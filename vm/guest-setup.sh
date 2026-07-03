#!/usr/bin/env bash
# One-time guest provisioning for the netmd VM. Runs IN the guest as root.
#
# Installs kernel/build deps, brings up the virtual USB stack (configfs,
# gadget modules, dummy_hcd built from the circuits_usb harness), and an
# Elixir toolchain. Idempotent; the OTP source build is the slow part.
set -euo pipefail

SHARE="${NETMD_SHARE:-/mnt/sprawl}"
CIRCUITS="${NETMD_CIRCUITS:-$SHARE/circuits_usb}"

[ -d "$CIRCUITS" ] || {
  echo "circuits_usb not found at $CIRCUITS (set NETMD_CIRCUITS)" >&2
  exit 1
}

echo "== kernel + build deps =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  build-essential curl kmod usbutils git ca-certificates \
  "linux-headers-$(uname -r)" "linux-modules-extra-$(uname -r)"

echo "== virtual USB stack =="
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
modprobe libcomposite
modprobe usb_f_fs
# Build (if needed) and load dummy_hcd via the circuits_usb harness.
bash "$CIRCUITS/harness/scripts/load-dummy.sh" >/dev/null

echo "== Elixir toolchain (reuses circuits_usb provisioning; OTP source build is slow) =="
bash "$CIRCUITS/harness/vm/provision-elixir.sh"

echo "GUEST_SETUP_DONE"
