"""Scores the live ingestion of the golden CV set against data/golden-cvs/expected.json.

Usage: python3 scripts/golden_set_check.py <org-alias>
Reports per-file checks plus: field accuracy, skill recall, quote-verification rate, gap and conflict detection.
"""
import json
import subprocess
import sys

ORG = sys.argv[1] if len(sys.argv) > 1 else "HRAgent"
EXPECTED = json.load(open("data/golden-cvs/expected.json"))


def query(soql):
    out = subprocess.run(["sf", "data", "query", "-q", soql, "--target-org", ORG, "--json"], capture_output=True, text=True)
    return json.loads(out.stdout)["result"]["records"]


docs = {d["File_Name__c"]: d for d in query(
    "SELECT File_Name__c, Status__c, Failure_Reason__c, Candidate__c, Candidate__r.Name, Candidate__r.Email__c, "
    "Candidate__r.Has_Conflicts__c, Candidate__r.Possible_Duplicate_Of__c, Candidate__r.Card_Completeness__c "
    "FROM CV_Document__c WHERE Status__c != 'Duplicate'")}
evidence = query("SELECT Candidate__c, Category__c, Attribute__c, Value__c, Status__c, Quote_Verified__c FROM Candidate_Evidence__c")

totals = {"fields": [0, 0], "skills": [0, 0], "quotes": [0, 0], "gaps": [0, 0], "conflicts": [0, 0]}


def tally(key, ok):
    totals[key][0] += 1 if ok else 0
    totals[key][1] += 1


for name, exp in EXPECTED.items():
    d = docs.get(name)
    lines = []
    if d is None:
        print(f"{name}: NOT FOUND")
        continue
    ok_status = d["Status__c"] in (exp["status"], "Needs Review" if exp["status"] == "Extracted" else exp["status"])
    lines.append(f"status {d['Status__c']} {'ok' if ok_status else 'EXPECTED ' + exp['status']}")
    if "reason" in exp:
        lines.append("reason ok" if exp["reason"] in (d.get("Failure_Reason__c") or "") else "reason WRONG")
    cand = d.get("Candidate__r")
    if cand and "name" in exp:
        rows = [e for e in evidence if e["Candidate__c"] == d["Candidate__c"]]
        for field, actual in (("name", cand["Name"]), ("email", cand["Email__c"])):
            tally("fields", actual == exp[field])
            if actual != exp[field]:
                lines.append(f"{field} {actual!r} EXPECTED {exp[field]!r}")
        values = " | ".join((e["Value__c"] or "").lower() for e in rows if e["Category__c"] == "Skill")
        missed = [s for s in exp["skills"] if s.lower() not in values]
        for s in exp["skills"]:
            tally("skills", s not in missed)
        stated = [e for e in rows if e["Status__c"] in ("Stated", "Conflicting") and e["Attribute__c"] not in ("Total experience",)]
        for e in stated:
            tally("quotes", e["Quote_Verified__c"])
        gaps = {e["Attribute__c"] for e in rows if e["Status__c"] == "Missing"}
        for g in exp.get("missing", []):
            tally("gaps", g in gaps or any(g.lower() in x.lower() for x in gaps))
        tally("conflicts", bool(cand["Has_Conflicts__c"]) == exp["conflicts"])
        if exp.get("overlap"):
            has = any(e["Attribute__c"] == "Overlapping roles" for e in rows)
            tally("gaps", has)
            lines.append("overlap flagged" if has else "overlap MISSED")
        if exp.get("possible_duplicate"):
            lines.append("duplicate flagged" if cand.get("Possible_Duplicate_Of__c") else "duplicate MISSED")
        lines.append(f"completeness {cand['Card_Completeness__c']}%, skills missed {missed or 'none'}, unexpected gaps {sorted(gaps - set(exp.get('missing', [])))}")
    print(f"{name}: " + "; ".join(lines))

print()
for k, (good, n) in totals.items():
    print(f"{k:10s} {good}/{n} = {100 * good / n:.0f}%" if n else f"{k:10s} n/a")
