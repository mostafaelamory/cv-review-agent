/**
 * Apex cannot parse PDF, so the CV_Transcribe template reads the file on a
 * multimodal model inside the Trust Layer (scanned PDFs included).
 *
 * Response contract:
 *   QUALITY: Good | Partial | Unreadable
 *   === PAGE n ===
 *   ...text...
 *   [[END]]            (only when the whole document was transcribed)
 * A missing [[END]] means the output was cut off; we ask for the remaining
 * pages, up to MAX_CALLS calls in total.
 */
public with sharing class PdfTranscriptExtractor implements IDocumentTextExtractor {
    public static final Integer MAX_CALLS = 3;
    private static final String END_MARKER = '[[END]]';

    public ExtractedText extract(CV_Document__c doc) {
        ILlmService llm = LlmServiceFactory.get();
        ExtractedText out = new ExtractedText();
        out.method = 'LLM Transcription';
        Map<Integer, String> pages = new Map<Integer, String>();
        String quality = 'Good';
        Boolean complete = false;
        List<String> raws = new List<String>();

        for (Integer call = 0; call < MAX_CALLS && !complete; call++) {
            Integer startPage = pages.isEmpty() ? 1 : maxKey(pages) + 1;
            LlmModels.Request req = new LlmModels.Request(PromptCatalog.TRANSCRIBE)
                .put('Start_Page', String.valueOf(startPage))
                .withFile('CV_File', doc.Content_Document_Id__c);
            String raw = llm.generate(req).text;
            raws.add(raw);
            if (!isTranscript(raw)) {
                // The model answered instead of transcribing (e.g. "I cannot view the file").
                // Never store that as CV text.
                quality = 'Unreadable';
                break;
            }
            complete = raw != null && raw.contains(END_MARKER);
            quality = worse(quality, parseQuality(raw));
            Map<Integer, String> parsed = parsePages(raw == null ? '' : raw.remove(END_MARKER), startPage);
            if (parsed.isEmpty()) {
                break;
            }
            pages.putAll(parsed);
        }

        List<Integer> nums = new List<Integer>(pages.keySet());
        nums.sort();
        Integer seq = 1;
        for (Integer p : nums) {
            if (String.isNotBlank(pages.get(p))) {
                out.chunks.add(new ExtractedText.Chunk(seq++, p, pages.get(p).trim()));
            }
        }
        out.complete = complete;
        out.quality = out.length() < 50 ? 'Unreadable' : (complete ? quality : worse(quality, 'Partial'));
        out.rawResponse = String.join(raws, '\n---\n');
        return out;
    }

    /** A transcript has a QUALITY line or page markers; anything else is the model talking. */
    @TestVisible
    private static Boolean isTranscript(String raw) {
        return raw != null && Pattern.compile('(?im)^\\s*(QUALITY:|=== ?PAGE \\d+ ?===)').matcher(raw).find();
    }

    @TestVisible
    private static Map<Integer, String> parsePages(String raw, Integer defaultPage) {
        Map<Integer, String> pages = new Map<Integer, String>();
        Matcher m = Pattern.compile('(?m)^\\s*=== ?PAGE (\\d+) ?===\\s*$').matcher(raw);
        List<Integer> starts = new List<Integer>();
        List<Integer> nums = new List<Integer>();
        List<Integer> ends = new List<Integer>();
        while (m.find()) {
            starts.add(m.start());
            ends.add(m.end());
            nums.add(Integer.valueOf(m.group(1)));
        }
        if (nums.isEmpty()) {
            String body = raw.replaceFirst('(?m)^\\s*QUALITY:.*$', '').trim();
            if (String.isNotBlank(body)) {
                pages.put(defaultPage, body);
            }
            return pages;
        }
        for (Integer i = 0; i < nums.size(); i++) {
            Integer endIdx = i + 1 < nums.size() ? starts[i + 1] : raw.length();
            pages.put(nums[i], raw.substring(ends[i], endIdx).trim());
        }
        return pages;
    }

    @TestVisible
    private static String parseQuality(String raw) {
        Matcher m = Pattern.compile('(?im)^\\s*QUALITY:\\s*(Good|Partial|Unreadable)').matcher(raw == null ? '' : raw);
        return m.find() ? m.group(1).toLowerCase().capitalize() : 'Good';
    }

    private static String worse(String a, String b) {
        List<String> order = new List<String>{ 'Good', 'Partial', 'Unreadable' };
        return order.indexOf(a) >= order.indexOf(b) ? a : b;
    }

    private static Integer maxKey(Map<Integer, String> m) {
        Integer max = 0;
        for (Integer k : m.keySet()) {
            max = Math.max(max, k);
        }
        return max;
    }
}
