/**
 * Writes Agent_Decision_Log__c rows from Log_Event__e. Runs as the Automated
 * Process user, so it writes in system mode by design: the log must be stored
 * whatever the acting user can edit.
 */
public without sharing class LogEventTriggerHandler {
    public static void handle(List<Log_Event__e> events) {
        List<Agent_Decision_Log__c> rows = new List<Agent_Decision_Log__c>();
        for (Log_Event__e e : events) {
            rows.add(
                new Agent_Decision_Log__c(
                    Action__c = e.Action__c,
                    Request_Id__c = e.Request_Id__c,
                    User__c = idOf(e.User_Id__c, User.SObjectType),
                    Candidate_Ids__c = e.Candidate_Ids__c,
                    Job_Role__c = idOf(e.Job_Role_Id__c, Job_Role__c.SObjectType),
                    Input_Summary__c = e.Input_Summary__c,
                    Output_Summary__c = e.Output_Summary__c,
                    Evidence_Ids__c = e.Evidence_Ids__c,
                    Prompt_Template__c = e.Prompt_Template__c,
                    Prompt_Version__c = e.Prompt_Version__c,
                    Grounding_Check__c = e.Grounding_Check__c,
                    Latency_ms__c = e.Latency_ms__c,
                    Outcome__c = e.Outcome__c,
                    Error_Message__c = e.Error_Message__c,
                    Raw_Response__c = e.Raw_Response__c
                )
            );
        }
        // allOrNone=false: one bad row must not lose the rest of the batch.
        Database.insert(rows, false);
    }

    private static Id idOf(String value, Schema.SObjectType expected) {
        try {
            Id candidate = (Id) value;
            return candidate != null && candidate.getSobjectType() == expected ? candidate : null;
        } catch (Exception e) {
            return null;
        }
    }
}
