# nut-ci-omnios

OmniOS VM images for running [Network UPS Tools](https://github.com/networkupstools/nut)
CI cells on GitHub-hosted runners: a qcow2 backing chain built from the
official OmniOS cloud image, pushed to GHCR as OCI artifacts with SLSA
build provenance and an SPDX SBOM.

| Layer | Contents | Parent |
|---|---|---|
| `base.c.qcow2` | the official OmniOS cloud image, checked against the sha256 OmniOS publishes | |
| `nut-deps.c.qcow2` | NUT's build prerequisites, gcc 14, ccache, rsync, the `abuild` user | `base.c.qcow2` |
| `<compiler>.c.qcow2` | one of clang 13/17/20/22 or gcc 15 | `nut-deps.c.qcow2` |

Each manifest, `ghcr.io/<owner>/nut-ci-omnios:<release>-<compiler>`, holds
the three layers of its chain plus each layer's package list
(`*.pkgs.txt`, full IPS FMRIs) and file list (`*.files.txt`: sha256, mode,
owner and path of every regular file). Its digest covers all of them.
Layers hold only their own clusters, zstd-compressed inside the qcow2, and
name their backing file relatively, so QEMU boots the top file wherever
the chain was pulled to. Boot a throwaway overlay of it, never the pulled
layer itself, or the layer's digest no longer matches.

## Using an image

```
oras pull ghcr.io/<owner>/nut-ci-omnios@sha256:<digest> -o img
qemu-img create -f qcow2 -F qcow2 -b img/clang-22.c.qcow2 job.qcow2
bash image/boot.sh job.qcow2 .        # root over ssh on 127.0.0.1:2222, key ./vmkey
```

Build as `abuild`, not root (NUT's integration tests drop privileges).
Pin the manifest digest, and verify it before booting (below).

## Files

- `image/<release>.conf`: the pinned inputs: base image URL and sha256,
  package FMRIs for the deps layer, one FMRI per compiler layer.
- `image/build.sh`: builds the chain for one release; `image/layer.sh`
  builds one layer; `image/vm-layer.sh` runs inside the VM (install, list,
  seal); `image/boot.sh` boots an image with an ssh key given by cloud-init.
- `image/mkspdx.py`: SPDX 2.3 SBOM from a package list.
- `.github/workflows/build.yml`: the reusable build, push and attest
  workflow; `release.yml` runs it for each release.

To build locally (needs KVM, `qemu-img`, `cloud-localds`):
`bash image/build.sh image/r151058.conf /tmp/img clang-22`.

## Reproducibility

Bit-for-bit identical images are not the goal: ZFS stores transaction
numbers, GUIDs and timestamps, and block placement depends on timing. The
claim is that the same pins give the same packages and files. Two builds
can be compared with their lists:
`diff a/clang-22.files.txt b/clang-22.files.txt` should print nothing.
`image/vm-layer.sh` names the paths it leaves out (they change on every
boot by design) and the few files it hashes without their date comment
(`n:`).

## Attestation and verification

The reusable workflow attests each manifest with SLSA build provenance and
an SPDX SBOM, both pushed next to the image. Only its `attest` job can get
a signing token; the build steps cannot. That is SLSA v1.0 Build L3,
provided the consumer verifies the signer and not only the repository:

```
gh attestation verify oci://ghcr.io/<owner>/nut-ci-omnios@sha256:<digest> \
  --repo <owner>/nut-ci-omnios \
  --signer-workflow <owner>/nut-ci-omnios/.github/workflows/build.yml \
  --source-ref refs/heads/main \
  --deny-self-hosted-runners
```

### Note for a repository with more than one maintainer

The provenance says which workflow file built the image; it cannot say
whether that file was any good. Anyone who can push to the branch the image
is built from can change the reusable workflow and get their own image
signed with the same identity. So the branch's protection is part of the
trust:

- build only from a protected `main` (or protected tags), with required
  review for changes under `image/` and `.github/workflows/`;
- in consumers, pin `--signer-digest` to the commit of a reviewed
  `build.yml`, not just `--signer-workflow`, so a later change to the
  workflow cannot sign images consumers accept until it is reviewed and the
  pin is moved;
- restrict who can write the GHCR package (link it to this repository only).

While one person maintains this repository, the branch protection is that
person's account. It matters once more people can push, for example if
networkupstools takes the build over.

## Licenses

The scripts and workflows in this repository are under the 0BSD license
(LICENSE): use them for anything, no attribution needed.

That covers this repository only, not the images it builds. An image is an
OmniOS system: illumos itself is mostly CDDL-1.0, and the packages on top
keep their own licenses (GPL and LGPL for gcc, git and bash, Apache-2.0
with the LLVM exception for clang, Apache-2.0 for OpenSSL, BSD-style for
net-snmp, and so on). `pkg info --license <package>` inside an image shows
each one. OmniOS publishes how every package is built
([omnios-build](https://github.com/omniosorg/omnios-build),
[omnios-extra](https://github.com/omniosorg/omnios-extra)), and each
image's package list names the exact builds it contains.

The tools that build the images are used, not shipped: QEMU (GPL-2.0),
cloud-utils (GPL-3.0), ORAS (Apache-2.0) and the GitHub actions (MIT).
