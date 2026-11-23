#!/usr/bin/env bash
# Uploads the golden CV files as Salesforce Files and prints their ContentDocument ids.
# Usage: scripts/upload_golden_cvs.sh <org-alias> [file ...]
set -euo pipefail
ORG="${1:?org alias}"; shift
FILES=("$@")
[ ${#FILES[@]} -eq 0 ] && FILES=(data/golden-cvs/files/*)
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
for f in "${FILES[@]}"; do
  name="$(basename "$f")"
  python3 -I -c 'import base64,json,sys; p=sys.argv[1]; print(json.dumps({"Title": p.rsplit("/",1)[-1].rsplit(".",1)[0], "PathOnClient": p.rsplit("/",1)[-1], "VersionData": base64.b64encode(open(p,"rb").read()).decode()}))' "$f" > "$TMP/body.json"
  vid=$(sf api request rest "/services/data/v66.0/sobjects/ContentVersion" --method POST --body "@$TMP/body.json" --target-org "$ORG" 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["id"])')
  did=$(sf api request rest "/services/data/v66.0/sobjects/ContentVersion/$vid?fields=ContentDocumentId" --target-org "$ORG" 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["ContentDocumentId"])')
  echo "$did $name"
done
