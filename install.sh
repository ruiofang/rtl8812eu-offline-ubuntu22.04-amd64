#!/usr/bin/env bash
# Install only from this bundle's file: APT repository. No network setup is changed.
set -Eeuo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$HERE/tools/common.sh"
KERNEL=$(uname -r)
NO_LOAD=0
CHECK=0
usage() {
    cat <<'EOF'
Usage: sudo ./install.sh [--kernel RELEASE] [--no-load]
       ./install.sh --check [--kernel RELEASE]

Defaults to building, installing and loading RTL8812EU for the running kernel.
--check      Read-only bundle/platform/header/security/device checks; no root needed.
--kernel     Target a kernel release; a non-running kernel requires --no-load.
--no-load    Install the driver without loading/unloading any network driver.
--help       Show this help.
EOF
}
while (($#)); do
    case "$1" in
        --kernel) (($# >= 2)) || fail '--kernel needs a release.'; KERNEL=$2; shift 2 ;;
        --no-load) NO_LOAD=1; shift ;;
        --check) CHECK=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done
validate_kernel "$KERNEL"
if (( CHECK )); then exec "$ROOT/check.sh" --kernel "$KERNEL"; fi
(( EUID == 0 )) || fail 'Run: sudo ./install.sh (or use ./install.sh --check for read-only checks).'
[[ "$KERNEL" == "$(uname -r)" || "$NO_LOAD" == 1 ]] || fail 'A non-running target kernel requires --no-load.'
check_platform
verify_bundle
check_secure_boot
check_headers_available
check_existing_source
check_existing_module
have flock || fail 'flock (util-linux) is required.'
exec 9>/run/lock/rtl8812eu-offline.lock
flock -n 9 || fail 'Another RTL8812EU bundle installer is running.'
start_log install
TEMP=$(mktemp -d /tmp/rtl8812eu-apt.XXXXXXXX)
STAGE=''
trap 'rc=$?; rm -rf -- "$TEMP"; if [[ -n "$STAGE" ]]; then rm -rf -- "$STAGE"; fi; if ((rc)); then printf "Installation failed (exit %s). See %s\n" "$rc" "$LOG" >&2; fi' EXIT
mkdir -p "$TEMP/lists/partial" "$TEMP/archives/partial"
# A symlink avoids spaces/non-ASCII characters in a removable drive's path.
ln -s "$ROOT/packages" "$TEMP/repository"
printf 'deb [trusted=yes] file:%s/repository ./\n' "$TEMP" > "$TEMP/sources.list"
APT=(apt-get
    -o "Dir::Etc::sourcelist=$TEMP/sources.list"
    -o 'Dir::Etc::sourceparts=-'
    -o "Dir::State::lists=$TEMP/lists"
    -o "Dir::Cache::archives=$TEMP/archives"
    -o 'APT::Sandbox::User=root'
    -o 'Acquire::Languages=none'
    -o 'Acquire::Retries=0'
    -o 'APT::Get::List-Cleanup=0'
    -o 'DPkg::Options::=--force-confold')
DEPS=(build-essential dkms gcc-12 bc libelf-dev iw usbutils kmod)
# Already-installed manual headers are valid too; do not force a missing .deb.
if ! headers_present "$KERNEL"; then DEPS+=("linux-headers-$KERNEL"); fi
say 'Resolving build dependencies using only the bundled file: repository...'
"${APT[@]}" update
"${APT[@]}" --simulate --no-remove --no-install-recommends install "${DEPS[@]}"
DEBIAN_FRONTEND=noninteractive "${APT[@]}" --assume-yes --no-remove --no-install-recommends install "${DEPS[@]}"
headers_present "$KERNEL" || fail "Headers for $KERNEL are still incomplete."
have gcc-12 || fail 'gcc-12 installation did not complete.'
have dkms || fail 'DKMS installation did not complete.'
check_existing_module
if [[ ! -e "$INSTALLED_SOURCE" ]]; then
    STAGE=$(mktemp -d "/usr/src/.$PACKAGE-stage.XXXXXXXX")
    cp -a "$SOURCE/." "$STAGE/"
    chown -R root:root "$STAGE"
    mv -T "$STAGE" "$INSTALLED_SOURCE"
    STAGE=''
fi
check_existing_source
STATUS=$(dkms status -m "$PACKAGE" -v "$DKMS_VERSION")
if [[ -z "$STATUS" ]]; then
    dkms add -m "$PACKAGE" -v "$DKMS_VERSION"
fi
STATUS=$(dkms status -m "$PACKAGE" -v "$DKMS_VERSION" -k "$KERNEL")
if [[ "$STATUS" != *': installed'* ]]; then
    dkms build -m "$PACKAGE" -v "$DKMS_VERSION" -k "$KERNEL"
    dkms install -m "$PACKAGE" -v "$DKMS_VERSION" -k "$KERNEL"
else
    say "DKMS already reports this version installed for $KERNEL; reusing it."
fi
depmod -a "$KERNEL"
MODULE_PATH=$(modinfo -k "$KERNEL" -n "$MODULE")
VERMAGIC=$(modinfo -k "$KERNEL" -F vermagic "$MODULE")
[[ ${VERMAGIC%% *} == "$KERNEL" ]] || fail "Installed module vermagic does not match $KERNEL: $VERMAGIC"
say "Installed module: $MODULE_PATH"
say "Module vermagic: $VERMAGIC"
if (( NO_LOAD )); then
    say 'Driver installation complete. Loading was skipped (--no-load).'
elif [[ -d "/sys/module/$MODULE" ]]; then
    say 'Driver installation complete. 8812eu was already loaded; it has not been disconnected/reloaded.'
    say 'If the loaded module predates this installation, reboot later or reload it during a maintenance window.'
else
    if ! modprobe "$MODULE"; then
        fail 'DKMS installation succeeded, but loading failed. Inspect this log and dmesg; no network configuration has been changed.'
    fi
    say 'Driver installation and module loading succeeded.'
fi
dkms status -m "$PACKAGE" -v "$DKMS_VERSION"
show_device_status
say 'No Wi-Fi connection, IP address, global network settings, kernel image or reboot was configured.'
