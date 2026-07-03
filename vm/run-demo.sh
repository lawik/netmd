#!/usr/bin/env bash
# Run the both-sides demo as root in the guest. Assumes guest-setup.sh has run.
#
# Builds netmd guest-local (the 9p share is slow for kbuild/mix and a
# host-built _build for a different setup must not leak in), then runs the
# demo which starts the FunctionFS gadget and drives it with the real USB
# transport in the same BEAM.
set -euo pipefail

SHARE="${NETMD_SHARE:-/mnt/sprawl}"
CIRCUITS="${NETMD_CIRCUITS:-$SHARE/circuits_usb}"
SRC="${NETMD_SRC:-$SHARE/netmd}"
BUILD=/root/netmd

export PATH="/root/.local/bin:$PATH"
command -v mise >/dev/null 2>&1 && eval "$(mise activate bash)"

echo "== ensure dummy_hcd is loaded =="
bash "$CIRCUITS/harness/scripts/load-dummy.sh" >/dev/null

echo "== copy netmd to guest-local $BUILD =="
rm -rf "$BUILD"
cp -a "$SRC" "$BUILD"
cd "$BUILD"
# Drop any host build products copied in via the share.
rm -rf _build deps

echo "== fetch deps and run the demo =="
mise exec -- mix deps.get
mise exec -- mix run vm/both_sides.exs
