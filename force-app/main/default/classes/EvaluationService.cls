/**
 * Scores candidates against a role and writes the recommendation.
 *
 * 1. Per-requirement judgement (CV_Assess_Requirements), one call per candidate,
 *    on blind evidence: no contact details, no name. Apex validates every cited
 *    evidence id and downgrades unsupported Met/Partial to Not evidenced.
 *    Requirements with Min_Years__c are decided here from merged date ranges.
 * 2. Deterministic score, bands and gates (ScoringService).
 * 3. One recommendation call per comparison (CV_Recommend).
 *
 * An evaluation is reused while its Input_Hash__c (evidence, requirements,
 * prompt version, thresholds) is unchanged. Only a few candidates are assessed
 * inline, within a time budget; the rest are queued.
 */
public with sharing class EvaluationService {
    public static final String STATUS_SCORED = 'Scored';
    public static final String STATUS_CACHED = 'Cached';
    public static final String STATUS_QUEUED = 'Queued';
    public static final String STATUS_FAILED = 'Failed';
    private static final Integer MAX_EVIDENCE_PER_ASSESSMENT = 90;

    public class CandidateResult {
        public Candidate__c candidate;
        public String status;
        public String error;
        public ScoringService.Score score;
        public Candidate_Evaluation__c evaluation;
        public Integer rank;
        public String alias;
        public String rawAssessment;
    }

    public class Outcome {
        public Job_Role__c role;
        public List<CandidateResult> ranked = new List<CandidateResult>();
        public List<CandidateResult> queued = new List<CandidateResult>();
        public List<CandidateResult> failed = new List<CandidateResult>();
        public String recommendation;
        public String tradeOffs;
        public Boolean anyStrong = false;
    }

    public static Outcome evaluate(Id roleId, List<Id> candidateIds, Integer maxInline, Boolean withRecommendation) {
        Long started = System.currentTimeMillis();
        Long budgetMs = CvAgentSettings.inlineBudgetSeconds() * 1000L;
        DecisionLogger.Entry log = DecisionLogger.start('Evaluate candidates').template(PromptCatalog.ASSESS_REQUIREMENTS);
        log.jobRoleId = roleId;
        log.candidateIds.addAll(candidateIds);

        Outcome out = new Outcome();
        out.role = EvidenceSelector.role(roleId);
        List<Role_Requirement__c> reqs = out.role.Requirements__r;
        if (reqs == null || reqs.isEmpty()) {
            throw new CvAgentException('The role "' + out.role.Name + '" has no requirements yet. Add requirements before scoring.')
                .withCode(CvAgentException.NOT_FOUND);
        }
        log.inputSummary = out.role.Name + ': ' + reqs.size() + ' requirements, ' + candidateIds.size() + ' candidate(s)';

        Map<Id, Candidate__c> candidates = EvidenceSelector.candidates(new Set<Id>(candidateIds));
        Map<Id, List<Candidate_Evidence__c>> evidenceByCandidate = new Map<Id, List<Candidate_Evidence__c>>();
        for (Candidate_Evidence__c ev : EvidenceSelector.forCandidates(candidates.keySet())) {
            if (!evidenceByCandidate.containsKey(ev.Candidate__c)) {
                evidenceByCandidate.put(ev.Candidate__c, new List<Candidate_Evidence__c>());
            }
            evidenceByCandidate.get(ev.Candidate__c).add(ev);
        }
        Map<Id, Candidate_Evaluation__c> current = new Map<Id, Candidate_Evaluation__c>();
        for (Candidate_Evaluation__c e : [
            SELECT Id, Candidate__c, Total_Score__c, Band__c, Must_Have_Gaps__c, Must_Haves_Met__c, High_Confidence_Evidence__c,
                Low_Data__c, Breakdown_JSON__c, Strengths__c, Concerns__c, Interview_Probes__c, Recommendation__c, Input_Hash__c
            FROM Candidate_Evaluation__c
            WHERE Job_Role__c = :roleId AND Candidate__c IN :candidates.keySet() AND Is_Current__c = TRUE
            WITH USER_MODE
        ]) {
            current.put(e.Candidate__c, e);
        }

        ILlmService llm = LlmServiceFactory.get();
        Integer inlineDone = 0;
        List<CandidateResult> scored = new List<CandidateResult>();
        for (Id cid : candidateIds) {
            Candidate__c c = candidates.get(cid);
            if (c == null) {
                continue;
            }
            List<Candidate_Evidence__c> evidence = evidenceByCandidate.containsKey(cid)
                ? evidenceByCandidate.get(cid)
                : new List<Candidate_Evidence__c>();
            String hash = inputHash(evidence, reqs);
            CandidateResult r = new CandidateResult();
            r.candidate = c;

            Candidate_Evaluation__c existing = current.get(cid);
            if (existing != null && existing.Input_Hash__c == hash) {
                r.status = STATUS_CACHED;
                r.evaluation = existing;
                r.score = fromEvaluation(existing);
                scored.add(r);
                continue;
            }
            Boolean overBudget = System.currentTimeMillis() - started > budgetMs;
            if (inlineDone >= maxInline || overBudget) {
                r.status = STATUS_QUEUED;
                out.queued.add(r);
                continue;
            }
            try {
                Map<Id, ScoringService.Assessment> assessments = assess(llm, reqs, evidence, r);
                Map<Id, Candidate_Evidence__c> evidenceById = new Map<Id, Candidate_Evidence__c>(evidence);
                r.score = ScoringService.score(reqs, assessments, evidenceById, c.Card_Completeness__c);
                r.evaluation = new Candidate_Evaluation__c(
                    Candidate__c = cid,
                    Job_Role__c = roleId,
                    Total_Score__c = r.score.total,
                    Band__c = r.score.band,
                    Must_Have_Gaps__c = r.score.mustHaveGaps,
                    Must_Haves_Met__c = r.score.mustHavesMet,
                    High_Confidence_Evidence__c = r.score.highConfidenceEvidence,
                    Low_Data__c = r.score.lowData,
                    Breakdown_JSON__c = JSON.serialize(r.score.lines),
                    Input_Hash__c = hash,
                    Prompt_Version__c = PromptCatalog.versionOf(PromptCatalog.ASSESS_REQUIREMENTS),
                    Is_Current__c = true
                );
                for (ScoringService.Line l : r.score.lines) {
                    for (Id evId : l.evidenceIds) {
                        log.evidenceIds.add(evId);
                    }
                }
                r.status = STATUS_SCORED;
                scored.add(r);
                inlineDone++;
            } catch (CvAgentException e) {
                r.status = STATUS_FAILED;
                r.error = e.getMessage();
                out.failed.add(r);
            }
        }

        // Rank, then recommend, then write: model calls before DML.
        rank(scored);
        out.ranked = scored;
        for (CandidateResult r : scored) {
            out.anyStrong = out.anyStrong || r.score.band == 'Strong';
        }
        if (withRecommendation && !scored.isEmpty()) {
            recommend(llm, out, log);
        }
        save(out, current);

        if (!out.queued.isEmpty()) {
            List<Id> queuedIds = new List<Id>();
            for (CandidateResult r : out.queued) {
                queuedIds.add(r.candidate.Id);
            }
            System.enqueueJob(new CvEvaluationJob(roleId, queuedIds));
        }

        log.outcome = out.failed.isEmpty() ? 'Success' : (scored.isEmpty() ? 'Failed' : 'Partial');
        log.groundingCheck = 'Passed';
        log.outputSummary = summaryForLog(out);
        DecisionLogger.publish(log);
        return out;
    }

    /** Calls CV_Assess_Requirements and validates the result against this candidate's evidence. */
    private static Map<Id, ScoringService.Assessment> assess(
        ILlmService llm,
        List<Role_Requirement__c> reqs,
        List<Candidate_Evidence__c> evidence,
        CandidateResult r
    ) {
        Map<Id, ScoringService.Assessment> out = new Map<Id, ScoringService.Assessment>();
        Map<String, Id> evidenceByAlias = new Map<String, Id>();
        List<String> evLines = new List<String>();
        List<String> gaps = new List<String>();
        Integer n = 0;
        for (Candidate_Evidence__c ev : evidence) {
            if (ev.Category__c == 'Contact') {
                continue; // blind assessment
            }
            if (ev.Status__c == 'Missing') {
                gaps.add('- ' + ev.Category__c + ': ' + ev.Attribute__c);
                continue;
            }
            if (!isScorable(ev) || n >= MAX_EVIDENCE_PER_ASSESSMENT) {
                continue;
            }
            String alias = 'E' + (++n);
            evidenceByAlias.put(alias, ev.Id);
            evLines.add('[' + alias + '] ' + EvidenceFormatter.line(ev, false));
        }

        Map<String, Role_Requirement__c> reqByAlias = new Map<String, Role_Requirement__c>();
        List<String> reqLines = new List<String>();
        Integer i = 0;
        for (Role_Requirement__c req : reqs) {
            String alias = 'R' + (++i);
            if (req.Min_Years__c != null && req.Min_Years__c > 0) {
                out.put(req.Id, yearsAssessment(req, evidence));
                continue;
            }
            reqByAlias.put(alias, req);
            reqLines.add(
                '[' + alias + '] (' + req.Type__c + (req.Category__c == null ? '' : ', ' + req.Category__c) + '): ' +
                req.Requirement__c + (String.isBlank(req.Keywords__c) ? '' : ' [also matches: ' + req.Keywords__c + ']')
            );
        }
        if (reqByAlias.isEmpty()) {
            return out;
        }

        LlmModels.Response res = llm.generate(
            new LlmModels.Request(PromptCatalog.ASSESS_REQUIREMENTS)
                .put('Requirements', String.join(reqLines, '\n'))
                .put('Evidence', evLines.isEmpty() ? '(no evidence)' : String.join(evLines, '\n'))
                .put('Known_Gaps', gaps.isEmpty() ? '(none)' : String.join(gaps, '\n'))
                .put('Skill_Aliases', SkillAliases.asPromptText())
        );
        r.rawAssessment = res.text;
        Map<String, Object> parsed = JsonUtil.parseObject(res.text);
        for (Object o : JsonUtil.arr(parsed, 'assessments')) {
            Map<String, Object> m = JsonUtil.obj(o);
            Role_Requirement__c req = reqByAlias.get(JsonUtil.str(m, 'requirement'));
            if (req == null) {
                continue;
            }
            ScoringService.Assessment a = new ScoringService.Assessment();
            a.match = normalizeMatch(JsonUtil.str(m, 'match'));
            a.rationale = JsonUtil.truncate(JsonUtil.str(m, 'rationale'), 400);
            for (String alias : JsonUtil.strings(m, 'evidence')) {
                Id evId = evidenceByAlias.get(alias.removeStart('[').removeEnd(']'));
                if (evId != null && !a.evidenceIds.contains(evId)) {
                    a.evidenceIds.add(evId);
                }
            }
            if (a.match != ScoringService.NOT_EVIDENCED && a.evidenceIds.isEmpty()) {
                a.rationale = (a.rationale == null ? '' : a.rationale + ' ') + '(Downgraded: no valid evidence was cited.)';
                a.match = ScoringService.NOT_EVIDENCED;
            }
            out.put(req.Id, a);
        }
        for (Role_Requirement__c req : reqByAlias.values()) {
            if (!out.containsKey(req.Id)) {
                ScoringService.Assessment a = new ScoringService.Assessment();
                a.rationale = 'Not assessed by the model; treated as not evidenced.';
                out.put(req.Id, a);
            }
        }
        return out;
    }

    /** Years requirements are decided from merged date ranges of matching roles. */
    @TestVisible
    private static ScoringService.Assessment yearsAssessment(Role_Requirement__c req, List<Candidate_Evidence__c> evidence) {
        List<String> keywords = new List<String>();
        if (String.isNotBlank(req.Keywords__c)) {
            for (String k : req.Keywords__c.split(',')) {
                if (String.isNotBlank(k)) {
                    keywords.add(k.trim().toLowerCase());
                }
            }
        }
        List<List<Date>> ranges = new List<List<Date>>();
        ScoringService.Assessment a = new ScoringService.Assessment();
        a.decidedBy = 'Apex date maths';
        for (Candidate_Evidence__c ev : evidence) {
            if (ev.Category__c != 'Experience' || ev.Start_Date__c == null || ev.End_Date__c == null ||
                ev.Status__c == 'Missing' || !isScorable(ev) ||
                ev.Attribute__c == 'Total experience' || ev.Attribute__c == 'Overlapping roles') {
                continue;
            }
            String hay = SkillAliases.expand(
                ((ev.Value__c == null ? '' : ev.Value__c) + ' ' + (ev.Organization__c == null ? '' : ev.Organization__c) + ' ' +
                (ev.Detail__c == null ? '' : ev.Detail__c)).toLowerCase()
            );
            Boolean matches = keywords.isEmpty();
            for (String k : keywords) {
                matches = matches || hay.contains(k);
            }
            if (matches) {
                ranges.add(new List<Date>{ ev.Start_Date__c, ev.End_Date__c });
                a.evidenceIds.add(ev.Id);
            }
        }
        Decimal years = (Decimal.valueOf(DateUtil.mergedMonths(ranges)) / 12).setScale(1);
        if (years >= req.Min_Years__c) {
            a.match = ScoringService.MET;
        } else if (years >= req.Min_Years__c / 2 && years > 0) {
            a.match = ScoringService.PARTIAL;
        } else {
            a.match = ScoringService.NOT_EVIDENCED;
        }
        a.rationale =
            years + ' years across ' + a.evidenceIds.size() + ' matching dated role(s); ' + req.Min_Years__c + ' required' +
            (keywords.isEmpty() ? '.' : ' (roles mentioning ' + String.join(keywords, ', ') + ').');
        return a;
    }

    /** Unverified quotes are excluded from scoring; recruiter-verified facts always count. */
    public static Boolean isScorable(Candidate_Evidence__c ev) {
        if (ev.Recruiter_Verified__c == true) {
            return true;
        }
        return !(ev.Status__c == 'Stated' && ev.Quote_Verified__c != true);
    }

    private static void recommend(ILlmService llm, Outcome out, DecisionLogger.Entry log) {
        List<String> lines = new List<String>();
        Map<String, CandidateResult> byAlias = new Map<String, CandidateResult>();
        Integer i = 0;
        for (CandidateResult r : out.ranked) {
            r.alias = 'C' + (++i);
            byAlias.put(r.alias, r);
            List<String> breakdown = new List<String>();
            for (ScoringService.Line l : linesOf(r)) {
                breakdown.add(
                    '  - ' + l.requirement + ' (' + l.type + '): ' + l.match +
                    (l.confidence == null ? '' : ', ' + l.confidence + ' confidence') +
                    ', ' + l.pointsEarned + '/' + l.pointsPossible + ' pts' +
                    (String.isBlank(l.rationale) ? '' : '. ' + l.rationale)
                );
            }
            lines.add(
                '[' + r.alias + '] ' + r.candidate.Name + ': rank ' + r.rank + ', score ' + r.score.total + ' (' + r.score.band + ')' +
                (r.score.gated ? ', capped by a must-have gap' : '') +
                (r.score.lowData ? ', LOW DATA: card ' + r.candidate.Card_Completeness__c + '% complete' : '') +
                (r.candidate.Has_Conflicts__c == true ? ', card has conflicting facts' : '') +
                '\n' + String.join(breakdown, '\n')
            );
        }
        LlmModels.Response res;
        try {
            res = llm.generate(
                new LlmModels.Request(PromptCatalog.RECOMMEND)
                    .put('Role', out.role.Name + (String.isBlank(out.role.Description__c) ? '' : '\n' + out.role.Description__c.left(1500)))
                    .put('Ranking', String.join(lines, '\n\n'))
                    .put('Any_Strong', out.anyStrong ? 'yes' : 'no')
            );
            Map<String, Object> parsed = JsonUtil.parseObject(res.text);
            out.recommendation = stripAliases(JsonUtil.str(parsed, 'recommendation'));
            out.tradeOffs = stripAliases(JsonUtil.str(parsed, 'trade_offs'));
            for (Object o : JsonUtil.arr(parsed, 'candidates')) {
                Map<String, Object> m = JsonUtil.obj(o);
                CandidateResult r = byAlias.get(JsonUtil.str(m, 'id'));
                if (r == null) {
                    continue;
                }
                r.evaluation.Strengths__c = stripAliases(bullets(JsonUtil.strings(m, 'strengths')));
                r.evaluation.Concerns__c = stripAliases(bullets(JsonUtil.strings(m, 'concerns')));
                r.evaluation.Interview_Probes__c = stripAliases(bullets(JsonUtil.strings(m, 'interview_probes')));
            }
            for (CandidateResult r : out.ranked) {
                r.evaluation.Recommendation__c = JsonUtil.truncate(
                    (out.recommendation == null ? '' : out.recommendation) +
                    (String.isBlank(out.tradeOffs) ? '' : '\n\nTrade-offs: ' + out.tradeOffs),
                    10000
                );
            }
        } catch (CvAgentException e) {
            // The ranking stands on its own; say so instead of failing the turn.
            out.recommendation = 'The written recommendation is unavailable right now (' + e.getMessage() +
                '). The ranking and breakdown below are computed and complete.';
            log.errorMessage = e.getMessage();
        }
    }

    private static void save(Outcome out, Map<Id, Candidate_Evaluation__c> current) {
        List<Candidate_Evaluation__c> toInsert = new List<Candidate_Evaluation__c>();
        List<Candidate_Evaluation__c> toUpdate = new List<Candidate_Evaluation__c>();
        for (CandidateResult r : out.ranked) {
            if (r.status == STATUS_SCORED) {
                toInsert.add(r.evaluation);
                Candidate_Evaluation__c old = current.get(r.candidate.Id);
                if (old != null) {
                    toUpdate.add(new Candidate_Evaluation__c(Id = old.Id, Is_Current__c = false));
                }
            } else if (r.status == STATUS_CACHED && r.evaluation.Id != null) {
                // Only the recommendation text changes; never write back the queried record.
                toUpdate.add(
                    new Candidate_Evaluation__c(
                        Id = r.evaluation.Id,
                        Strengths__c = r.evaluation.Strengths__c,
                        Concerns__c = r.evaluation.Concerns__c,
                        Interview_Probes__c = r.evaluation.Interview_Probes__c,
                        Recommendation__c = r.evaluation.Recommendation__c
                    )
                );
            }
        }
        update as user toUpdate;
        insert as user toInsert;
    }

    private static void rank(List<CandidateResult> results) {
        // Insertion sort with the ScoringService comparator; lists are small.
        for (Integer i = 1; i < results.size(); i++) {
            CandidateResult cur = results[i];
            Integer j = i - 1;
            while (j >= 0 && ScoringService.compare(results[j].score, cur.score) > 0) {
                results[j + 1] = results[j];
                j--;
            }
            results[j + 1] = cur;
        }
        for (Integer i = 0; i < results.size(); i++) {
            results[i].rank = i + 1;
        }
    }

    public static ScoringService.Score fromEvaluation(Candidate_Evaluation__c e) {
        ScoringService.Score s = new ScoringService.Score();
        s.total = e.Total_Score__c == null ? 0 : e.Total_Score__c;
        s.band = e.Band__c;
        s.mustHaveGaps = e.Must_Have_Gaps__c == null ? 0 : e.Must_Have_Gaps__c.intValue();
        s.mustHavesMet = e.Must_Haves_Met__c == null ? 0 : e.Must_Haves_Met__c.intValue();
        s.highConfidenceEvidence = e.High_Confidence_Evidence__c == null ? 0 : e.High_Confidence_Evidence__c.intValue();
        s.lowData = e.Low_Data__c == true;
        s.lines = parseLines(e.Breakdown_JSON__c);
        return s;
    }

    public static List<ScoringService.Line> parseLines(String breakdownJson) {
        if (String.isBlank(breakdownJson)) {
            return new List<ScoringService.Line>();
        }
        return (List<ScoringService.Line>) JSON.deserialize(breakdownJson, List<ScoringService.Line>.class);
    }

    private static List<ScoringService.Line> linesOf(CandidateResult r) {
        return r.score.lines == null ? new List<ScoringService.Line>() : r.score.lines;
    }

    /** Cache key: what the evidence and requirements are now, plus prompt version and thresholds. */
    @TestVisible
    private static String inputHash(List<Candidate_Evidence__c> evidence, List<Role_Requirement__c> reqs) {
        List<String> parts = new List<String>();
        for (Candidate_Evidence__c ev : evidence) {
            parts.add(ev.Id + ':' + (ev.LastModifiedDate == null ? '' : String.valueOf(ev.LastModifiedDate.getTime())));
        }
        for (Role_Requirement__c r : reqs) {
            parts.add(r.Id + ':' + (r.LastModifiedDate == null ? '' : String.valueOf(r.LastModifiedDate.getTime())));
        }
        parts.sort();
        parts.add(PromptCatalog.versionOf(PromptCatalog.ASSESS_REQUIREMENTS));
        parts.add(CvAgentSettings.strongThreshold() + '/' + CvAgentSettings.possibleThreshold());
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(String.join(parts, '|'))));
    }

    private static String normalizeMatch(String raw) {
        String m = raw == null ? '' : raw.trim().toLowerCase();
        if (m == 'met') {
            return ScoringService.MET;
        }
        if (m == 'partial' || m == 'partially met') {
            return ScoringService.PARTIAL;
        }
        if (m == 'contradicted') {
            return ScoringService.CONTRADICTED;
        }
        return ScoringService.NOT_EVIDENCED;
    }

    /** Removes internal ids such as "(C1)" or "[R2]" that the model may echo into prose. */
    @TestVisible
    private static String stripAliases(String s) {
        return s == null ? null : s.replaceAll('\\s*[\\(\\[](?:[CRE]\\d+(?:,\\s*)?)+[\\)\\]]', '');
    }

    private static String bullets(List<String> items) {
        if (items.isEmpty()) {
            return null;
        }
        return JsonUtil.truncate('• ' + String.join(items, '\n• '), 5000);
    }

    private static String summaryForLog(Outcome out) {
        List<String> parts = new List<String>();
        for (CandidateResult r : out.ranked) {
            parts.add('#' + r.rank + ' ' + r.candidate.Name + ' ' + r.score.total + ' ' + r.score.band + ' (' + r.status + ')');
        }
        for (CandidateResult r : out.queued) {
            parts.add(r.candidate.Name + ' queued');
        }
        for (CandidateResult r : out.failed) {
            parts.add(r.candidate.Name + ' failed: ' + r.error);
        }
        return String.join(parts, '; ');
    }
}
