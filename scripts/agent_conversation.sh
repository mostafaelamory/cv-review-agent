#!/usr/bin/env bash
# Runs a scripted conversation against the CV Review Agent (authoring bundle, live actions) and prints each reply.
# Usage: scripts/agent_conversation.sh <org-alias> "utterance 1" "utterance 2" ...
set -uo pipefail
ORG="$1"; shift
SID=$(sf agent preview start --authoring-bundle CV_Review_Agent --use-live-actions --target-org "$ORG" --json 2>/dev/null | python3 -I -c 'import json,sys;t=sys.stdin.read();print(json.loads(t[t.find("{"):])["result"]["sessionId"])')
echo "session $SID"
for u in "$@"; do
  echo; echo ">>> $u"
  sf agent preview send --authoring-bundle CV_Review_Agent --session-id "$SID" --utterance "$u" --target-org "$ORG" --json 2>/dev/null \
    | python3 -I -c 'import json,sys
t=sys.stdin.read(); d=json.loads(t[t.find("{"):])
r=d.get("result") or {}
msgs=r.get("messages") or []
for m in msgs:
    print("<<<", (m.get("message") or m.get("text") or json.dumps(m))[:1800])
if not msgs: print("RAW", json.dumps(d)[:1500])'
done
sf agent preview end --authoring-bundle CV_Review_Agent --session-id "$SID" --target-org "$ORG" --json >/dev/null 2>&1
