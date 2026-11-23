/**
 * Offline implementation used by Apex tests (always) and by Stub mode (working
 * without generation credits).
 *
 * Tests queue exact responses per template with enqueue(). With nothing queued,
 * the stub produces simple, deterministic output from the inputs: it is not
 * clever, but it exercises the whole pipeline and every guard.
 */
public with sharing class StubLlmService implements ILlmService {
    private static Map<String, List<String>> queued = new Map<String, List<String>>();
    public static List<LlmModels.Request> calls = new List<LlmModels.Request>();
    /** When set, every call throws this code (to test retries and failure paths). */
    public static String failWithCode;

    public static void enqueue(String templateName, String response) {
        if (!queued.containsKey(templateName)) {
            queued.put(templateName, new List<String>());
        }
        queued.get(templateName).add(response);
    }

    public static void reset() {
        queued = new Map<String, List<String>>();
        calls = new List<LlmModels.Request>();
        failWithCode = null;
    }

    public LlmModels.Response generate(LlmModels.Request request) {
        calls.add(request);
        if (failWithCode != null) {
            throw new CvAgentException('Stubbed failure').withCode(failWithCode);
        }
        List<String> q = queued.get(request.templateName);
        if (q != null && !q.isEmpty()) {
            return new LlmModels.Response(request.templateName, q.remove(0), 1);
        }
        return new LlmModels.Response(request.templateName, heuristic(request), 1);
    }

    private String heuristic(LlmModels.Request r) {
        String t = r.templateName;
        if (t == PromptCatalog.TRANSCRIBE) {
            return 'QUALITY: Partial\n=== PAGE 1 ===\n(Stub mode cannot read PDF files. Switch LLM Mode to Live.)\n[[END]]';
        }
        if (t == PromptCatalog.EXTRACT_CARD) {
            return extractCard(r.textInputs.get('CV_Text'));
        }
        if (t == PromptCatalog.ASSESS_REQUIREMENTS) {
            return assess(r.textInputs.get('Requirements'), r.textInputs.get('Evidence'));
        }
        if (t == PromptCatalog.ANSWER_QUESTION) {
            return answer(r.textInputs.get('Question'), r.textInputs.get('Evidence'));
        }
        if (t == PromptCatalog.RECOMMEND) {
            return '{"recommendation":"Stub mode: the top-ranked candidate is recommended on score alone. '
                + 'Switch LLM Mode to Live for a written recommendation.","trade_offs":"","candidates":[]}';
        }
        return '{}';
    }

    /** Name from the first line, email and phone by pattern, skills from a fixed list. */
    private static String extractCard(String text) {
        text = text == null ? '' : text;
        List<Map<String, Object>> evidence = new List<Map<String, Object>>();
        Map<String, Object> profile = new Map<String, Object>();
        for (String line : text.split('\n')) {
            String l = line.trim();
            if (String.isNotBlank(l) && !l.startsWith('===') && !l.startsWith('QUALITY')) {
                profile.put('full_name', l.left(80));
                evidence.add(row('Contact', 'Full name', l.left(80), l));
                break;
            }
        }
        Matcher em = Pattern.compile('[\\w.+-]+@[\\w-]+\\.[\\w.]+').matcher(text);
        if (em.find()) {
            profile.put('email', em.group());
            evidence.add(row('Contact', 'Email', em.group(), em.group()));
        }
        Matcher ph = Pattern.compile('\\+?[0-9][0-9 ()-]{7,}[0-9]').matcher(text);
        if (ph.find()) {
            profile.put('phone', ph.group());
            evidence.add(row('Contact', 'Phone', ph.group(), ph.group()));
        }
        String lower = text.toLowerCase();
        for (String skill : new List<String>{ 'Apex', 'LWC', 'SOQL', 'Java', 'JavaScript', 'Python', 'SQL', 'Salesforce' }) {
            Integer idx = lower.indexOf(skill.toLowerCase());
            if (idx >= 0) {
                evidence.add(row('Skill', 'Skill', skill, text.substring(idx, idx + skill.length())));
            }
        }
        return JSON.serialize(new Map<String, Object>{ 'profile' => profile, 'evidence' => evidence });
    }

    private static Map<String, Object> row(String category, String attribute, String value, String quote) {
        return new Map<String, Object>{
            'category' => category,
            'attribute' => attribute,
            'value' => value,
            'status' => 'Stated',
            'quote' => quote
        };
    }

    /** A requirement is Met when an evidence line contains its first keyword. */
    private static String assess(String requirements, String evidence) {
        List<Object> out = new List<Object>();
        for (String reqLine : (requirements == null ? '' : requirements).split('\n')) {
            Matcher m = Pattern.compile('^\\[(R\\d+)\\][^:]*:\\s*(.*)$').matcher(reqLine.trim());
            if (!m.matches()) {
                continue;
            }
            List<String> words = TextNormalizer.keywords(m.group(2));
            List<String> ids = new List<String>();
            for (String evLine : (evidence == null ? '' : evidence).split('\n')) {
                Matcher e = Pattern.compile('^\\[(E\\d+)\\](.*)$').matcher(evLine.trim());
                if (e.matches() && !words.isEmpty() && e.group(2).toLowerCase().contains(words[0])) {
                    ids.add(e.group(1));
                }
            }
            out.add(new Map<String, Object>{
                'requirement' => m.group(1),
                'match' => ids.isEmpty() ? 'Not evidenced' : 'Met',
                'evidence' => ids,
                'rationale' => ids.isEmpty() ? 'No evidence found.' : 'Evidence mentions ' + words[0] + '.'
            });
        }
        return JSON.serialize(new Map<String, Object>{ 'assessments' => out });
    }

    /** Returns evidence lines that share a keyword with the question. */
    private static String answer(String question, String evidence) {
        List<String> words = TextNormalizer.keywords(question);
        List<Object> segments = new List<Object>();
        for (String evLine : (evidence == null ? '' : evidence).split('\n')) {
            Matcher e = Pattern.compile('^\\[([EC]\\d+)\\](.*)$').matcher(evLine.trim());
            if (!e.matches() || !e.group(1).startsWith('E')) {
                continue;
            }
            for (String w : words) {
                if (e.group(2).toLowerCase().contains(w)) {
                    segments.add(new Map<String, Object>{ 'text' => e.group(2).trim(), 'sources' => new List<String>{ e.group(1) } });
                    break;
                }
            }
            if (segments.size() >= 5) {
                break;
            }
        }
        return JSON.serialize(new Map<String, Object>{ 'segments' => segments });
    }
}
