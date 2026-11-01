#!/bin/bash
# build.sh <release.conf> <workdir> [compiler...]
# Build the whole chain for one OmniOS release into <workdir>/out:
#   base.c.qcow2          the official cloud image, checked against BASE_SHA256
#   nut-deps.c.qcow2      DEPS_PKGS + the abuild user, on base
#   <compiler>.c.qcow2    one per COMPILERS entry (or the ones named), on nut-deps
# plus <layer>.{pkgs,licenses,files}.txt for each built layer.
# Needs qemu-system-x86_64 with KVM, qemu-img, cloud-localds, curl.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
conf=$(realpath "$1") work=$(realpath -m "$2"); shift 2
# shellcheck source=r151058.conf
. "$conf"
mkdir -p "$work/out"; cd "$work"

base="omnios-$RELEASE.cloud.qcow2"
[ -f "$base" ] || curl -fsSL --retry 3 -o "$base" "$BASE_URL"
echo "$BASE_SHA256  $base" | sha256sum -c -
qemu-img convert -c -O qcow2 -o compression_type=zstd "$base" out/base.c.qcow2

# shellcheck disable=SC2086 # the package lists split on whitespace
bash "$here/layer.sh" "$base" nut-deps out --user $DEPS_PKGS

for entry in $COMPILERS; do
    name=${entry%%=*} fmri=${entry#*=}
    if [ $# -gt 0 ] && ! printf '%s\n' "$@" | grep -qx "$name"; then continue; fi
    bash "$here/layer.sh" out/nut-deps.qcow2 "$name" out "$fmri"
done
ls -l out/*.c.qcow2
