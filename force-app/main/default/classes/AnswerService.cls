/**
 * Grounded Q&A over CV evidence.
 *
 * Retrieval (user mode) -> CV_Answer_Question returns JSON segments, each with
 * the evidence aliases that support it -> Apex rejects any alias outside the
 * retrieved set and any segment without one -> one retry -> otherwise
 * "Not stated in the CV". Only verified text and its sources leave this class.
 */
public with sharing class AnswerService {
    public static final String NOT_STATED = 'Not stated in the CV.';

    public class Source {
        public Integer index;
        public Id recordId;
        public String objectApiName;
        public String candidateName;
        public String label;
        public String quote;
        public Decimal page;
        public String status;
    }

    public class Answer {
        public String text;
        public List<Source> sources = new List<Source>();
        public String outcome = 'Success';
        public Boolean needsClarification = false;
        public List<Id> candidateIds = new List<Id>();
        public String requestId;
    }

    private class Context {
        Map<String, Id> idByAlias = new Map<String, Id>();
        Map<Id, Candidate_Evidence__c> evidenceById = new Map<Id, Candidate_Evidence__c>();
        Map<Id, CV_Text_Chunk__c> chunkById = new Map<Id, CV_Text_Chunk__c>();
        List<String> lines = new List<String>();
        List<String> candidateNames = new List<String>();
    }

    public static Answer ask(String question, String candidateNames, String keywords, Id contextRecordId) {
        DecisionLogger.Entry log = DecisionLogger.start('Answer question').template(PromptCatalog.ANSWER_QUESTION);
        log.inputSummary = JsonUtil.truncate('Q: ' + question + ' | candidates: ' + candidateNames + ' | keywords: ' + keywords, 5000);
        Answer ans = new Answer();
        ans.requestId = log.requestId;
        try {
            List<Candidate__c> scope = resolveScope(candidateNames, contextRecordId, ans);
            if (ans.needsClarification) {
                log.outcome = 'Refused';
                log.outputSummary = ans.text;
                DecisionLogger.publish(log);
                return ans;
            }
            if (scope.isEmpty()) {
                ans.text = 'There are no candidate cards you can access yet. Upload CVs first.';
                log.outcome = 'Refused';
                log.outputSummary = ans.text;
                DecisionLogger.publish(log);
                return ans;
            }
            for (Candidate__c c : scope) {
                ans.candidateIds.add(c.Id);
                log.candidateIds.add(c.Id);
            }
            Context ctx = retrieve(question, keywords, scope);
            if (ctx.idByAlias.isEmpty()) {
                ans.text = NOT_STATED;
                ans.outcome = 'Ungrounded';
                log.outcome = 'Ungrounded';
                log.outputSummary = 'No evidence retrieved';
                DecisionLogger.publish(log);
                return ans;
            }

            ILlmService llm = LlmServiceFactory.get();
            String feedback = '';
            Verified verified;
            for (Integer attempt = 0; attempt < 2; attempt++) {
                LlmModels.Response res = llm.generate(
                    new LlmModels.Request(PromptCatalog.ANSWER_QUESTION)
                        .put('Question', question)
                        .put('Candidates', String.join(ctx.candidateNames, ', '))
                        .put('Evidence', String.join(ctx.lines, '\n'))
                        .put('Feedback', feedback)
                );
                log.rawResponse = res.text;
                verified = verify(res.text, ctx);
                if (verified.allValid) {
                    log.groundingCheck = attempt == 0 ? 'Passed' : 'Repaired';
                    break;
                }
                feedback = 'Your previous answer had segments without valid evidence ids (' + verified.problem +
                    '). Every segment must cite ids from the evidence block. If nothing supports an answer, return {"segments":[],"not_stated":true}.';
            }

            if (verified.segments.isEmpty()) {
                ans.text = NOT_STATED;
                ans.outcome = 'Ungrounded';
                log.groundingCheck = verified.allValid ? 'Passed' : 'Failed';
                log.outcome = 'Ungrounded';
            } else {
                if (!verified.allValid) {
                    log.groundingCheck = 'Repaired'; // invalid segments dropped
                    ans.outcome = 'Partial';
                    log.outcome = 'Partial';
                }
                render(ans, verified, ctx);
                for (Source s : ans.sources) {
                    log.evidenceIds.add(s.recordId);
                }
            }
            log.outputSummary = JsonUtil.truncate(ans.text, 10000);
        } catch (Exception e) {
            log.fail(e);
            ans.text = 'I could not answer that right now: ' + e.getMessage();
            ans.outcome = 'Failed';
        }
        DecisionLogger.publish(log);
        return ans;
    }

    /** Named candidates, else the record in context, else the most recent cards. */
    private static List<Candidate__c> resolveScope(String candidateNames, Id contextRecordId, Answer ans) {
        Integer max = CvAgentSettings.maxCandidatesPerQuery();
        List<String> names = CandidateResolver.splitNames(candidateNames);
        if (!names.isEmpty()) {
            CandidateResolver.Resolution r = CandidateResolver.resolve(names);
            if (r.needsClarification()) {
                ans.needsClarification = true;
                ans.text = r.clarification();
                ans.outcome = 'Refused';
                return new List<Candidate__c>();
            }
            return r.matched.size() > max ? subList(r.matched, max) : r.matched;
        }
        if (contextRecordId != null && contextRecordId.getSobjectType() == Candidate__c.SObjectType) {
            return [SELECT Id, Name, Headline__c FROM Candidate__c WHERE Id = :contextRecordId WITH USER_MODE];
        }
        if (contextRecordId != null && contextRecordId.getSobjectType() == Job_Role__c.SObjectType) {
            List<Candidate__c> forRole = CandidateResolver.forRole(contextRecordId, max);
            if (!forRole.isEmpty()) {
                return forRole;
            }
        }
        return CandidateResolver.recent(max);
    }

    /**
     * One candidate: all evidence plus the full stored text.
     * Several: keyword-matched evidence, the matching Missing/Conflicting rows,
     * and SOSL-matched text chunks, within the row cap.
     */
    private static Context retrieve(String question, String keywords, List<Candidate__c> scope) {
        Context ctx = new Context();
        Set<Id> ids = new Map<Id, Candidate__c>(scope).keySet();
        for (Candidate__c c : scope) {
            ctx.candidateNames.add(c.Name);
        }
        List<String> terms = new List<String>();
        if (String.isNotBlank(keywords)) {
            for (String k : keywords.split(',')) {
                if (String.isNotBlank(k)) {
                    terms.add(k.trim().toLowerCase());
                }
            }
        }
        if (terms.isEmpty()) {
            terms = TextNormalizer.keywords(question);
        }
        terms = SkillAliases.expandKeywords(terms);
        Integer maxRows = CvAgentSettings.maxEvidenceRows();

        List<Candidate_Evidence__c> evidence;
        List<CV_Text_Chunk__c> chunks = new List<CV_Text_Chunk__c>();
        if (scope.size() == 1) {
            evidence = EvidenceSelector.forCandidates(ids);
            chunks = EvidenceSelector.chunksFor(ids);
        } else {
            evidence = terms.isEmpty() ? new List<Candidate_Evidence__c>() : EvidenceSelector.search(ids, terms, null, maxRows);
            // Gaps matter for cross-candidate questions; tenure facts only when the question is about tenure.
            Boolean aboutTenure = Pattern.compile('(?i)\\b(years?|experience|tenure|senior|how long)\\b').matcher(question).find();
            Map<Id, Candidate_Evidence__c> merged = new Map<Id, Candidate_Evidence__c>(evidence);
            for (Candidate_Evidence__c ev : EvidenceSelector.forCandidates(ids)) {
                if (merged.size() >= maxRows) {
                    break;
                }
                if ((ev.Status__c == 'Conflicting' && aboutTenure) || (ev.Status__c == 'Missing' && mentionsAny(ev, terms)) ||
                    (ev.Attribute__c == 'Total experience' && aboutTenure)) {
                    merged.put(ev.Id, ev);
                }
            }
            evidence = merged.values();
            Set<Id> chunkIds = EvidenceSelector.chunkIdsMatching(subList(terms, 5), ids);
            if (!chunkIds.isEmpty()) {
                for (CV_Text_Chunk__c ch : EvidenceSelector.chunksFor(ids)) {
                    if (chunkIds.contains(ch.Id) && chunks.size() < 6) {
                        chunks.add(ch);
                    }
                }
            }
        }

        Integer n = 0;
        for (Candidate_Evidence__c ev : evidence) {
            if (n >= maxRows && scope.size() > 1) {
                break;
            }
            String alias = 'E' + (++n);
            ctx.idByAlias.put(alias, ev.Id);
            ctx.evidenceById.put(ev.Id, ev);
            ctx.lines.add('[' + alias + '] ' + EvidenceFormatter.line(ev, true));
        }
        Integer c = 0;
        for (CV_Text_Chunk__c ch : chunks) {
            String alias = 'T' + (++c);
            ctx.idByAlias.put(alias, ch.Id);
            ctx.chunkById.put(ch.Id, ch);
            ctx.lines.add(
                '[' + alias + '] Candidate: ' + ch.CV_Document__r.Candidate__r.Name + ' | CV text' +
                (ch.Page__c == null ? '' : ' page ' + ch.Page__c) + ':\n' + ch.Text__c.left(6000)
            );
        }
        return ctx;
    }

    private class Segment {
        String text;
        List<Id> ids = new List<Id>();
    }

    private class Verified {
        List<Segment> segments = new List<Segment>();
        Boolean allValid = true;
        String problem;
    }

    @TestVisible
    private static Verified verify(String raw, Context ctx) {
        Verified v = new Verified();
        Map<String, Object> parsed;
        try {
            parsed = JsonUtil.parseObject(raw);
        } catch (CvAgentException e) {
            v.allValid = false;
            v.problem = 'invalid JSON';
            return v;
        }
        for (Object o : JsonUtil.arr(parsed, 'segments')) {
            Map<String, Object> m = JsonUtil.obj(o);
            Segment s = new Segment();
            s.text = JsonUtil.str(m, 'text');
            for (String alias : JsonUtil.strings(m, 'sources')) {
                Id rid = ctx.idByAlias.get(alias.removeStart('[').removeEnd(']').trim());
                if (rid == null) {
                    v.allValid = false;
                    v.problem = 'unknown id ' + alias;
                } else if (!s.ids.contains(rid)) {
                    s.ids.add(rid);
                }
            }
            if (String.isBlank(s.text)) {
                continue;
            }
            if (s.ids.isEmpty()) {
                v.allValid = false;
                v.problem = 'segment without sources: "' + s.text.left(60) + '"';
                continue;
            }
            v.segments.add(s);
        }
        return v;
    }

    /** Segment text with [n] markers, and a numbered source list. */
    private static void render(Answer ans, Verified v, Context ctx) {
        Map<Id, Integer> numberOf = new Map<Id, Integer>();
        List<String> parts = new List<String>();
        for (Segment s : v.segments) {
            List<String> marks = new List<String>();
            for (Id rid : s.ids) {
                if (!numberOf.containsKey(rid)) {
                    numberOf.put(rid, numberOf.size() + 1);
                    ans.sources.add(toSource(numberOf.get(rid), rid, ctx));
                }
                marks.add('[' + numberOf.get(rid) + ']');
            }
            parts.add(s.text.trim() + ' ' + String.join(marks, ''));
        }
        ans.text = String.join(parts, '\n');
    }

    private static Source toSource(Integer index, Id rid, Context ctx) {
        Source s = new Source();
        s.index = index;
        s.recordId = rid;
        if (ctx.evidenceById.containsKey(rid)) {
            Candidate_Evidence__c ev = ctx.evidenceById.get(rid);
            s.objectApiName = 'Candidate_Evidence__c';
            s.candidateName = ev.Candidate__r?.Name;
            s.label = ev.Category__c + ': ' + (ev.Value__c != null ? ev.Value__c : ev.Attribute__c);
            s.quote = ev.Quote_Verified__c == true ? ev.Source_Quote__c : null;
            s.page = ev.Source_Page__c;
            s.status = EvidenceFormatter.statusLabel(ev);
        } else {
            CV_Text_Chunk__c ch = ctx.chunkById.get(rid);
            s.objectApiName = 'CV_Text_Chunk__c';
            s.candidateName = ch.CV_Document__r.Candidate__r.Name;
            s.label = 'CV text: ' + ch.CV_Document__r.File_Name__c;
            s.page = ch.Page__c;
            s.status = 'CV text';
        }
        return s;
    }

    private static Boolean mentionsAny(Candidate_Evidence__c ev, List<String> terms) {
        String hay = ((ev.Attribute__c == null ? '' : ev.Attribute__c) + ' ' + ev.Category__c).toLowerCase();
        for (String t : terms) {
            if (hay.contains(t)) {
                return true;
            }
        }
        return terms.contains(ev.Category__c.toLowerCase());
    }

    private static List<String> subList(List<String> items, Integer max) {
        List<String> out = new List<String>();
        for (Integer i = 0; i < Math.min(max, items.size()); i++) {
            out.add(items[i]);
        }
        return out;
    }

    private static List<Candidate__c> subList(List<Candidate__c> items, Integer max) {
        List<Candidate__c> out = new List<Candidate__c>();
        for (Integer i = 0; i < Math.min(max, items.size()); i++) {
            out.add(items[i]);
        }
        return out;
    }
}
