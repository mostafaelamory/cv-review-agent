/** Picks the extractor for a file type. Legacy .doc and other types are rejected. */
public with sharing class DocumentExtractorFactory {
    public static IDocumentTextExtractor forType(String fileType) {
        if (fileType == 'DOCX') {
            return new DocxTextExtractor();
        }
        if (fileType == 'PDF') {
            return new PdfTranscriptExtractor();
        }
        throw new CvAgentException('Unsupported format: save as PDF or DOCX').withCode(CvAgentException.UNSUPPORTED_FORMAT);
    }

    public static String typeFromExtension(String extension) {
        String e = extension == null ? '' : extension.toLowerCase().removeStart('.');
        if (e == 'pdf') {
            return 'PDF';
        }
        if (e == 'docx') {
            return 'DOCX';
        }
        if (e == 'doc') {
            return 'DOC';
        }
        return 'Other';
    }
}
