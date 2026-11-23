/**
 * Reads DOCX text without a model: unzips the package with Compression.ZipReader
 * and walks word/document.xml (plus headers and footers) with XmlStreamReader.
 * Paragraphs become lines; text is grouped into blocks of about 3,000 characters.
 */
public with sharing class DocxTextExtractor implements IDocumentTextExtractor {
    private static final Integer BLOCK_SIZE = 3000;

    public ExtractedText extract(CV_Document__c doc) {
        List<ContentVersion> versions = [
            SELECT VersionData
            FROM ContentVersion
            WHERE ContentDocumentId = :doc.Content_Document_Id__c AND IsLatest = TRUE
            WITH USER_MODE
            LIMIT 1
        ];
        if (versions.isEmpty()) {
            throw new CvAgentException('File not found or not shared with you').withCode(CvAgentException.NOT_FOUND);
        }
        return extractFromBlob(versions[0].VersionData);
    }

    public ExtractedText extractFromBlob(Blob docx) {
        Compression.ZipReader reader;
        try {
            reader = new Compression.ZipReader(docx);
        } catch (Exception e) {
            throw new CvAgentException('The DOCX file could not be opened: ' + e.getMessage())
                .withCode(CvAgentException.UNREADABLE);
        }
        List<String> headerFooter = new List<String>();
        String body;
        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();
            if (name == 'word/document.xml') {
                body = paragraphs(reader.extract(entry).toString());
            } else if (Pattern.matches('word/(header|footer)\\d*\\.xml', name)) {
                String t = paragraphs(reader.extract(entry).toString()).trim();
                if (String.isNotBlank(t) && !headerFooter.contains(t)) {
                    headerFooter.add(t);
                }
            }
        }
        if (body == null) {
            throw new CvAgentException('Not a Word document: word/document.xml is missing').withCode(CvAgentException.UNREADABLE);
        }
        ExtractedText out = new ExtractedText();
        out.method = 'DOCX Parser';
        String full = (headerFooter.isEmpty() ? '' : String.join(headerFooter, '\n') + '\n') + body;
        Integer seq = 1;
        String current = '';
        for (String line : full.split('\n')) {
            if (current.length() + line.length() > BLOCK_SIZE && String.isNotBlank(current)) {
                out.chunks.add(new ExtractedText.Chunk(seq++, null, current.trim()));
                current = '';
            }
            current += line + '\n';
        }
        if (String.isNotBlank(current)) {
            out.chunks.add(new ExtractedText.Chunk(seq, null, current.trim()));
        }
        if (out.length() < 50) {
            out.quality = 'Unreadable';
        }
        return out;
    }

    /** Text runs joined per paragraph; tabs and breaks kept; table cells separated. */
    @TestVisible
    private static String paragraphs(String xml) {
        XmlStreamReader r = new XmlStreamReader(xml);
        r.setCoalescing(true);
        List<String> lines = new List<String>();
        String line = '';
        Boolean inText = false;
        while (r.hasNext()) {
            r.next();
            XmlTag ev = r.getEventType();
            if (ev == XmlTag.START_ELEMENT) {
                String n = r.getLocalName();
                if (n == 't') {
                    inText = true;
                } else if (n == 'tab') {
                    line += '\t';
                } else if (n == 'br' || n == 'cr') {
                    line += '\n';
                }
            } else if (ev == XmlTag.CHARACTERS && inText) {
                line += r.getText();
            } else if (ev == XmlTag.END_ELEMENT) {
                String n = r.getLocalName();
                if (n == 't') {
                    inText = false;
                } else if (n == 'p') {
                    lines.add(line);
                    line = '';
                } else if (n == 'tc') {
                    lines.add('|');
                }
            }
        }
        if (String.isNotBlank(line)) {
            lines.add(line);
        }
        // Collapse runs of empty lines.
        return String.join(lines, '\n').replaceAll('\n{3,}', '\n\n');
    }
}
