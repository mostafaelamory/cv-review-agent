/** Agent action: "why did A rank above B?" computed from the two breakdowns. */
public with sharing class CvExplainRankingAction {
    public class Request {
        @InvocableVariable(required=true label='Role' description='Job role both candidates were evaluated for.')
        public String roleName;
        @InvocableVariable(required=true label='Candidate A' description='Name of the first candidate.')
        public String candidateA;
        @InvocableVariable(required=true label='Candidate B' description='Name of the second candidate.')
        public String candidateB;
    }

    public class Response {
        @InvocableVariable(label='Explanation' description='Requirements where the two candidates\' points differ, largest difference first.')
        public String explanation;
    }

    @InvocableMethod(
        label='Explain Ranking'
        description='Explains why one candidate ranked above another for a role, requirement by requirement.'
        category='CV Review'
    )
    public static List<Response> explain(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request r : requests) {
            Response res = new Response();
            try {
                res.explanation = explainOne(r);
            } catch (Exception e) {
                res.explanation = e.getMessage();
            }
            out.add(res);
        }
        return out;
    }

    private static String explainOne(Request r) {
        Job_Role__c role = CandidateResolver.resolveRole(r.roleName);
        if (role == null) {
            return 'No job role found named "' + r.roleName + '".';
        }
        CandidateResolver.Resolution res = CandidateResolver.resolve(new List<String>{ r.candidateA, r.candidateB });
        if (res.needsClarification() || res.matched.size() < 2) {
            return res.needsClarification() ? res.clarification() : 'Name two different candidates.';
        }
        Map<Id, Candidate_Evaluation__c> byCandidate = new Map<Id, Candidate_Evaluation__c>();
        for (Candidate_Evaluation__c e : [
            SELECT Candidate__c, Total_Score__c, Band__c, Breakdown_JSON__c
            FROM Candidate_Evaluation__c
            WHERE Job_Role__c = :role.Id AND Candidate__c IN :res.ids() AND Is_Current__c = TRUE
            WITH USER_MODE
        ]) {
            byCandidate.put(e.Candidate__c, e);
        }
        Candidate__c a = res.matched[0];
        Candidate__c b = res.matched[1];
        if (!byCandidate.containsKey(a.Id) || !byCandidate.containsKey(b.Id)) {
            return 'Both candidates need a current evaluation for ' + role.Name + '. Run the evaluation first.';
        }
        Candidate_Evaluation__c ea = byCandidate.get(a.Id);
        Candidate_Evaluation__c eb = byCandidate.get(b.Id);
        if (eb.Total_Score__c > ea.Total_Score__c) {
            Candidate__c tc = a;
            a = b;
            b = tc;
            Candidate_Evaluation__c te = ea;
            ea = eb;
            eb = te;
        }
        List<String> diffs = ScoringService.explainDifference(
            a.Name, EvaluationService.parseLines(ea.Breakdown_JSON__c), b.Name, EvaluationService.parseLines(eb.Breakdown_JSON__c)
        );
        String head = a.Name + ' scored ' + ea.Total_Score__c + ' (' + ea.Band__c + ') and ' + b.Name + ' scored ' +
            eb.Total_Score__c + ' (' + eb.Band__c + ') for ' + role.Name + '.';
        if (diffs.isEmpty()) {
            return head + ' Their points are the same on every requirement; the tie is broken by must-haves met, then by high-confidence evidence.';
        }
        return head + ' The difference comes from:\n- ' + String.join(diffs, '\n- ');
    }
}