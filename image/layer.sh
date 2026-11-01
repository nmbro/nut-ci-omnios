#!/bin/bash
# layer.sh <parent.qcow2> <name> <workdir> [--user] <FMRI>...
# Build <workdir>/<name>.qcow2 as a qcow2 layer on <parent>: boot it, install
# the packages (vm-layer.sh), fetch the package, license and file lists as
# <name>.{pkgs,licenses,files}.txt, seal and shut down. Then write the
# shipped form, <name>.c.qcow2: only this layer's clusters, zstd-compressed
# inside the qcow2 (QEMU reads it directly), backing file named relative so
# the chain works from any directory.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
parent=$(realpath "$1") name=$2 work=$(realpath "$3"); shift 3
adduser=false; [ "${1-}" = --user ] && { adduser=true; shift; }
cd "$work"
rm -f "$name.qcow2" "$name.c.qcow2"
qemu-img create -q -f qcow2 -F qcow2 -b "$parent" "$name.qcow2" 20G
bash "$here/boot.sh" "$work/$name.qcow2" "$work"
O=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i vmkey)
ssh "${O[@]}" -p 2222 root@127.0.0.1 sh -s install "$adduser" "$@" < "$here/vm-layer.sh"
for list in pkgs licenses files; do
    scp -q "${O[@]}" -P 2222 "root@127.0.0.1:/var/tmp/layer/$list.txt" "$name.$list.txt"
done
ssh "${O[@]}" -p 2222 root@127.0.0.1 sh -s seal < "$here/vm-layer.sh"
ssh "${O[@]}" -p 2222 root@127.0.0.1 /usr/sbin/shutdown -y -i5 -g0 >/dev/null || true
for _ in $(seq 1 100); do kill -0 "$(cat qemu.pid)" 2>/dev/null || break; sleep 3; done
if kill -0 "$(cat qemu.pid)" 2>/dev/null; then echo "layer.sh: VM did not stop"; exit 1; fi

# The parent's shipped name: the official image ships as base.c.qcow2
pname=$(basename "$parent" .qcow2); case "$pname" in omnios-*.cloud) pname=base ;; esac
qemu-img convert -c -O qcow2 -o compression_type=zstd -B "$parent" -F qcow2 "$name.qcow2" "$name.c.qcow2"
qemu-img rebase -u -F qcow2 -b "$pname.c.qcow2" "$name.c.qcow2"
echo "layer.sh: $name.c.qcow2 $(stat -c %s "$name.c.qcow2") bytes, on $pname.c.qcow2"
