/** Output of a document text extractor: ordered chunks plus quality signals. */
public with sharing class ExtractedText {
    public class Chunk {
        public Integer sequence;
        public Integer page;
        public String text;
        public Chunk(Integer sequence, Integer page, String text) {
            this.sequence = sequence;
            this.page = page;
            this.text = text;
        }
    }

    public List<Chunk> chunks = new List<Chunk>();
    public String method;
    /** Good, Partial or Unreadable. */
    public String quality = 'Good';
    /** False when a transcript was cut off and could not be completed. */
    public Boolean complete = true;
    public String rawResponse;

    /** Full text with page or block markers; this is what the extraction prompt sees. */
    public String withMarkers() {
        List<String> parts = new List<String>();
        for (Chunk c : chunks) {
            parts.add((c.page != null ? '=== PAGE ' + c.page + ' ===' : '=== BLOCK ' + c.sequence + ' ===') + '\n' + c.text);
        }
        return String.join(parts, '\n');
    }

    public Integer length() {
        Integer n = 0;
        for (Chunk c : chunks) {
            n += c.text == null ? 0 : c.text.length();
        }
        return n;
    }
}
