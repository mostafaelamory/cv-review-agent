#!/usr/bin/env bash
# Prints recent CV documents, cards and decision-log rows. Usage: scripts/check_ingestion.sh <org-alias>
ORG="${1:-HRAgent}"
q(){ sf data query -q "$1" --target-org "$ORG" --json 2>/dev/null | python3 -I -c "
import json,sys
d=json.load(sys.stdin)
if d.get('status'): print(d.get('message')); sys.exit()
for r in d['result']['records']:
    r.pop('attributes',None)
    print({k:(v if not isinstance(v,dict) else {a:b for a,b in v.items() if a!='attributes'}) for k,v in r.items()})"; }
echo '--- documents'; q "SELECT File_Name__c, Status__c, Failure_Reason__c, Extraction_Method__c, Candidate__r.Name, Candidate__r.Card_Status__c, Candidate__r.Card_Completeness__c FROM CV_Document__c ORDER BY CreatedDate DESC LIMIT 12"
echo '--- log'; q "SELECT Action__c, Outcome__c, Grounding_Check__c, Latency_ms__c, Output_Summary__c, Error_Message__c FROM Agent_Decision_Log__c ORDER BY CreatedDate DESC LIMIT 8"
echo '--- jobs'; q "SELECT ApexClass.Name, Status, ExtendedStatus FROM AsyncApexJob WHERE JobType='Queueable' ORDER BY CreatedDate DESC LIMIT 6"
