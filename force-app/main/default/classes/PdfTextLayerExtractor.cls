/**
 * PDF text read from the file's text layer in the browser (pdf.js in the
 * cvUpload component), one string per page. Exact for digital PDFs; a scanned
 * PDF has no text layer and falls back to model transcription.
 */
public with sharing class PdfTextLayerExtractor implements IDocumentTextExtractor {
    public static final Integer MIN_CHARS = 80;
    private List<String> pages;

    public PdfTextLayerExtractor(List<String> pages) {
        this.pages = pages == null ? new List<String>() : pages;
    }

    public ExtractedText extract(CV_Document__c doc) {
        ExtractedText out = new ExtractedText();
        out.method = 'PDF Text Layer';
        Integer pageNo = 0;
        for (String p : pages) {
            pageNo++;
            if (String.isNotBlank(p)) {
                out.chunks.add(new ExtractedText.Chunk(out.chunks.size() + 1, pageNo, JsonUtil.truncate(p.trim(), 131072)));
            }
        }
        if (out.length() < MIN_CHARS) {
            out.quality = 'Unreadable';
        }
        return out;
    }

    /** True when the pages carry enough text to skip model transcription. */
    public static Boolean hasTextLayer(List<String> pages) {
        Integer n = 0;
        for (String p : pages == null ? new List<String>() : pages) {
            n += p == null ? 0 : p.trim().length();
        }
        return n >= MIN_CHARS;
    }
}
