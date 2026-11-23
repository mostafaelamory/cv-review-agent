/**
 * Ingests one CV: text extraction, card extraction, validation and save.
 * One job per file gives per-file status and retries.
 *
 * All model calls happen before any DML, so a failed call never leaves
 * half-written records. Rate limits and timeouts are retried with a delay
 * (Max_Attempts__c); anything else marks the document Failed with a reason.
 */
public with sharing class CvIngestionJob implements Queueable, Database.AllowsCallouts {
    private Id documentId;
    private Integer attempt;
    /** PDF text extracted in the browser (one entry per page); null for server-side extraction. */
    private List<String> pdfPages;

    public CvIngestionJob(Id documentId) {
        this(documentId, 1, null);
    }

    public CvIngestionJob(Id documentId, List<String> pdfPages) {
        this(documentId, 1, pdfPages);
    }

    public CvIngestionJob(Id documentId, Integer attempt, List<String> pdfPages) {
        this.documentId = documentId;
        this.attempt = attempt;
        this.pdfPages = pdfPages;
    }

    public void execute(QueueableContext ctx) {
        DecisionLogger.Entry log = DecisionLogger.start('Ingest CV').template(PromptCatalog.EXTRACT_CARD);
        CV_Document__c doc;
        try {
            doc = [
                SELECT Id, Name, Content_Document_Id__c, File_Name__c, File_Type__c, Job_Role__c, Status__c
                FROM CV_Document__c
                WHERE Id = :documentId
                WITH USER_MODE
            ];
            log.inputSummary = doc.Name + ' ' + doc.File_Name__c + ' (' + doc.File_Type__c + '), attempt ' + attempt;
            log.jobRoleId = doc.Job_Role__c;

            IDocumentTextExtractor extractor = pdfPages != null && doc.File_Type__c == 'PDF'
                ? (IDocumentTextExtractor) new PdfTextLayerExtractor(pdfPages)
                : DocumentExtractorFactory.forType(doc.File_Type__c);
            ExtractedText extracted = extractor.extract(doc);
            if (extracted.quality == 'Unreadable') {
                throw new CvAgentException(
                        doc.File_Type__c == 'PDF'
                            ? 'No readable text: the PDF has no text layer (scanned?) and the model could not read it. Upload a text PDF or DOCX.'
                            : 'No readable text found in the file'
                    )
                    .withCode(CvAgentException.UNREADABLE);
            }

            Map<String, Object> card = extractCard(extracted, log);
            CandidateCardBuilder.Result result = new CandidateCardBuilder(doc, extracted).parse(card).save();

            log.candidateIds.add(result.candidateId);
            log.outcome = result.cardStatus == 'Ready' ? 'Success' : 'Needs Review';
            log.groundingCheck = result.statedCount == result.verifiedCount ? 'Passed' : 'Repaired';
            log.outputSummary =
                'Card ' + result.cardStatus + ': ' + result.evidenceCount + ' facts, ' +
                result.verifiedCount + '/' + result.statedCount + ' quotes verified, ' +
                result.conflictCount + ' conflicting, completeness ' + result.completeness + '%' +
                (result.reviewReasons.isEmpty() ? '' : '. Review: ' + String.join(result.reviewReasons, '; '));

            if (!Test.isRunningTest()) {
                // One minute later, so parallel cards are visible; it then starts any role evaluation.
                System.enqueueJob(new CvDuplicateCheckJob(result.candidateId, doc.Job_Role__c), 1);
            }
        } catch (CvAgentException e) {
            handleFailure(doc, e, e.isRetryable(), log);
        } catch (Exception e) {
            handleFailure(doc, e, false, log);
        }
        DecisionLogger.publish(log);
    }

    /** CV_Extract_Card with one repair retry on invalid JSON. */
    private Map<String, Object> extractCard(ExtractedText extracted, DecisionLogger.Entry log) {
        ILlmService llm = LlmServiceFactory.get();
        String cvText = extracted.withMarkers();
        String repairHint = '';
        for (Integer i = 0; i < 2; i++) {
            LlmModels.Response res = llm.generate(
                new LlmModels.Request(PromptCatalog.EXTRACT_CARD)
                    .put('CV_Text', cvText)
                    .put('Repair_Hint', repairHint)
            );
            log.rawResponse = res.text;
            try {
                return JsonUtil.parseObject(res.text);
            } catch (CvAgentException e) {
                if (i == 1) {
                    throw e;
                }
                repairHint = 'Your previous answer was not valid JSON (' + e.getMessage() + '). Return only the JSON object.';
            }
        }
        return null;
    }

    private void handleFailure(CV_Document__c doc, Exception e, Boolean retryable, DecisionLogger.Entry log) {
        log.fail(e);
        Integer maxAttempts = CvAgentSettings.maxAttempts();
        if (retryable && attempt < maxAttempts && !Test.isRunningTest()) {
            log.outcome = 'Partial';
            log.outputSummary = 'Retry ' + (attempt + 1) + ' of ' + maxAttempts + ' queued';
            update as user new CV_Document__c(Id = documentId, Attempts__c = attempt, Status__c = 'Queued');
            // Back off: 1, 2, 4 minutes.
            System.enqueueJob(new CvIngestionJob(documentId, attempt + 1, pdfPages), Integer.valueOf(Math.pow(2, attempt - 1)));
            return;
        }
        String reason = e instanceof CvAgentException ? e.getMessage() : 'Unexpected error: ' + e.getMessage();
        try {
            update as user new CV_Document__c(
                Id = documentId,
                Status__c = 'Failed',
                Failure_Reason__c = JsonUtil.truncate(reason, 255),
                Attempts__c = attempt,
                Processed_At__c = System.now()
            );
        } catch (Exception ignored) {
            System.debug(LoggingLevel.ERROR, 'Could not mark document failed: ' + ignored.getMessage());
        }
    }
}
