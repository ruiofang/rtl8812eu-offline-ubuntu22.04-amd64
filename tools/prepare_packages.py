#!/usr/bin/env python3
"""Add a complete native Ubuntu 22.04 dependency closure to the offline kit.

Uses APT's normal signed package metadata, but solves dependencies with an empty
dpkg status and empty archives so an already provisioned preparation host cannot
hide dependencies needed on another machine. Does not install system packages.
"""
import argparse
import concurrent.futures
import datetime
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
PACKAGE_DIR = ROOT / "packages"
BASE_PACKAGES = ["build-essential", "dkms", "gcc-12", "bc", "libelf-dev",
                 "iw", "usbutils", "kmod", "mokutil"]


def run(args):
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE,
                          env={**os.environ, "LC_ALL": "C"}).stdout


def digest(path, algorithm="sha256"):
    value = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def atomic_text(path, content):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(content, encoding="utf-8")
    temporary.replace(path)


def parse_records(text):
    records = {}
    for block in text.strip().split("\n\n"):
        fields = {}
        for line in block.splitlines():
            if ": " in line and not line.startswith(" "):
                key, value = line.split(": ", 1)
                fields[key] = value
        if all(key in fields for key in ("Package", "Version", "Architecture", "SHA256")):
            records[fields["Package"], fields["Version"], fields["Architecture"]] = fields
    return records


def resolve(kernel):
    requested = BASE_PACKAGES + ["linux-headers-" + kernel]
    with tempfile.TemporaryDirectory(prefix="rtl8812eu-apt-") as temporary:
        archives = Path(temporary) / "archives"
        archives.mkdir()
        # Exclude third-party repositories, including CUDA's newer DKMS fork.
        # Preferences are temporary and never change the preparation host.
        preferences = Path(temporary) / "preferences"
        preferences_parts = Path(temporary) / "preferences.d"
        preferences_parts.mkdir()
        preferences.write_text("".join("Package: *\nPin: release o=Ubuntu,a=" + suite
                                       + "\nPin-Priority: 1001\n\n"
                                       for suite in ("jammy", "jammy-updates", "jammy-security"))
                               + "Package: *\nPin: release *\nPin-Priority: -1\n")
        apt_options = ["-o", "Dir::Etc::preferences=" + str(preferences),
                       "-o", "Dir::Etc::preferencesparts=" + str(preferences_parts),
                       "-o", "Dir::State::status=/dev/null"]
        plan = run(["apt-get", *apt_options,
                    "-o", "Dir::Cache::archives=" + str(archives),
                    "--print-uris", "--no-install-recommends", "--yes",
                    "--download-only", "install", *requested])
    rows = []
    specs = []
    for line in plan.splitlines():
        if not line.startswith("'"):
            continue
        uri, filename, size, _weak_hash = shlex.split(line)
        filename = urllib.parse.unquote(filename)
        if Path(filename).name != filename or not filename.endswith(".deb"):
            raise RuntimeError("不安全的软件包文件名: " + filename)
        package, version, architecture = filename[:-4].split("_")
        rows.append((uri, filename, int(size), package, version, architecture))
        specs.append(package + "=" + version)
    if not rows:
        raise RuntimeError("APT 未返回依赖包；请检查仓库和内核版本。")
    metadata = run(["apt-cache", "show", *specs])
    records = parse_records(metadata)
    packages = []
    for uri, filename, size, package, version, architecture in rows:
        record = records[package, version, architecture]
        if int(record["Size"]) != size or not re.fullmatch(r"[0-9a-f]{64}", record["SHA256"]):
            raise RuntimeError("APT 元数据不一致: " + filename)
        parsed = urllib.parse.urlsplit(uri)
        if parsed.scheme not in ("http", "https"):
            raise RuntimeError("仅支持 HTTP(S) Ubuntu 仓库: " + uri)
        if parsed.username or parsed.password:
            raise RuntimeError("请使用无需凭据的 Ubuntu 仓库。")
        uri = urllib.parse.urlunsplit(("https", parsed.netloc, parsed.path, parsed.query, parsed.fragment))
        packages.append(dict(url=uri, filename=filename, size=size, package=package,
                             version=version, architecture=architecture, sha256=record["SHA256"]))
    return requested, packages, plan, metadata


def fetch(package):
    target = PACKAGE_DIR / package["filename"]
    if (target.is_file() and target.stat().st_size == package["size"]
            and digest(target) == package["sha256"]):
        return "已有 " + target.name
    temporary = target.with_name(target.name + ".part")
    for attempt in range(3):
        try:
            with urllib.request.urlopen(package["url"], timeout=90) as response, temporary.open("wb") as output:
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    output.write(chunk)
            if temporary.stat().st_size != package["size"] or digest(temporary) != package["sha256"]:
                raise RuntimeError("软件包大小/SHA256 不匹配: " + target.name)
            temporary.replace(target)
            return "下载 " + target.name
        except Exception:
            temporary.unlink(missing_ok=True)
            if attempt == 2:
                raise
            time.sleep(attempt + 1)


