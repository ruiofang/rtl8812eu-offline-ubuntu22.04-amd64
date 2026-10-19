#!/usr/bin/env bash
# On an Internet-connected Ubuntu 22.04 amd64 host:
#   sudo ./tools/prepare-online.sh --kernel 6.8.0-85-generic
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' '需要 Python 3。请先在联网准备机安装 python3。' >&2
    exit 1
fi
exec python3 "$SCRIPT_DIR/prepare_packages.py" "$@"
