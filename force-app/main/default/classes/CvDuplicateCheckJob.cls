/**
 * Flags a new card as a possible duplicate of an earlier card with the same
 * email. Runs a minute after ingestion so cards created in parallel (one batch
 * holding two CVs of the same person) are committed and visible to each other.
 * Then starts the role evaluation when the CV was uploaded against a role.
 */
public with sharing class CvDuplicateCheckJob implements Queueable, Database.AllowsCallouts {
    private Id candidateId;
    private Id roleId;

    public CvDuplicateCheckJob(Id candidateId, Id roleId) {
        this.candidateId = candidateId;
        this.roleId = roleId;
    }

    public void execute(QueueableContext ctx) {
        flag(candidateId);
        if (roleId != null && !Test.isRunningTest()) {
            System.enqueueJob(new CvEvaluationJob(roleId, new List<Id>{ candidateId }));
        }
    }

    /** The earliest other card with the same email wins; ties broken by id. */
    public static void flag(Id candidateId) {
        List<Candidate__c> me = [
            SELECT Id, Email__c, CreatedDate, Possible_Duplicate_Of__c FROM Candidate__c WHERE Id = :candidateId WITH USER_MODE
        ];
        if (me.isEmpty() || me[0].Email__c == null || me[0].Possible_Duplicate_Of__c != null) {
            return;
        }
        for (Candidate__c other : [
            SELECT Id, CreatedDate FROM Candidate__c
            WHERE Email__c = :me[0].Email__c AND Id != :candidateId
            WITH USER_MODE ORDER BY CreatedDate, Id LIMIT 5
        ]) {
            if (other.CreatedDate < me[0].CreatedDate || (other.CreatedDate == me[0].CreatedDate && String.valueOf(other.Id) < String.valueOf(candidateId))) {
                update as user new Candidate__c(Id = candidateId, Possible_Duplicate_Of__c = other.Id);
                DecisionLogger.Entry log = DecisionLogger.start('Duplicate check');
                log.candidateIds.add(candidateId);
                log.outputSummary = 'Possible duplicate of ' + other.Id + ' (same email)';
                DecisionLogger.publish(log);
                return;
            }
        }
    }
}
