#!/usr/bin/env python3
"""mkspdx.py <name> <pkgs.txt> <base-url> <base-sha256> > sbom.spdx.json

A minimal SPDX 2.3 document for one image variant: the official base image
and every installed OmniOS package (full IPS FMRI from `pkg list -Hv`).
SBOM_CREATED (ISO 8601, UTC) sets the creation time, e.g. the commit's."""
import datetime
import json
import os
import sys
import uuid

name, pkgs_file, base_url, base_sha = sys.argv[1:5]
pkgs = []
for i, line in enumerate(open(pkgs_file, encoding="utf-8")):
    fmri = line.strip()
    if not fmri:
        continue
    # pkg://<publisher>/<name>@<version>:<timestamp>
    pub, _, rest = fmri.removeprefix("pkg://").partition("/")
    pname, _, ver = rest.partition("@")
    pkgs.append({
        "SPDXID": f"SPDXRef-Package-{i}",
        "name": pname,
        "versionInfo": ver,
        "supplier": f"Organization: {pub}",
        "downloadLocation": "NOASSERTION",
        "filesAnalyzed": False,
        "externalRefs": [{"referenceCategory": "OTHER",
                          "referenceType": "ips-fmri", "referenceLocator": fmri}],
    })
base = {
    "SPDXID": "SPDXRef-Base",
    "name": base_url.rsplit("/", 1)[-1],
    "downloadLocation": base_url,
    "filesAnalyzed": False,
    "checksums": [{"algorithm": "SHA256", "checksumValue": base_sha}],
}
doc = {
    "spdxVersion": "SPDX-2.3",
    "dataLicense": "CC0-1.0",
    "SPDXID": "SPDXRef-DOCUMENT",
    "name": name,
    "documentNamespace": f"https://github.com/nut-ci-omnios/spdx/{name}-{uuid.uuid4()}",
    "creationInfo": {"creators": ["Tool: nut-ci-omnios-image mkspdx.py"],
                     "created": os.environ.get("SBOM_CREATED") or datetime.datetime.now(
                         datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")},
    "packages": [base] + pkgs,
    "relationships": [{"spdxElementId": "SPDXRef-DOCUMENT",
                       "relationshipType": "DESCRIBES", "relatedSpdxElement": "SPDXRef-Base"}]
    + [{"spdxElementId": "SPDXRef-Base", "relationshipType": "CONTAINS",
        "relatedSpdxElement": p["SPDXID"]} for p in pkgs],
}
json.dump(doc, sys.stdout, indent=1)
print()
