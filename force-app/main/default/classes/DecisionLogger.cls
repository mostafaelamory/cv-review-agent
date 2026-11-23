/**
 * Audit trail. Each entry is published as Log_Event__e (publish immediately),
 * so it is stored even if the surrounding transaction rolls back; a trigger
 * turns it into an Agent_Decision_Log__c row. Logs hold ids and summaries,
 * never full CV text.
 */
public with sharing class DecisionLogger {
    public class Entry {
        public String action;
        public String requestId;
        public Set<Id> candidateIds = new Set<Id>();
        public Id jobRoleId;
        public String inputSummary;
        public String outputSummary;
        public Set<String> evidenceIds = new Set<String>();
        public String promptTemplate;
        public String groundingCheck = 'Not Applicable';
        public String outcome = 'Success';
        public String errorMessage;
        public String rawResponse;
        private Long started = System.currentTimeMillis();

        public Entry(String action) {
            this.action = action;
            this.requestId = newRequestId();
        }
        public Entry template(String name) {
            this.promptTemplate = name;
            return this;
        }
        public Entry fail(Exception e) {
            this.outcome = 'Failed';
            this.errorMessage = e.getTypeName() + ': ' + e.getMessage();
            return this;
        }
    }

    public static Entry start(String action) {
        return new Entry(action);
    }

    public static void publish(Entry e) {
        publish(new List<Entry>{ e });
    }

    public static void publish(List<Entry> entries) {
        List<Log_Event__e> events = new List<Log_Event__e>();
        for (Entry e : entries) {
            events.add(
                new Log_Event__e(
                    Action__c = JsonUtil.truncate(e.action, 80),
                    Request_Id__c = e.requestId,
                    User_Id__c = UserInfo.getUserId(),
                    Candidate_Ids__c = JsonUtil.truncate(String.join(new List<Id>(e.candidateIds), ','), 5000),
                    Job_Role_Id__c = e.jobRoleId,
                    Input_Summary__c = JsonUtil.truncate(e.inputSummary, 5000),
                    Output_Summary__c = JsonUtil.truncate(e.outputSummary, 10000),
                    Evidence_Ids__c = JsonUtil.truncate(String.join(new List<String>(e.evidenceIds), ','), 20000),
                    Prompt_Template__c = e.promptTemplate,
                    Prompt_Version__c = e.promptTemplate == null ? null : PromptCatalog.versionOf(e.promptTemplate),
                    Grounding_Check__c = e.groundingCheck,
                    Latency_ms__c = System.currentTimeMillis() - e.started,
                    Outcome__c = e.outcome,
                    Error_Message__c = JsonUtil.truncate(e.errorMessage, 5000),
                    Raw_Response__c = JsonUtil.truncate(e.rawResponse, 100000)
                )
            );
        }
        List<Database.SaveResult> results = EventBus.publish(events);
        for (Database.SaveResult r : results) {
            if (!r.isSuccess()) {
                System.debug(LoggingLevel.ERROR, 'Log_Event__e publish failed: ' + r.getErrors());
            }
        }
    }

    private static String newRequestId() {
        Blob b = Crypto.generateAesKey(128);
        return EncodingUtil.convertToHex(b).substring(0, 20);
    }
}
