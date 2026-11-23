@IsTest
private class CvSupportTest {
    @IsTest
    static void stubHeuristicsDriveTheWholePipelineOffline() {
        StubLlmService stub = new StubLlmService();
        String text = 'Jane Doe\njane.doe@example.com\n+20 100 555 0199\nSkills: Apex, Python';
        Map<String, Object> card = JsonUtil.parseObject(stub.generate(new LlmModels.Request(PromptCatalog.EXTRACT_CARD).put('CV_Text', text)).text);
        Assert.areEqual('Jane Doe', JsonUtil.str(JsonUtil.obj(card.get('profile')), 'full_name'));
        Assert.areEqual(5, JsonUtil.arr(card, 'evidence').size(), 'Name, email, phone and two skills');

        String assess = stub.generate(
            new LlmModels.Request(PromptCatalog.ASSESS_REQUIREMENTS)
                .put('Requirements', '[R1] (Must-have, Skill): Apex\n[R2] (Nice-to-have): Kotlin')
                .put('Evidence', '[E1] Skill | Apex | Stated, High confidence')
        ).text;
        Assert.isTrue(assess.contains('"match":"Met"'));
        Assert.isTrue(assess.contains('"match":"Not evidenced"'));

        Assert.isTrue(stub.generate(new LlmModels.Request(PromptCatalog.TRANSCRIBE)).text.contains('[[END]]'));
        Assert.isTrue(stub.generate(new LlmModels.Request(PromptCatalog.RECOMMEND)).text.contains('recommendation'));
        Assert.areEqual('{}', stub.generate(new LlmModels.Request('Other')).text);
        StubLlmService.reset();
        Assert.isTrue(StubLlmService.calls.isEmpty());
    }

    @IsTest
    static void factoryReturnsInjectedService() {
        ILlmService custom = new StubLlmService();
        LlmServiceFactory.inject(custom);
        Assert.areEqual(custom, LlmServiceFactory.get());
        LlmServiceFactory.inject(null);
        Assert.isTrue(LlmServiceFactory.get() instanceof StubLlmService, 'Tests never call the live model');
    }

    @IsTest
    static void resolvesRolesNamesAndIds() {
        Job_Role__c r1 = new Job_Role__c(Name = 'Salesforce Developer');
        Job_Role__c r2 = new Job_Role__c(Name = 'Senior Salesforce Developer');
        insert new List<Job_Role__c>{ r1, r2 };
        Assert.areEqual(r1.Id, CandidateResolver.resolveRole('salesforce developer').Id, 'Exact name wins');
        Assert.areEqual(r2.Id, CandidateResolver.resolveRole(r2.Id).Id);
        Assert.isNull(CandidateResolver.resolveRole('Chef'));
        Assert.isNull(CandidateResolver.resolveRole(''));
        try {
            CandidateResolver.resolveRole('Sales');
            Assert.fail('Expected an ambiguity error');
        } catch (CvAgentException e) {
            Assert.isTrue(e.getMessage().contains('Several roles'));
        }
        Assert.isNull(CandidateResolver.asId('not-an-id'));
        Assert.areEqual(new List<String>{ 'Sara', 'Omar', 'Lina' }, CandidateResolver.splitNames('Sara, Omar and Lina'));

        System.runAs(CvTestFactory.recruiter()) {
            Id cid = CvTestFactory.candidate('Lina Haddad', 'lina@example.com', true);
            insert new CV_Document__c(File_Name__c = 'lina.pdf', Job_Role__c = r2.Id, Candidate__c = cid, Status__c = 'Extracted');
            Assert.areEqual(cid, CandidateResolver.forRole(r2.Id, 10)[0].Id);
            CandidateResolver.Resolution res = CandidateResolver.resolve(new List<String>{ String.valueOf(cid) });
            Assert.areEqual(cid, res.matched[0].Id, 'Ids resolve directly');
            Assert.isFalse(res.needsClarification());
        }
    }

    @IsTest
    static void searchesStoredTextWithSosl() {
        System.runAs(CvTestFactory.recruiter()) {
            Id cid = CvTestFactory.candidate('Maya Farouk', 'maya@example.com', true);
            CV_Text_Chunk__c chunk = [SELECT Id FROM CV_Text_Chunk__c LIMIT 1];
            Test.setFixedSearchResults(new List<Id>{ chunk.Id });
            Set<Id> hits = EvidenceSelector.chunkIdsMatching(new List<String>{ 'apex', 'c++' }, new Set<Id>{ cid });
            Assert.isTrue(hits.contains(chunk.Id));
            Assert.isTrue(EvidenceSelector.chunkIdsMatching(new List<String>{ '?' }, null).isEmpty(), 'No usable terms, no search');
            Assert.isFalse(EvidenceSelector.search(new Set<Id>{ cid }, new List<String>{ 'apex' }, new Set<String>{ 'Skill' }, 10).isEmpty());
            try {
                EvidenceSelector.role(cid);
                Assert.fail('Expected NOT_FOUND');
            } catch (CvAgentException e) {
                Assert.areEqual(CvAgentException.NOT_FOUND, e.code);
            }
        }
    }

    @IsTest
    static void formatsEvidenceForPromptsAndSources() {
        Candidate_Evidence__c ev = new Candidate_Evidence__c(
            Category__c = 'Experience', Attribute__c = 'Role', Value__c = 'Developer', Organization__c = 'Acme',
            Start_Date__c = Date.newInstance(2020, 1, 1), Date_Precision__c = 'Year', Is_Current__c = true,
            Status__c = 'Inferred', Inference_Reason__c = 'From dates', Confidence__c = 'Medium', Detail__c = 'Built things'
        );
        String line = EvidenceFormatter.line(ev, false);
        Assert.isTrue(line.contains('2020 to present'));
        Assert.isTrue(line.contains('why: From dates'));
        ev.Status__c = 'Stated';
        ev.Quote_Verified__c = false;
        Assert.isTrue(EvidenceFormatter.statusLabel(ev).startsWith('Unverified'));
    }
}
