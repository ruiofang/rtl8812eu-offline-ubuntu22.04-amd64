#!/usr/bin/env bash
# Remove only this bundle's DKMS package/version. System dependencies are retained.
set -Eeuo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$HERE/tools/common.sh"
UNLOAD=0
while (($#)); do
    case "$1" in
        --unload) UNLOAD=1; shift ;;
        -h|--help)
            say 'Usage: sudo ./uninstall.sh [--unload]'
            say 'Removes this DKMS version for all kernels and its matching source.'
            say 'Default: leave any loaded driver active until reboot.'
            say '--unload: unload 8812eu now; connected Wi-Fi will disconnect.'
            exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done
(( EUID == 0 )) || fail 'Run: sudo ./uninstall.sh'
check_platform
verify_bundle
check_existing_source
have flock || fail 'flock (util-linux) is required.'
exec 9>/run/lock/rtl8812eu-offline.lock
flock -n 9 || fail 'Another RTL8812EU bundle installer is running.'
start_log uninstall
if (( UNLOAD )) && [[ -d "/sys/module/$MODULE" ]]; then
    running_kernel=$(uname -r)
    have dkms && have modinfo || fail 'Cannot verify ownership of the loaded driver; refusing to unload it.'
    unload_status=$(dkms status -m "$PACKAGE" -v "$DKMS_VERSION" -k "$running_kernel")
    [[ "$unload_status" == *': installed'* ]] ||
        fail "This bundle's DKMS version is not installed for the running kernel; refusing to unload a potentially unrelated driver."
    unload_path=$(modinfo -k "$running_kernel" -n "$MODULE")
    case "$unload_path" in
        /lib/modules/"$running_kernel"/updates/dkms/8812eu.ko|\
        /lib/modules/"$running_kernel"/updates/dkms/8812eu.ko.xz|\
        /lib/modules/"$running_kernel"/updates/dkms/8812eu.ko.zst|\
        /usr/lib/modules/"$running_kernel"/updates/dkms/8812eu.ko|\
        /usr/lib/modules/"$running_kernel"/updates/dkms/8812eu.ko.xz|\
        /usr/lib/modules/"$running_kernel"/updates/dkms/8812eu.ko.zst) ;;
        *) fail "Unexpected module path $unload_path; refusing to unload a potentially unrelated driver." ;;
    esac
    say 'Unloading 8812eu; its Wi-Fi interfaces will disconnect.'
    modprobe -r "$MODULE" || fail 'Module could not be unloaded; no DKMS/source removal was attempted.'
fi
if have dkms && [[ -n $(dkms status -m "$PACKAGE" -v "$DKMS_VERSION") ]]; then
    dkms remove -m "$PACKAGE" -v "$DKMS_VERSION" --all
fi
if [[ -d "$INSTALLED_SOURCE" ]]; then
    # Refuse modified/foreign source above; remove only the exact known directory.
    rm -rf -- "$INSTALLED_SOURCE"
fi
say "Removed $PACKAGE/$DKMS_VERSION and its matching DKMS source. Build dependencies and other drivers were retained."
if [[ -d "/sys/module/$MODULE" ]]; then
    say 'The loaded module remains active until reboot or a deliberate module unload.'
fi
