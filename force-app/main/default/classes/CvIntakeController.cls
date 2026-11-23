/**
 * Server side of the cvUpload LWC: registers uploaded files as CV documents,
 * skips exact duplicates by checksum, rejects unsupported formats, and starts
 * one ingestion job per file.
 */
public with sharing class CvIntakeController {
    public class DocStatus {
        @AuraEnabled public Id documentId;
        @AuraEnabled public String fileName;
        @AuraEnabled public String status;
        @AuraEnabled public String reason;
        @AuraEnabled public Id candidateId;
        @AuraEnabled public String candidateName;
        @AuraEnabled public String cardStatus;
        @AuraEnabled public Decimal completeness;
        @AuraEnabled public String contentDocumentId;
        @AuraEnabled public String contentVersionId;
        @AuraEnabled public String fileType;
        @AuraEnabled public Boolean awaitingText;
    }

    /**
     * clientExtractsPdf: the component will read each PDF's text layer in the
     * browser and call submitPdfText; PDF jobs start then, not here.
     */
    @AuraEnabled
    public static List<DocStatus> registerUploads(List<Id> contentDocumentIds, Id jobRoleId, Boolean clientExtractsPdf) {
        if (contentDocumentIds == null || contentDocumentIds.isEmpty()) {
            return new List<DocStatus>();
        }
        if (contentDocumentIds.size() > 25) {
            throw new AuraHandledException('Upload at most 25 files at a time.');
        }
        try {
            List<ContentVersion> versions = [
                SELECT Id, ContentDocumentId, Title, FileExtension, Checksum, ContentSize
                FROM ContentVersion
                WHERE ContentDocumentId IN :contentDocumentIds AND IsLatest = TRUE
                WITH USER_MODE
            ];
            Set<String> checksums = new Set<String>();
            for (ContentVersion v : versions) {
                checksums.add(v.Checksum);
            }
            Map<String, CV_Document__c> existingByChecksum = new Map<String, CV_Document__c>();
            for (CV_Document__c d : [
                SELECT Id, Candidate__c, Checksum__c
                FROM CV_Document__c
                WHERE Checksum__c IN :checksums AND Status__c IN ('Queued', 'Processing', 'Extracted', 'Needs Review')
                WITH USER_MODE
                ORDER BY CreatedDate
            ]) {
                if (!existingByChecksum.containsKey(d.Checksum__c)) {
                    existingByChecksum.put(d.Checksum__c, d);
                }
            }

            List<CV_Document__c> docs = new List<CV_Document__c>();
            Set<String> seenInBatch = new Set<String>();
            for (ContentVersion v : versions) {
                String type = DocumentExtractorFactory.typeFromExtension(v.FileExtension);
                CV_Document__c d = new CV_Document__c(
                    Content_Document_Id__c = v.ContentDocumentId,
                    Content_Version_Id__c = v.Id,
                    File_Name__c = JsonUtil.truncate(v.Title + (v.FileExtension == null ? '' : '.' + v.FileExtension), 255),
                    File_Type__c = type,
                    Checksum__c = v.Checksum,
                    Job_Role__c = jobRoleId,
                    Status__c = 'Queued',
                    Attempts__c = 0
                );
                if (type != 'PDF' && type != 'DOCX') {
                    d.Status__c = 'Failed';
                    d.Failure_Reason__c = 'Unsupported format: save as PDF or DOCX';
                } else if (existingByChecksum.containsKey(v.Checksum)) {
                    CV_Document__c original = existingByChecksum.get(v.Checksum);
                    d.Status__c = 'Duplicate';
                    d.Duplicate_Of__c = original.Id;
                    d.Candidate__c = original.Candidate__c;
                    d.Failure_Reason__c = 'Same file was already uploaded';
                } else if (seenInBatch.contains(v.Checksum)) {
                    d.Status__c = 'Duplicate';
                    d.Failure_Reason__c = 'Same file appears twice in this upload';
                } else if (v.ContentSize > 15 * 1024 * 1024) {
                    d.Status__c = 'Failed';
                    d.Failure_Reason__c = 'File is larger than 15 MB';
                }
                seenInBatch.add(v.Checksum);
                docs.add(d);
            }
            insert as user docs;

            List<ContentDocumentLink> links = new List<ContentDocumentLink>();
            for (CV_Document__c d : docs) {
                links.add(new ContentDocumentLink(ContentDocumentId = d.Content_Document_Id__c, LinkedEntityId = d.Id, ShareType = 'V'));
                if (d.Status__c == 'Queued' && !(clientExtractsPdf == true && d.File_Type__c == 'PDF')) {
                    System.enqueueJob(new CvIngestionJob(d.Id));
                }
            }
            Database.insert(links, false); // a link that already exists is not an error

            List<Id> ids = new List<Id>();
            for (CV_Document__c d : docs) {
                ids.add(d.Id);
            }
            DecisionLogger.Entry log = DecisionLogger.start('Register uploads');
            log.jobRoleId = jobRoleId;
            log.inputSummary = docs.size() + ' file(s)';
            log.outputSummary = summarize(docs);
            DecisionLogger.publish(log);
            List<DocStatus> statuses = getStatuses(ids);
            for (DocStatus st : statuses) {
                st.awaitingText = clientExtractsPdf == true && st.fileType == 'PDF' && st.status == 'Queued';
            }
            return statuses;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Upload could not be registered: ' + e.getMessage());
        }
    }

    /**
     * Receives the text layer of a PDF (one string per page) read in the browser
     * and starts ingestion. Too little text means a scanned PDF: the job then
     * falls back to model transcription.
     */
    @AuraEnabled
    public static DocStatus submitPdfText(Id documentId, List<String> pages) {
        try {
            List<CV_Document__c> docs = [
                SELECT Id, Status__c, File_Type__c FROM CV_Document__c WHERE Id = :documentId WITH USER_MODE
            ];
            if (docs.isEmpty() || docs[0].File_Type__c != 'PDF') {
                throw new AuraHandledException('PDF document not found.');
            }
            if (docs[0].Status__c != 'Queued') {
                return getStatuses(new List<Id>{ documentId })[0]; // already started
            }
            Integer total = 0;
            for (String p : pages == null ? new List<String>() : pages) {
                total += p == null ? 0 : p.length();
            }
            if (total > 400000) {
                throw new AuraHandledException('The PDF text is too long for a CV (over 400,000 characters).');
            }
            if (PdfTextLayerExtractor.hasTextLayer(pages)) {
                System.enqueueJob(new CvIngestionJob(documentId, pages));
            } else {
                System.enqueueJob(new CvIngestionJob(documentId));
            }
            return getStatuses(new List<Id>{ documentId })[0];
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Could not start processing: ' + e.getMessage());
        }
    }

    /** Base64 bytes of an uploaded PDF so the component can read its text layer (CVs up to 3 MB). */
    @AuraEnabled
    public static String getPdfData(Id documentId) {
        List<CV_Document__c> docs = [
            SELECT Content_Document_Id__c FROM CV_Document__c WHERE Id = :documentId AND File_Type__c = 'PDF' WITH USER_MODE
        ];
        if (docs.isEmpty()) {
            throw new AuraHandledException('PDF document not found.');
        }
        List<ContentVersion> versions = [
            SELECT VersionData, ContentSize FROM ContentVersion
            WHERE ContentDocumentId = :docs[0].Content_Document_Id__c AND IsLatest = TRUE
            WITH USER_MODE LIMIT 1
        ];
        if (versions.isEmpty() || versions[0].ContentSize > 3 * 1024 * 1024) {
            return null; // too large to read in the browser: the server path handles it
        }
        return EncodingUtil.base64Encode(versions[0].VersionData);
    }

    @AuraEnabled
    public static List<DocStatus> getStatuses(List<Id> documentIds) {
        List<DocStatus> out = new List<DocStatus>();
        for (CV_Document__c d : [
            SELECT Id, File_Name__c, Status__c, Failure_Reason__c, Candidate__c, Candidate__r.Name, Content_Document_Id__c,
                Content_Version_Id__c, File_Type__c,
                Candidate__r.Card_Status__c, Candidate__r.Card_Completeness__c
            FROM CV_Document__c
            WHERE Id IN :documentIds
            WITH USER_MODE
            ORDER BY CreatedDate
        ]) {
            DocStatus s = new DocStatus();
            s.documentId = d.Id;
            s.fileName = d.File_Name__c;
            s.status = d.Status__c;
            s.reason = d.Failure_Reason__c;
            s.candidateId = d.Candidate__c;
            s.candidateName = d.Candidate__r?.Name;
            s.cardStatus = d.Candidate__r?.Card_Status__c;
            s.completeness = d.Candidate__r?.Card_Completeness__c;
            s.contentDocumentId = d.Content_Document_Id__c;
            s.contentVersionId = d.Content_Version_Id__c;
            s.fileType = d.File_Type__c;
            s.awaitingText = false;
            out.add(s);
        }
        return out;
    }

    /** Recent uploads, optionally for one role, so the component can show history. */
    @AuraEnabled
    public static List<DocStatus> getRecent(Id jobRoleId) {
        List<Id> ids = new List<Id>();
        String filter = jobRoleId == null ? '' : ' AND Job_Role__c = :jobRoleId';
        for (CV_Document__c d : Database.query(
            'SELECT Id FROM CV_Document__c WHERE CreatedDate = LAST_N_DAYS:7' + filter +
            ' WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 25'
        )) {
            ids.add(d.Id);
        }
        return getStatuses(ids);
    }

    private static String summarize(List<CV_Document__c> docs) {
        Map<String, Integer> counts = new Map<String, Integer>();
        for (CV_Document__c d : docs) {
            counts.put(d.Status__c, (counts.containsKey(d.Status__c) ? counts.get(d.Status__c) : 0) + 1);
        }
        List<String> parts = new List<String>();
        for (String k : counts.keySet()) {
            parts.add(k + ': ' + counts.get(k));
        }
        return String.join(parts, ', ');
    }
}