def refresh_indexes():
    """No dpkg-dev prerequisite: dpkg-deb is part of every normal Ubuntu host."""
    records = []
    for path in sorted(PACKAGE_DIR.glob("*.deb")):
        control = run(["dpkg-deb", "--field", str(path)]).rstrip()
        records.append(control + "\nFilename: ./" + path.name + "\nSize: " + str(path.stat().st_size)
                       + "\nMD5sum: " + digest(path, "md5") + "\nSHA256: " + digest(path) + "\n\n")
    text = "".join(records)
    atomic_text(PACKAGE_DIR / "Packages", text)
    (PACKAGE_DIR / "Packages.gz").write_bytes(gzip.compress(text.encode(), mtime=0))
    package_files = sorted(p for p in PACKAGE_DIR.iterdir()
                           if p.is_file() and p.name != "SHA256SUMS" and not p.name.endswith((".tmp", ".part")))
    atomic_text(PACKAGE_DIR / "SHA256SUMS", "".join(digest(p) + "  " + p.name + "\n" for p in package_files))
    # The root manifest covers deliverables, including the nested checksum file.
    # Runtime logs are deliberately excluded so checks survive normal operation.
    all_files = sorted(p for p in ROOT.rglob("*") if p.is_file()
                       and p != ROOT / "SHA256SUMS"
                       and "logs" not in p.relative_to(ROOT).parts
                       and "__pycache__" not in p.relative_to(ROOT).parts
                       and not p.name.endswith((".tmp", ".part")))
    atomic_text(ROOT / "SHA256SUMS", "".join(digest(p) + "  " + str(p.relative_to(ROOT)) + "\n" for p in all_files))


def main():
    parser = argparse.ArgumentParser(description="在联网 Ubuntu 22.04 amd64 上补齐离线依赖，不安装系统软件包。")
    parser.add_argument("--kernel", default=os.uname().release, help="目标电脑 uname -r 输出，默认本机内核")
    parser.add_argument("--no-update", action="store_true", help="跳过 apt-get update，使用已有仓库元数据")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9][0-9A-Za-z.+~-]*", args.kernel):
        parser.error("内核版本格式无效")
    release = dict(line.split("=", 1) for line in Path("/etc/os-release").read_text().splitlines() if "=" in line)
    if release.get("ID", "").strip('"') != "ubuntu" or release.get("VERSION_ID", "").strip('"') != "22.04":
        parser.error("请在 Ubuntu 22.04 联网准备机运行，不能混用其他发行版依赖。")
    if run(["dpkg", "--print-architecture"]).strip() != "amd64":
        parser.error("此离线工程仅支持 amd64。")
    if not args.no_update:
        if os.geteuid() != 0:
            parser.error("刷新仓库需要 root；请使用 sudo ./tools/prepare-online.sh --kernel " + args.kernel)
        subprocess.run(["apt-get", "update"], check=True)
    PACKAGE_DIR.mkdir(parents=True, exist_ok=True)
    requested, packages, plan, metadata = resolve(args.kernel)
    print("需核对/下载 %d 个依赖包，合计 %.1f MB" % (len(packages), sum(p["size"] for p in packages) / 1e6), flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        for message in pool.map(fetch, packages):
            print(message, flush=True)
    manifest_path = PACKAGE_DIR / "manifest.json"
    previous = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    combined = {p["filename"]: p for p in previous.get("packages", [])}
    combined.update({p["filename"]: p for p in packages})
    timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
    manifest = dict(format=1, ubuntu_version="22.04", architecture="amd64",
                    kernels=sorted(set(previous.get("kernels", [])) | {args.kernel}),
                    created_utc=previous.get("created_utc", timestamp), updated_utc=timestamp,
                    dependency_policy="apt-get --no-install-recommends against empty dpkg status and empty archive cache; exact SHA256 from apt metadata",
                    requested_packages=sorted(set(previous.get("requested_packages", [])) | set(requested)),
                    packages=sorted(combined.values(), key=lambda p: p["filename"]))
    atomic_text(manifest_path, json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    atomic_text(PACKAGE_DIR / ("apt-plan-" + args.kernel + ".txt"), plan)
    atomic_text(PACKAGE_DIR / ("apt-metadata-" + args.kernel + ".txt"), metadata)
    refresh_indexes()
    print("准备完成：" + str(ROOT))
    print("请把整个工程目录复制到离线目标电脑，然后运行 sudo ./install.sh")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
        print("准备失败: " + str(error), file=sys.stderr)
        print("尚未安装任何系统软件包。修复网络/仓库/目标内核版本后可重试。", file=sys.stderr)
        sys.exit(1)
