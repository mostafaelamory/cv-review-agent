/**
 * Scores queued candidates for a role in the background, one per job,
 * chaining to the next. Used when an upload is made from a Job Role page and
 * when a chat request exceeds the inline budget.
 */
public with sharing class CvEvaluationJob implements Queueable, Database.AllowsCallouts {
    private Id roleId;
    private List<Id> candidateIds;

    public CvEvaluationJob(Id roleId, List<Id> candidateIds) {
        this.roleId = roleId;
        this.candidateIds = candidateIds;
    }

    public void execute(QueueableContext ctx) {
        if (candidateIds == null || candidateIds.isEmpty()) {
            return;
        }
        Id next = candidateIds.remove(0);
        try {
            EvaluationService.evaluate(roleId, new List<Id>{ next }, 1, false);
        } catch (Exception e) {
            DecisionLogger.Entry log = DecisionLogger.start('Evaluate candidates (queued)').fail(e);
            log.jobRoleId = roleId;
            log.candidateIds.add(next);
            DecisionLogger.publish(log);
        }
        if (!candidateIds.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new CvEvaluationJob(roleId, candidateIds));
        }
    }
}
