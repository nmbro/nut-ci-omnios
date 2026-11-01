#!/bin/bash
# boot.sh <disk.qcow2> <workdir> [ssh-port]: boot an OmniOS cloud image (or a
# layer on top of one) in QEMU/KVM and wait until root can log in with
# <workdir>/vmkey over ssh on 127.0.0.1:<ssh-port> (default 2222).
# A NoCloud seed CD gives cloud-init the key; the image's own cloud-init then
# makes fresh SSH host keys. SSH is forwarded on loopback only.
# The emulated e1000 NIC is deliberate: the image's vioif fails to map its
# BAR under QEMU's virtio-net ("Failed to map CAP 1").
set -euo pipefail
disk=$1 work=$2 port=${3:-2222}
cd "$work"
[ -f vmkey ] || ssh-keygen -q -t ed25519 -N '' -f vmkey
cat > user-data <<EOF
#cloud-config
disable_root: false
ssh_authorized_keys:
  - $(cat vmkey.pub)
EOF
printf 'instance-id: nut-ci-%s\nlocal-hostname: omnios\n' "$(date +%s%N)" > meta-data
cloud-localds seed.iso user-data meta-data
rm -f console.log
qemu-system-x86_64 -enable-kvm -cpu host -smp "${VM_CPUS:-4}" -m "${VM_MEM:-8192}" \
  -display none -monitor none -serial file:console.log \
  -drive file="$disk",if=virtio,discard=unmap,detect-zeroes=unmap \
  -drive file=seed.iso,media=cdrom,readonly=on \
  -nic user,model=e1000,hostfwd=tcp:127.0.0.1:"$port"-:22 \
  > qemu.out 2>&1 < /dev/null &
echo $! > qemu.pid
for i in $(seq 1 60); do
  if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -o ConnectTimeout=5 -o LogLevel=ERROR -i vmkey -p "$port" root@127.0.0.1 true 2>/dev/null; then
    echo "boot.sh: ssh up after $((i * 5)) s"; exit 0
  fi
  kill -0 "$(cat qemu.pid)" 2>/dev/null || { echo "boot.sh: QEMU exited"; cat qemu.out; exit 1; }
  sleep 5
done
echo "boot.sh: no ssh after 300 s; console tail:"; tail -30 console.log | tr -d '\r'; exit 1
