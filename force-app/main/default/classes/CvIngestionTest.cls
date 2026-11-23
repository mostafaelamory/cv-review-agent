@IsTest
private class CvIngestionTest {
    static String card(String name) {
        return CvTestFactory.cardJson(name, name.deleteWhitespace().toLowerCase() + '@example.com', true);
    }

    @IsTest
    static void docxUploadBecomesACard() {
        System.runAs(CvTestFactory.recruiter()) {
            String text = CvTestFactory.cvText('Sara Ahmed', 'saraahmed@example.com', true);
            Id docId = CvTestFactory.uploadFile('sara.docx', CvTestFactory.docx(text.split('\n')));
            StubLlmService.enqueue(PromptCatalog.EXTRACT_CARD, 'Sure! ```json\n' + card('Sara Ahmed') + '\n```');
            Test.startTest();
            List<CvIntakeController.DocStatus> res = CvIntakeController.registerUploads(new List<Id>{ docId }, null, true);
            Test.stopTest();
            Assert.areEqual('Queued', res[0].status);
            Assert.isFalse(res[0].awaitingText, 'DOCX is never extracted in the browser');
            CV_Document__c doc = [SELECT Status__c, Extraction_Method__c, Candidate__c, Candidate__r.Name FROM CV_Document__c];
            Assert.areEqual('Extracted', doc.Status__c);
            Assert.areEqual('DOCX Parser', doc.Extraction_Method__c);
            Assert.areEqual('Sara Ahmed', doc.Candidate__r.Name);
            CV_Text_Chunk__c chunk = [SELECT Text__c FROM CV_Text_Chunk__c];
            Assert.isTrue(chunk.Text__c.startsWith('CONFIDENTIAL CV'), 'Headers are read too');
            Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :doc.Candidate__c]);
            Assert.isTrue(StubLlmService.calls[0].textInputs.get('CV_Text').contains('=== BLOCK 1 ==='));
        }
    }

    @IsTest
    static void pdfTextFromTheBrowserIsUsed() {
        System.runAs(CvTestFactory.recruiter()) {
            Id docId = CvTestFactory.uploadFile('omar.pdf', Blob.valueOf('%PDF-1.4 fake'));
            List<CvIntakeController.DocStatus> res = CvIntakeController.registerUploads(new List<Id>{ docId }, null, true);
            Assert.isTrue(res[0].awaitingText);
            Assert.isNotNull(CvIntakeController.getPdfData(res[0].documentId));
            StubLlmService.enqueue(PromptCatalog.EXTRACT_CARD, card('Omar Khalil'));
            Test.startTest();
            CvIntakeController.submitPdfText(res[0].documentId, new List<String>{ CvTestFactory.cvText('Omar Khalil', 'omarkhalil@example.com', true) });
            Test.stopTest();
            CV_Document__c doc = [SELECT Status__c, Extraction_Method__c FROM CV_Document__c];
            Assert.areEqual('PDF Text Layer', doc.Extraction_Method__c);
            Assert.areEqual(1, [SELECT Page__c FROM CV_Text_Chunk__c].Page__c);
            for (LlmModels.Request r : StubLlmService.calls) {
                Assert.areNotEqual(PromptCatalog.TRANSCRIBE, r.templateName, 'No model transcription when the text layer exists');
            }
        }
    }

    @IsTest
    static void scannedPdfFallsBackAndFailsClearlyWhenTheModelCannotRead() {
        System.runAs(CvTestFactory.recruiter()) {
            Id docId = CvTestFactory.uploadFile('scan.pdf', Blob.valueOf('%PDF-1.4 image only'));
            List<CvIntakeController.DocStatus> res = CvIntakeController.registerUploads(new List<Id>{ docId }, null, true);
            StubLlmService.enqueue(PromptCatalog.TRANSCRIBE, 'I cannot view attached files. Please paste the text.');
            Test.startTest();
            CvIntakeController.submitPdfText(res[0].documentId, new List<String>{ '' });
            Test.stopTest();
            CV_Document__c doc = [SELECT Status__c, Failure_Reason__c FROM CV_Document__c];
            Assert.areEqual('Failed', doc.Status__c);
            Assert.isTrue(doc.Failure_Reason__c.contains('no text layer'));
            Assert.areEqual(0, [SELECT COUNT() FROM Candidate__c], 'A refusal is never stored as CV text');
        }
    }

    @IsTest
    static void serverTranscriptionReadsPagesAndContinuesCutOffOutput() {
        CV_Document__c doc = new CV_Document__c(File_Type__c = 'PDF');
        StubLlmService.enqueue(PromptCatalog.TRANSCRIBE, 'QUALITY: Good\n=== PAGE 1 ===\n' + 'Sara Ahmed, Apex developer. '.repeat(5));
        StubLlmService.enqueue(PromptCatalog.TRANSCRIBE, 'QUALITY: Partial\n=== PAGE 2 ===\nBSc Computer Science\n[[END]]');
        ExtractedText t = new PdfTranscriptExtractor().extract(doc);
        Assert.areEqual(2, t.chunks.size());
        Assert.areEqual(2, t.chunks[1].page);
        Assert.isTrue(t.complete);
        Assert.areEqual('Partial', t.quality);
        Assert.areEqual('2', StubLlmService.calls[1].textInputs.get('Start_Page'), 'Second call asks for the remaining pages');
        Assert.isTrue(t.withMarkers().contains('=== PAGE 2 ==='));
    }

    @IsTest
    static void rejectsLegacyDocAndDuplicates() {
        System.runAs(CvTestFactory.recruiter()) {
            Blob data = CvTestFactory.docx(new List<String>{ 'Same file' });
            Id first = CvTestFactory.uploadFile('a.docx', data);
            Id second = CvTestFactory.uploadFile('b.docx', data);
            Id legacy = CvTestFactory.uploadFile('old.doc', Blob.valueOf('legacy'));
            Test.startTest();
            CvIntakeController.registerUploads(new List<Id>{ first }, null, false);
            List<CvIntakeController.DocStatus> res = CvIntakeController.registerUploads(new List<Id>{ second, legacy }, null, false);
            Test.stopTest();
            Map<String, CvIntakeController.DocStatus> byName = new Map<String, CvIntakeController.DocStatus>();
            for (CvIntakeController.DocStatus s : res) {
                byName.put(s.fileName, s);
            }
            Assert.areEqual('Duplicate', byName.get('b.docx').status);
            Assert.areEqual('Failed', byName.get('old.doc').status);
            Assert.areEqual('Unsupported format: save as PDF or DOCX', byName.get('old.doc').reason);
            Assert.areEqual(3, CvIntakeController.getRecent(null).size());
        }
    }

    @IsTest
    static void invalidJsonIsRepairedOnceThenFails() {
        System.runAs(CvTestFactory.recruiter()) {
            Id docId = CvTestFactory.uploadFile('x.docx', CvTestFactory.docx(new List<String>{ 'Some CV text long enough to be readable by the parser for sure.' }));
            StubLlmService.enqueue(PromptCatalog.EXTRACT_CARD, 'not json');
            StubLlmService.enqueue(PromptCatalog.EXTRACT_CARD, 'still not json');
            Test.startTest();
            CvIntakeController.registerUploads(new List<Id>{ docId }, null, false);
            Test.stopTest();
            CV_Document__c doc = [SELECT Status__c, Failure_Reason__c FROM CV_Document__c];
            Assert.areEqual('Failed', doc.Status__c);
            Assert.areEqual(2, StubLlmService.calls.size(), 'One repair retry');
            Assert.isTrue(StubLlmService.calls[1].textInputs.get('Repair_Hint').contains('not valid JSON'));
        }
    }

    @IsTest
    static void rateLimitMarksFailedAfterAttempts() {
        System.runAs(CvTestFactory.recruiter()) {
            Id docId = CvTestFactory.uploadFile('y.docx', CvTestFactory.docx(new List<String>{ 'Readable CV text that is long enough to pass the threshold.' }));
            StubLlmService.failWithCode = CvAgentException.LLM_UNAVAILABLE;
            Test.startTest();
            CvIntakeController.registerUploads(new List<Id>{ docId }, null, false);
            Test.stopTest();
            Assert.areEqual('Failed', [SELECT Status__c FROM CV_Document__c].Status__c, 'No re-enqueue inside tests');
        }
    }

    @IsTest
    static void docxParserHandlesTabsBreaksAndBadFiles() {
        String xml = '<w:document xmlns:w="w"><w:body><w:p><w:r><w:t>A</w:t><w:tab/><w:t>B</w:t><w:br/><w:t>C</w:t></w:r></w:p>' +
            '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>';
        String out = DocxTextExtractor.paragraphs(xml);
        Assert.isTrue(out.startsWith('A\tB\nC'));
        Assert.isTrue(out.contains('Cell'));
        try {
            new DocxTextExtractor().extractFromBlob(Blob.valueOf('not a zip'));
            Assert.fail('Expected UNREADABLE');
        } catch (CvAgentException e) {
            Assert.areEqual(CvAgentException.UNREADABLE, e.code);
        }
        try {
            DocumentExtractorFactory.forType('DOC');
            Assert.fail('Expected UNSUPPORTED_FORMAT');
        } catch (CvAgentException e) {
            Assert.areEqual(CvAgentException.UNSUPPORTED_FORMAT, e.code);
        }
        Assert.areEqual('Other', DocumentExtractorFactory.typeFromExtension('png'));
    }
}
