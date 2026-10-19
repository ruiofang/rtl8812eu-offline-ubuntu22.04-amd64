#!/usr/bin/env bash
# Read-only checks: does not create a log, run apt, load modules, or scan/connect Wi-Fi.
set -Eeuo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$HERE/tools/common.sh"
KERNEL=$(uname -r)
while (($#)); do
    case "$1" in
        --kernel) (($# >= 2)) || fail '--kernel needs a release.'; KERNEL=$2; shift 2 ;;
        -h|--help) say 'Usage: ./check.sh [--kernel RELEASE]'; exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done
validate_kernel "$KERNEL"
say "Running kernel: $(uname -r)"
say "Target kernel: $KERNEL"
check_platform
verify_bundle
check_secure_boot
check_headers_available
check_existing_source
check_existing_module
say 'Build/helper packages (missing packages will be resolved from the local repository):'
for package in build-essential dkms gcc-12 bc libelf-dev iw usbutils kmod; do
    state=$(dpkg-query -W -f='${db:Status-Status} ${Version}' "$package" 2>/dev/null || true)
    if [[ "$state" == installed* ]]; then
        say "  $package: $state"
    elif repo_has_package "$package"; then
        say "  $package: not installed, bundled"
    else
        fail "Required package $package is neither installed nor bundled."
    fi
done
say 'DKMS status:'
if have dkms; then dkms status -m "$PACKAGE" -v "$DKMS_VERSION" || true; else say '  DKMS is not installed yet.'; fi
say "Module on disk for $KERNEL:"
if have modinfo && modinfo -k "$KERNEL" "$MODULE" >/dev/null 2>&1; then
    modinfo -k "$KERNEL" -F filename "$MODULE"
    modinfo -k "$KERNEL" -F vermagic "$MODULE"
else
    say '  8812eu is not installed for this kernel yet.'
fi
if [[ -d "/sys/module/$MODULE" ]]; then say 'Loaded module: 8812eu'; else say 'Loaded module: not loaded'; fi
show_device_status
say 'Read-only preflight passed. Package dependency resolution/build and real device operation are separate installation checks.'
