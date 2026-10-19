#!/usr/bin/env bash
# Developer verification: needs Docker and an already cached ubuntu:22.04 image.
# All installation changes stay inside a disposable, unprivileged container.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
docker image inspect ubuntu:22.04 >/dev/null
docker run --rm --network none \
    -v "$ROOT:/bundle" -w /bundle ubuntu:22.04 bash -euc '
    ./check.sh --kernel 6.8.0-85-generic
    ./install.sh --kernel 6.8.0-85-generic --no-load
    modinfo -k 6.8.0-85-generic -F vermagic 8812eu
    dkms status -m realtek-rtl88x2eu -v "5.15.0.1~20230815" -k 6.8.0-85-generic | grep ": installed"
    ./install.sh --kernel 6.8.0-85-generic --no-load
    ./uninstall.sh
    ./uninstall.sh
    test ! -e /usr/src/realtek-rtl88x2eu-5.15.0.1~20230815
    test ! -e /lib/modules/6.8.0-85-generic/updates/dkms/8812eu.ko
    test -z "$(dkms status -m realtek-rtl88x2eu -v "5.15.0.1~20230815")"
    echo "PASS: offline dependencies, DKMS build/install, repeat install and uninstall"
    '
