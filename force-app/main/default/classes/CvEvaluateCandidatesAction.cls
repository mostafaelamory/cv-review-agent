/**
 * Agent action: score and rank candidates for a role, with a recommendation.
 * The ranking is returned as structured data and drawn by the
 * evaluationResult custom Lightning type, so the model cannot reword it.
 */
public with sharing class CvEvaluateCandidatesAction {
    public class Request {
        @InvocableVariable(required=true label='Role' description='Name of the job role to evaluate against, e.g. "Senior Salesforce Developer".')
        public String roleName;
        @InvocableVariable(label='Candidate Names' description='Comma-separated candidate names. Leave empty to evaluate every candidate uploaded for or already scored against the role.')
        public String candidateNames;
    }

    public class Response {
        @InvocableVariable(label='Evaluation Result' description='Ranked table for display.')
        public EvaluationResult evaluationResult;
        @InvocableVariable(label='Summary' description='Plain-text ranking, recommendation, trade-offs and gaps. Use it to answer follow-up questions.')
        public String summary;
        @InvocableVariable(label='Has Evaluation' description='True when at least one candidate has a score for this role.')
        public Boolean hasEvaluation;
        @InvocableVariable(label='Top Candidate' description='Name of the top-ranked candidate.')
        public String topCandidate;
        @InvocableVariable(label='Needs Clarification' description='True when the role or a candidate name was ambiguous or not found.')
        public Boolean needsClarification;
    }

    /** Shape of the evaluationResult Lightning type. */
    public class EvaluationResult {
        @AuraEnabled public String roleName;
        @AuraEnabled public String roleId;
        @AuraEnabled public String recommendation;
        @AuraEnabled public String tradeOffs;
        @AuraEnabled public Boolean anyStrong;
        @AuraEnabled public List<Row> rows;
        @AuraEnabled public List<String> pending;
        @AuraEnabled public List<String> failed;
    }

    public class Row {
        @AuraEnabled public Integer rank;
        @AuraEnabled public String candidateId;
        @AuraEnabled public String candidateName;
        @AuraEnabled public String evaluationId;
        @AuraEnabled public Decimal score;
        @AuraEnabled public String band;
        @AuraEnabled public Integer mustHaveGaps;
        @AuraEnabled public Boolean lowData;
        @AuraEnabled public Boolean gated;
        @AuraEnabled public String strengths;
        @AuraEnabled public String concerns;
        @AuraEnabled public String interviewProbes;
        @AuraEnabled public List<BreakdownLine> breakdown;
    }

    public class BreakdownLine {
        @AuraEnabled public String requirement;
        @AuraEnabled public String type;
        @AuraEnabled public String match;
        @AuraEnabled public String confidence;
        @AuraEnabled public Decimal pointsEarned;
        @AuraEnabled public Decimal pointsPossible;
        @AuraEnabled public String rationale;
    }

    @InvocableMethod(
        label='Evaluate Candidates'
        description='Scores candidates against a job role, ranks them, and recommends with strengths, concerns and interview probes.'
        category='CV Review'
    )
    public static List<Response> evaluate(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request r : requests) {
            out.add(evaluateOne(r));
        }
        return out;
    }

    private static Response evaluateOne(Request r) {
        Response res = new Response();
        res.hasEvaluation = false;
        res.needsClarification = false;
        try {
            Job_Role__c role = CandidateResolver.resolveRole(r.roleName);
            if (role == null) {
                res.needsClarification = true;
                res.summary = 'No job role found named "' + r.roleName + '". Check the role name, or create the role with its requirements first.';
                return res;
            }
            Integer max = CvAgentSettings.maxCandidatesPerQuery();
            List<Id> ids = new List<Id>();
            List<String> names = CandidateResolver.splitNames(r.candidateNames);
            if (names.isEmpty()) {
                for (Candidate__c c : CandidateResolver.forRole(role.Id, max)) {
                    ids.add(c.Id);
                }
                if (ids.isEmpty()) {
                    res.needsClarification = true;
                    res.summary = 'No candidates are linked to "' + role.Name + '" yet. Name the candidates to evaluate.';
                    return res;
                }
            } else {
                CandidateResolver.Resolution resolution = CandidateResolver.resolve(names);
                if (resolution.needsClarification()) {
                    res.needsClarification = true;
                    res.summary = resolution.clarification();
                    return res;
                }
                for (Candidate__c c : resolution.matched) {
                    if (ids.size() < max) {
                        ids.add(c.Id);
                    }
                }
            }
            EvaluationService.Outcome outcome = EvaluationService.evaluate(role.Id, ids, CvAgentSettings.maxInlineAssessments(), true);
            res.evaluationResult = toResult(outcome);
            res.summary = toSummary(outcome);
            res.hasEvaluation = !outcome.ranked.isEmpty();
            res.topCandidate = outcome.ranked.isEmpty() ? null : outcome.ranked[0].candidate.Name;
        } catch (CvAgentException e) {
            res.needsClarification = e.code == CvAgentException.NOT_FOUND;
            res.summary = e.getMessage();
        } catch (Exception e) {
            res.summary = 'The evaluation failed: ' + e.getMessage();
        }
        return res;
    }

    @TestVisible
    private static EvaluationResult toResult(EvaluationService.Outcome o) {
        EvaluationResult er = new EvaluationResult();
        er.roleName = o.role.Name;
        er.roleId = o.role.Id;
        er.recommendation = o.recommendation;
        er.tradeOffs = o.tradeOffs;
        er.anyStrong = o.anyStrong;
        er.rows = new List<Row>();
        er.pending = new List<String>();
        er.failed = new List<String>();
        for (EvaluationService.CandidateResult cr : o.ranked) {
            Row row = new Row();
            row.rank = cr.rank;
            row.candidateId = cr.candidate.Id;
            row.candidateName = cr.candidate.Name;
            row.evaluationId = cr.evaluation.Id;
            row.score = cr.score.total;
            row.band = cr.score.band;
            row.mustHaveGaps = cr.score.mustHaveGaps;
            row.lowData = cr.score.lowData;
            row.gated = cr.score.gated;
            row.strengths = cr.evaluation.Strengths__c;
            row.concerns = cr.evaluation.Concerns__c;
            row.interviewProbes = cr.evaluation.Interview_Probes__c;
            row.breakdown = new List<BreakdownLine>();
            for (ScoringService.Line l : cr.score.lines) {
                BreakdownLine b = new BreakdownLine();
                b.requirement = l.requirement;
                b.type = l.type;
                b.match = l.match;
                b.confidence = l.confidence;
                b.pointsEarned = l.pointsEarned;
                b.pointsPossible = l.pointsPossible;
                b.rationale = l.rationale;
                row.breakdown.add(b);
            }
            er.rows.add(row);
        }
        for (EvaluationService.CandidateResult cr : o.queued) {
            er.pending.add(cr.candidate.Name);
        }
        for (EvaluationService.CandidateResult cr : o.failed) {
            er.failed.add(cr.candidate.Name + ': ' + cr.error);
        }
        return er;
    }

    @TestVisible
    private static String toSummary(EvaluationService.Outcome o) {
        List<String> lines = new List<String>{ 'Role: ' + o.role.Name };
        for (EvaluationService.CandidateResult cr : o.ranked) {
            List<String> gaps = new List<String>();
            for (ScoringService.Line l : cr.score.lines) {
                if (l.type == 'Must-have' && (l.match == ScoringService.NOT_EVIDENCED || l.match == ScoringService.CONTRADICTED)) {
                    gaps.add(l.requirement);
                }
            }
            lines.add(
                cr.rank + '. ' + cr.candidate.Name + ': ' + cr.score.total + '/100, ' + cr.score.band +
                (cr.score.gated ? ' (capped: must-have gap)' : '') +
                (cr.score.lowData ? ' (low data: card ' + cr.candidate.Card_Completeness__c + '% complete)' : '') +
                (gaps.isEmpty() ? '' : '. Must-have gaps: ' + String.join(gaps, ', '))
            );
        }
        if (!o.ranked.isEmpty() && !o.anyStrong) {
            lines.add('No candidate is a Strong match. ' + o.ranked[0].candidate.Name + ' is the best available option.');
        }
        if (String.isNotBlank(o.recommendation)) {
            lines.add('Recommendation: ' + o.recommendation);
        }
        if (String.isNotBlank(o.tradeOffs)) {
            lines.add('Trade-offs: ' + o.tradeOffs);
        }
        for (EvaluationService.CandidateResult cr : o.ranked) {
            if (String.isNotBlank(cr.evaluation.Interview_Probes__c)) {
                lines.add('Interview probes for ' + cr.candidate.Name + ':\n' + cr.evaluation.Interview_Probes__c);
            }
        }
        if (!o.queued.isEmpty()) {
            List<String> names = new List<String>();
            for (EvaluationService.CandidateResult cr : o.queued) {
                names.add(cr.candidate.Name);
            }
            lines.add('Still being scored in the background: ' + String.join(names, ', ') + '. Ask again in a minute.');
        }
        for (EvaluationService.CandidateResult cr : o.failed) {
            lines.add('Could not score ' + cr.candidate.Name + ': ' + cr.error);
        }
        return String.join(lines, '\n');
    }
}