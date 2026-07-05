#!/usr/bin/env bash
# Disposable QEMU VM for running netmd as root against a virtual USB stack.
#
# Reuses the bodge_usb VM approach (Ubuntu cloud image + cloud-init +
# virtio-9p + KVM) but shares the sprawl PARENT directory so both the netmd
# and bodge_usb checkouts are visible in the guest. That lets the guest
# build the bodge_usb NIF, load dummy_hcd, run the FunctionFS gadget
# (NetMD.Simulator.Gadget) and drive it with the real transport -- both
# sides of the USB link in one VM, no hardware.
#
# Subcommands:
#   up          boot the VM (creates disk/seed on first run), wait for SSH
#   setup       install kernel/build deps, Elixir, load modules (guest)
#   demo        run the both-sides demo as root in the guest
#   ssh [cmd]   run a command in the guest (interactive if none)
#   status      show VM/ssh state
#   down        power off cleanly
#   destroy     power off and delete the disk overlay
set -euo pipefail

STATE="${NETMD_VM_STATE:-$HOME/.local/share/netmd-vm}"
# Share the parent of the netmd repo so bodge_usb (a sibling) comes along.
SHARE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NETMD_SUBDIR="$(basename "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")"
KEY="$STATE/id_ed25519"
BASE="$STATE/noble-cloudimg.qcow2"
OVERLAY="$STATE/disk.qcow2"
SEED="$STATE/seed.iso"
SERIAL="$STATE/serial.log"
PIDFILE="$STATE/qemu.pid"
SSH_PORT="${NETMD_VM_SSH_PORT:-2223}"
MEM="${NETMD_VM_MEM:-4096}"
CPUS="${NETMD_VM_CPUS:-4}"
MOUNT_TAG=sprawl
GUEST_SHARE=/mnt/sprawl
GUEST_NETMD="$GUEST_SHARE/$NETMD_SUBDIR"

SSHOPTS=(-i "$KEY" -p "$SSH_PORT"
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR -o ConnectTimeout=5)
SSH_HOST=dev@127.0.0.1

log() { printf '[vm] %s\n' "$*" >&2; }
die() { printf '[vm] ERROR: %s\n' "$*" >&2; exit 1; }
vm_running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

make_seed() {
  [ -f "$SEED" ] && return 0
  local pub; pub="$(cat "$KEY.pub")"
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/meta-data" <<EOF
instance-id: netmdvm-001
local-hostname: netmdvm
EOF
  cat > "$tmp/user-data" <<EOF
#cloud-config
hostname: netmdvm
users:
  - name: dev
    groups: [sudo]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - $pub
EOF
  genisoimage -output "$SEED" -volid cidata -joliet -rock \
    "$tmp/user-data" "$tmp/meta-data" >/dev/null 2>&1
  rm -rf "$tmp"
  log "created cloud-init seed"
}

BASE_IMAGE_URL="${NETMD_VM_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"

fetch_base_image() {
  [ -f "$BASE" ] && return 0
  command -v curl >/dev/null 2>&1 || die "curl needed to download the base image"
  log "downloading base cloud image (~600MB, one time)"
  curl -L --fail --retry 3 -C - -o "$BASE.part" "$BASE_IMAGE_URL" || die "image download failed"
  mv "$BASE.part" "$BASE"
}

make_overlay() {
  [ -f "$OVERLAY" ] && return 0
  fetch_base_image
  qemu-img create -f qcow2 -F qcow2 -b "$BASE" "$OVERLAY" 20G >/dev/null
  log "created disk overlay (20G)"
}

cmd_up() {
  mkdir -p "$STATE"
  [ -f "$KEY" ] || ssh-keygen -t ed25519 -N '' -C netmd-vm -f "$KEY" >/dev/null
  if vm_running; then log "already running (pid $(cat "$PIDFILE"))"; wait_ssh; return; fi
  make_seed
  make_overlay
  log "booting VM (kvm, ${CPUS} cpu, ${MEM}MB, ssh -> 127.0.0.1:${SSH_PORT})"
  qemu-system-x86_64 \
    -enable-kvm -cpu host -smp "$CPUS" -m "$MEM" \
    -drive file="$OVERLAY",if=virtio,format=qcow2 \
    -drive file="$SEED",if=virtio,format=raw,readonly=on \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"$SSH_PORT"-:22 \
    -device virtio-net-pci,netdev=net0 \
    -fsdev local,id=sprawl,path="$SHARE_ROOT",security_model=none \
    -device virtio-9p-pci,fsdev=sprawl,mount_tag="$MOUNT_TAG" \
    -display none -serial file:"$SERIAL" \
    -pidfile "$PIDFILE" -daemonize
  wait_ssh
}

wait_ssh() {
  log "waiting for SSH (cloud-init first boot ~30-60s)..."
  local i
  for i in $(seq 1 120); do
    if ssh "${SSHOPTS[@]}" "$SSH_HOST" true 2>/dev/null; then log "SSH is up"; return 0; fi
    sleep 2
  done
  die "SSH did not come up; see $SERIAL"
}

cmd_ssh() {
  if [ $# -eq 0 ]; then ssh "${SSHOPTS[@]}" "$SSH_HOST"; else ssh "${SSHOPTS[@]}" "$SSH_HOST" "$@"; fi
}

ensure_mount() {
  cmd_ssh "sudo mkdir -p $GUEST_SHARE && sudo mountpoint -q $GUEST_SHARE || \
    sudo mount -t 9p -o trans=virtio,version=9p2000.L,msize=262144 $MOUNT_TAG $GUEST_SHARE"
}

cmd_setup() {
  vm_running || die "VM not running (run 'up' first)"
  ensure_mount
  cmd_ssh "sudo bash $GUEST_NETMD/vm/guest-setup.sh"
}

cmd_demo() {
  vm_running || die "VM not running (run 'up' first)"
  ensure_mount
  cmd_ssh "cd $GUEST_NETMD && sudo bash vm/run-demo.sh"
}

cmd_status() {
  if vm_running; then log "VM running (pid $(cat "$PIDFILE"))"; else log "VM not running"; fi
  ssh "${SSHOPTS[@]}" "$SSH_HOST" 'echo guest: $(uname -r); uptime' 2>/dev/null || log "SSH not reachable"
}

cmd_down() {
  vm_running || { log "not running"; return 0; }
  log "powering off"
  ssh "${SSHOPTS[@]}" "$SSH_HOST" 'sudo poweroff' 2>/dev/null || true
  local i; for i in $(seq 1 30); do vm_running || { log "down"; rm -f "$PIDFILE"; return 0; }; sleep 1; done
  kill "$(cat "$PIDFILE")" 2>/dev/null || true; rm -f "$PIDFILE"
}

cmd_destroy() { cmd_down; rm -f "$OVERLAY"; log "removed overlay"; }

case "${1:-}" in
  up)      shift; cmd_up "$@" ;;
  setup)   shift; cmd_setup "$@" ;;
  demo)    shift; cmd_demo "$@" ;;
  ssh)     shift; cmd_ssh "$@" ;;
  status)  shift; cmd_status "$@" ;;
  down)    shift; cmd_down "$@" ;;
  destroy) shift; cmd_destroy "$@" ;;
  *) echo "usage: $0 {up|setup|demo|ssh [cmd]|status|down|destroy}" >&2; exit 2 ;;
esac
