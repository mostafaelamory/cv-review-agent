/**
 * Typed access to CV_Agent_Setting__mdt (record "Default"), with safe defaults
 * so the agent still works if the record is missing.
 */
public with sharing class CvAgentSettings {
    @TestVisible
    private static CV_Agent_Setting__mdt testOverride;

    public static CV_Agent_Setting__mdt get() {
        if (testOverride != null) {
            return testOverride;
        }
        CV_Agent_Setting__mdt s = CV_Agent_Setting__mdt.getInstance('Default');
        return s != null ? s : new CV_Agent_Setting__mdt(LLM_Mode__c = 'Live');
    }

    public static Boolean isStubMode() {
        return get().LLM_Mode__c == 'Stub';
    }
    public static Decimal strongThreshold() {
        return num(get().Strong_Threshold__c, 75);
    }
    public static Decimal possibleThreshold() {
        return num(get().Possible_Threshold__c, 55);
    }
    public static Decimal lowDataThreshold() {
        return num(get().Low_Data_Threshold__c, 50);
    }
    public static Integer maxInlineAssessments() {
        return num(get().Max_Inline_Assessments__c, 3).intValue();
    }
    public static Integer inlineBudgetSeconds() {
        return num(get().Inline_Budget_Seconds__c, 35).intValue();
    }
    public static Integer maxCandidatesPerQuery() {
        return num(get().Max_Candidates_Per_Query__c, 10).intValue();
    }
    public static Integer maxEvidenceRows() {
        return num(get().Max_Evidence_Rows__c, 60).intValue();
    }
    public static Integer maxAttempts() {
        return num(get().Max_Attempts__c, 3).intValue();
    }

    private static Decimal num(Decimal value, Decimal fallback) {
        return value == null ? fallback : value;
    }
}
