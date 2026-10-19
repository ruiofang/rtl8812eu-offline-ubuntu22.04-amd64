#!/usr/bin/env bash
# Shared helpers. This file is sourced by the top-level scripts.
set -Eeuo pipefail
export LC_ALL=C
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
PACKAGE=realtek-rtl88x2eu
DKMS_VERSION='5.15.0.1~20230815'
MODULE=8812eu
SOURCE="$ROOT/driver/rtl8812eu"
INSTALLED_SOURCE="/usr/src/$PACKAGE-$DKMS_VERSION"
TESTED_KERNEL=6.8.0-85-generic

say() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
validate_kernel() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] || fail "Invalid kernel release: $1"
}
check_platform() {
    local ID='' VERSION_ID='' PRETTY_NAME='' VERSION=''
    [[ -r /etc/os-release ]] || fail 'Cannot identify the operating system.'
    # This is the host-owned standard OS identification file.
    . /etc/os-release
    [[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 22.04 ]] ||
        fail "This bundle supports Ubuntu 22.04 only (found ${PRETTY_NAME:-unknown})."
    have dpkg || fail 'dpkg is required.'
    [[ $(dpkg --print-architecture) == amd64 ]] || fail 'This bundle supports amd64/x86_64 only.'
}
verify_bundle() {
    [[ -s "$ROOT/SHA256SUMS" ]] || fail 'SHA256SUMS is missing. Use the complete, finalized offline bundle.'
    say 'Verifying bundle SHA-256 checksums...'
    (cd "$ROOT" && sha256sum --check --strict --quiet SHA256SUMS) ||
        fail 'Bundle verification failed. Recopy or recreate the complete bundle.'
    [[ -f "$SOURCE/dkms.conf" ]] || fail 'Driver source is missing.'
    [[ -s "$ROOT/packages/Packages" ]] || fail 'The local APT repository index is missing.'
}
source_digest() {
    (cd "$1" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1)
}
check_existing_source() {
    [[ -z $(find "$SOURCE" -type l -print -quit) ]] || fail 'The bundled driver source contains unexpected symbolic links.'
    [[ ! -L "$INSTALLED_SOURCE" ]] || fail "$INSTALLED_SOURCE is a symbolic link; refusing to replace it."
    if [[ -e "$INSTALLED_SOURCE" ]]; then
        [[ -d "$INSTALLED_SOURCE" ]] || fail "$INSTALLED_SOURCE is not a directory."
        [[ -z $(find "$INSTALLED_SOURCE" -type l -print -quit) ]] ||
            fail "Existing $INSTALLED_SOURCE contains symbolic links; refusing to replace it."
        [[ $(source_digest "$SOURCE") == $(source_digest "$INSTALLED_SOURCE") ]] ||
            fail "Existing $INSTALLED_SOURCE differs from this bundle. Preserve/review that installation before replacing it."
        say 'Existing DKMS source matches this bundle; it will be reused.'
    fi
}
check_existing_module() {
    local existing registered=''
    if have modinfo && existing=$(modinfo -k "$KERNEL" -n "$MODULE" 2>/dev/null); then
        if have dkms; then registered=$(dkms status -m "$PACKAGE" -v "$DKMS_VERSION" -k "$KERNEL"); fi
        [[ "$registered" == *': installed'* ]] ||
            fail "An existing 8812eu module ($existing) is not registered as this bundle's DKMS version for $KERNEL. Review/remove that installation first."
    fi
}
secure_boot_state() {
    local state path value
    if have mokutil; then
        state=$(mokutil --sb-state 2>/dev/null || true)
        case "$state" in
            *'SecureBoot enabled'*) printf 'enabled'; return ;;
            *'SecureBoot disabled'*) printf 'disabled'; return ;;
        esac
    fi
    if [[ ! -d /sys/firmware/efi ]]; then printf 'bios-or-no-efi'; return; fi
    for path in /sys/firmware/efi/efivars/SecureBoot-*; do
        [[ -r "$path" ]] || continue
        value=$(od -An -t u1 -j4 -N1 "$path" 2>/dev/null | tr -d '[:space:]') || continue
        case "$value" in 1) printf 'enabled'; return ;; 0) printf 'disabled'; return ;; esac
    done
    printf 'unknown'
}
check_secure_boot() {
    local state
    state=$(secure_boot_state)
    say "Secure Boot: $state"
    case "$state" in
        enabled) fail 'Secure Boot is enabled. This installer requires Secure Boot disabled; it cannot enroll a trusted key unattended. Keeping Secure Boot enabled requires a separate manual signing/enrollment workflow.' ;;
        unknown) fail 'Cannot verify Secure Boot state. Run this check with sudo; if still unknown, verify firmware/key enrollment before installing.' ;;
    esac
    if [[ -r /sys/kernel/security/lockdown ]] &&
        grep -Eq '\[(integrity|confidentiality)\]' /sys/kernel/security/lockdown; then
        fail 'Kernel lockdown is active; unsigned module loading is not available.'
    fi
}
headers_present() {
    [[ -f "/lib/modules/$1/build/include/config/auto.conf" &&
       -f "/lib/modules/$1/build/include/generated/utsrelease.h" ]]
}
repo_has_package() {
    awk -v name="$1" '$1 == "Package:" && $2 == name {found=1} END {exit !found}' "$ROOT/packages/Packages"
}
check_headers_available() {
    if headers_present "$KERNEL"; then
        say "Kernel headers: installed for $KERNEL"
    elif repo_has_package "linux-headers-$KERNEL"; then
        say "Kernel headers: bundled for $KERNEL; installation will install them."
    else
        fail "Matching headers for $KERNEL are neither installed nor bundled. Run tools/prepare-online.sh --kernel '$KERNEL' on an online Ubuntu 22.04 amd64 computer to add this kernel's headers, then copy the refreshed complete bundle."
    fi
    if [[ "$KERNEL" != "$TESTED_KERNEL" ]]; then
        say "NOTE: This source was tested on $TESTED_KERNEL. Building on $KERNEL needs separate verification."
    fi
}
start_log() {
    mkdir -p "$ROOT/logs"
    LOG="$ROOT/logs/$1-$(date +%Y%m%d-%H%M%S)-$$.log"
    exec > >(tee -a "$LOG") 2>&1
    say "Log: $LOG"
}
show_device_status() {
    local dev driver speed usb_devices=0 found=0 iface base
    say 'USB adapters (RTL8812EU commonly uses USB ID 0bda:a81a):'
    if have lsusb; then lsusb || true; else say '  lsusb is not installed.'; fi
    for dev in /sys/bus/usb/devices/*; do
        [[ -f "$dev/idVendor" && -f "$dev/idProduct" ]] || continue
        if [[ $(cat "$dev/idVendor") == 0bda && $(cat "$dev/idProduct") == a81a ]]; then
            usb_devices=$((usb_devices + 1))
            speed=$(cat "$dev/speed" 2>/dev/null || printf 'unknown')
            say "  RTL8812EU USB port $(basename "$dev"): $speed Mbps"
            [[ "$speed" != 12 ]] || say '  WARNING: 12 Mbps USB link severely limits throughput; check the port/cable.'
        fi
    done
    say 'Interfaces bound to 8812eu:'
    for iface in /sys/class/net/*; do
        [[ -e "$iface/device/driver/module" ]] || continue
        driver=$(basename "$(readlink -f "$iface/device/driver/module")")
        [[ "$driver" == "$MODULE" ]] || continue
        found=$((found + 1))
        base=$(basename "$iface")
        say "  $base: state=$(cat "$iface/operstate" 2>/dev/null || printf unknown)"
    done
    if (( found == 0 )); then
        say '  No bound interface found. Device connection, Wi-Fi scanning and throughput are not verified.'
    fi
    if (( usb_devices == 0 )); then
        say '  USB ID 0bda:a81a was not detected. Other supported USB IDs may exist; see driver USB aliases.'
    fi
}
