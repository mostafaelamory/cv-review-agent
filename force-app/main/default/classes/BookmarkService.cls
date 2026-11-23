/**
 * Creates the requirement-3.1 bookmark: one immutable Candidate_Bookmark__c that
 * snapshots the candidate overview, score, reasoning and the recruiter's notes.
 * Idempotent per evaluation and recruiter (Bookmark_Key__c).
 */
public with sharing class BookmarkService {
    public class Result {
        public Candidate_Bookmark__c bookmark;
        public Boolean alreadyExisted = false;
    }

    public static Result create(Id candidateId, Id roleId, String notes) {
        List<Candidate_Evaluation__c> evals = [
            SELECT Id, Total_Score__c, Band__c, Breakdown_JSON__c, Strengths__c, Concerns__c, Interview_Probes__c,
                Recommendation__c, Must_Have_Gaps__c, Low_Data__c, Job_Role__c, Job_Role__r.Name, Candidate__c
            FROM Candidate_Evaluation__c
            WHERE Candidate__c = :candidateId AND Job_Role__c = :roleId AND Is_Current__c = TRUE
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (evals.isEmpty()) {
            throw new CvAgentException('This candidate has not been evaluated for this role yet. Evaluate first, then bookmark.')
                .withCode(CvAgentException.NOT_FOUND);
        }
        Candidate_Evaluation__c ev = evals[0];
        String key = ev.Id + ':' + UserInfo.getUserId();
        Result result = new Result();
        List<Candidate_Bookmark__c> existing = [
            SELECT Id, Name, Score__c, Band__c, Notes__c, Bookmarked_At__c, Status__c
            FROM Candidate_Bookmark__c
            WHERE Bookmark_Key__c = :key
            WITH USER_MODE
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            result.bookmark = existing[0];
            result.alreadyExisted = true;
            return result;
        }

        Candidate__c c = EvidenceSelector.candidates(new Set<Id>{ candidateId }).get(candidateId);
        Candidate_Bookmark__c b = new Candidate_Bookmark__c(
            Candidate__c = candidateId,
            Job_Role__c = roleId,
            Candidate_Evaluation__c = ev.Id,
            Overview_Snapshot__c = JsonUtil.truncate(overview(c), 10000),
            Score__c = ev.Total_Score__c,
            Band__c = ev.Band__c,
            Reasoning__c = JsonUtil.truncate(reasoning(ev), 32768),
            Notes__c = JsonUtil.truncate(notes, 5000),
            Bookmarked_At__c = System.now(),
            Status__c = 'Shortlisted',
            Bookmark_Key__c = key
        );
        insert as user b;
        result.bookmark = b;

        DecisionLogger.Entry log = DecisionLogger.start('Create bookmark');
        log.candidateIds.add(candidateId);
        log.jobRoleId = roleId;
        log.inputSummary = 'Evaluation ' + ev.Id + (String.isBlank(notes) ? ', no notes' : ', with notes');
        log.outputSummary = 'Bookmark ' + b.Id + ': ' + ev.Total_Score__c + ' ' + ev.Band__c;
        DecisionLogger.publish(log);
        return result;
    }

    private static String overview(Candidate__c c) {
        List<String> lines = new List<String>{ c.Name };
        if (c.Headline__c != null) {
            lines.add(c.Headline__c);
        }
        if (c.Location__c != null) {
            lines.add('Location: ' + c.Location__c);
        }
        if (c.Total_Experience_Months__c != null) {
            lines.add('Experience (inferred from dates): ' + DateUtil.formatMonths(c.Total_Experience_Months__c.intValue()));
        }
        if (c.Summary__c != null) {
            lines.add(c.Summary__c);
        }
        lines.add('Card completeness: ' + c.Card_Completeness__c + '%' + (c.Has_Conflicts__c == true ? '; card has conflicting facts' : ''));
        return String.join(lines, '\n');
    }

    private static String reasoning(Candidate_Evaluation__c ev) {
        List<String> lines = new List<String>{
            'Score ' + ev.Total_Score__c + '/100, band ' + ev.Band__c +
            (ev.Must_Have_Gaps__c > 0 ? ', ' + ev.Must_Have_Gaps__c + ' must-have gap(s)' : '') +
            (ev.Low_Data__c == true ? ', low data' : ''),
            '',
            'Breakdown:'
        };
        for (ScoringService.Line l : EvaluationService.parseLines(ev.Breakdown_JSON__c)) {
            lines.add(
                '- ' + l.requirement + ' (' + l.type + '): ' + l.match + (l.confidence == null ? '' : ', ' + l.confidence) +
                ', ' + l.pointsEarned + '/' + l.pointsPossible + ' pts' + (String.isBlank(l.rationale) ? '' : '. ' + l.rationale)
            );
        }
        if (ev.Strengths__c != null) {
            lines.add('\nStrengths:\n' + ev.Strengths__c);
        }
        if (ev.Concerns__c != null) {
            lines.add('\nConcerns:\n' + ev.Concerns__c);
        }
        if (ev.Interview_Probes__c != null) {
            lines.add('\nInterview probes:\n' + ev.Interview_Probes__c);
        }
        if (ev.Recommendation__c != null) {
            lines.add('\nRecommendation:\n' + ev.Recommendation__c);
        }
        return String.join(lines, '\n');
    }
}
