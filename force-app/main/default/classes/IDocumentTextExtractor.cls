/** Strategy for turning one uploaded file into stored CV text. */
public interface IDocumentTextExtractor {
    ExtractedText extract(CV_Document__c doc);
}
