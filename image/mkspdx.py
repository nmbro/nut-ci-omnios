#!/usr/bin/env python3
"""mkspdx.py <name> <pkgs.txt> <licenses.txt> <base-url> <base-sha256> > sbom.spdx.json

A minimal SPDX 2.3 document for one image variant: the official base image
and every installed OmniOS package (full IPS FMRI from `pkg list -Hv`), each
with the licenses its package declares (`pkg contents -t license`).
SBOM_CREATED (ISO 8601, UTC) sets the creation time, e.g. the commit's.

OmniOS license names map to SPDX identifiers only where the name is
unambiguous. "GPLv2" could be GPL-2.0-only or -or-later, so it and every
other name become a LicenseRef-OmniOS-<name>, explained in the document;
`pkg info --license <package>` in the image prints the actual text."""
import datetime
import json
import os
import re
import sys
import uuid

name, pkgs_file, lic_file, base_url, base_sha = sys.argv[1:6]

SPDX_IDS = {
    "lic_CDDL": "CDDL-1.0", "CDDL": "CDDL-1.0",
    "MIT": "MIT", "Apache2": "Apache-2.0", "MPLv2": "MPL-2.0",
    "simplified-BSD": "BSD-2-Clause", "modified-BSD": "BSD-3-Clause",
}
refs = {}


def license_id(lic):
    lic = lic.strip()
    if lic in SPDX_IDS:
        return SPDX_IDS[lic]
    ref = "LicenseRef-OmniOS-" + re.sub(r"[^A-Za-z0-9.]+", "-", lic).strip("-")
    refs[ref] = lic
    return ref


licenses = {}
for line in open(lic_file, encoding="utf-8"):
    pkg, _, lic = line.rstrip("\n").partition("\t")
    if pkg and lic:
        licenses.setdefault(pkg, set()).add(license_id(lic))

pkgs = []
for i, line in enumerate(open(pkgs_file, encoding="utf-8")):
    fmri = line.strip()
    if not fmri:
        continue
    # pkg://<publisher>/<name>@<version>:<timestamp>
    pub, _, rest = fmri.removeprefix("pkg://").partition("/")
    pname, _, ver = rest.partition("@")
    ids = sorted(licenses.get(pname, ()))
    pkgs.append({
        "SPDXID": f"SPDXRef-Package-{i}",
        "name": pname,
        "versionInfo": ver,
        "supplier": f"Organization: {pub}",
        "downloadLocation": "NOASSERTION",
        "filesAnalyzed": False,
        "licenseConcluded": "NOASSERTION",
        "licenseDeclared": " AND ".join(ids) if ids else "NOASSERTION",
        "copyrightText": "NOASSERTION",
        "externalRefs": [{"referenceCategory": "OTHER",
                          "referenceType": "ips-fmri", "referenceLocator": fmri}],
    })
base = {
    "SPDXID": "SPDXRef-Base",
    "name": base_url.rsplit("/", 1)[-1],
    "downloadLocation": base_url,
    "filesAnalyzed": False,
    "licenseConcluded": "NOASSERTION",
    "licenseDeclared": "NOASSERTION",
    "copyrightText": "NOASSERTION",
    "checksums": [{"algorithm": "SHA256", "checksumValue": base_sha}],
}
doc = {
    "spdxVersion": "SPDX-2.3",
    "dataLicense": "CC0-1.0",
    "SPDXID": "SPDXRef-DOCUMENT",
    "name": name,
    "documentNamespace": f"https://github.com/nut-ci-omnios/spdx/{name}-{uuid.uuid4()}",
    "creationInfo": {"creators": ["Tool: nut-ci-omnios mkspdx.py"],
                     "created": os.environ.get("SBOM_CREATED") or datetime.datetime.now(
                         datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")},
    "packages": [base] + pkgs,
    "hasExtractedLicensingInfos": [{
        "licenseId": ref,
        "name": lic,
        "extractedText": f"The license OmniOS names \"{lic}\" in the package's license "
                         "action; `pkg info --license <package>` in the image prints it.",
    } for ref, lic in sorted(refs.items())],
    "relationships": [{"spdxElementId": "SPDXRef-DOCUMENT",
                       "relationshipType": "DESCRIBES", "relatedSpdxElement": "SPDXRef-Base"}]
    + [{"spdxElementId": "SPDXRef-Base", "relationshipType": "CONTAINS",
        "relatedSpdxElement": p["SPDXID"]} for p in pkgs],
}
json.dump(doc, sys.stdout, indent=1)
print()
