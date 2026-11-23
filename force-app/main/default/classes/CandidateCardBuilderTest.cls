@IsTest
private class CandidateCardBuilderTest {
    static Map<String, Candidate_Evidence__c> byValue(Id candidateId) {
        Map<String, Candidate_Evidence__c> out = new Map<String, Candidate_Evidence__c>();
        for (Candidate_Evidence__c ev : [
            SELECT Attribute__c, Value__c, Status__c, Confidence__c, Quote_Verified__c, Source_Chunk__c, Conflict_Group__c,
                Inference_Reason__c, Date_Precision__c, Is_Current__c, Category__c, Organization__c
            FROM Candidate_Evidence__c WHERE Candidate__c = :candidateId
        ]) {
            out.put(ev.Attribute__c + '|' + ev.Value__c + '|' + ev.Organization__c, ev);
        }
        return out;
    }

    @IsTest
    static void buildsCardWithStatusesConfidenceAndGaps() {
        System.runAs(CvTestFactory.recruiter()) {
            Id cid = CvTestFactory.candidate('Sara Ahmed', 'sara@example.com', true);
            Candidate__c c = [
                SELECT Name, Email__c, Card_Status__c, Card_Completeness__c, Has_Conflicts__c, Total_Experience_Months__c, Headline__c, Summary__c
                FROM Candidate__c WHERE Id = :cid
            ];
            Assert.areEqual('Sara Ahmed', c.Name);
            Assert.areEqual('sara@example.com', c.Email__c);
            Assert.isTrue(c.Has_Conflicts__c, 'Claimed 8 years versus dated roles is a conflict');
            Assert.isTrue(c.Total_Experience_Months__c > 96, 'Merged tenure from 2016 to today');
            Assert.areEqual('Salesforce Developer at Acme Corp', c.Headline__c, 'Current role becomes the headline');
            Assert.isTrue(c.Summary__c.contains('Apex'));

            Map<String, Candidate_Evidence__c> ev = byValue(cid);
            Candidate_Evidence__c apex = ev.get('Skill|Apex|null');
            Assert.isTrue(apex.Quote_Verified__c);
            Assert.areEqual('High', apex.Confidence__c);
            Assert.isNotNull(apex.Source_Chunk__c, 'Verified quotes link to the stored text');

            Candidate_Evidence__c k8s = ev.get('Skill|Kubernetes|null');
            Assert.isFalse(k8s.Quote_Verified__c, 'Quote not in the CV');
            Assert.areEqual('Low', k8s.Confidence__c);

            Candidate_Evidence__c beta = ev.get('Role|Developer|Beta Ltd');
            Assert.areEqual('Year', beta.Date_Precision__c);
            Assert.areEqual('Medium', beta.Confidence__c, 'Year-only dates are Medium');
            Assert.isTrue(ev.get('Role|Salesforce Developer|Acme Corp').Is_Current__c);

            Candidate_Evidence__c claimed = ev.get('Years of experience (claimed)|8 years|null');
            Assert.areEqual('Conflicting', claimed.Status__c);
            Assert.areEqual('experience-total', claimed.Conflict_Group__c);
            Assert.areEqual('Low', claimed.Confidence__c);

            Integer overlaps = 0;
            Integer missing = 0;
            for (Candidate_Evidence__c e : ev.values()) {
                if (e.Attribute__c == 'Overlapping roles') {
                    overlaps++;
                    Assert.areEqual('Inferred', e.Status__c);
                }
                if (e.Status__c == 'Missing') {
                    missing++;
                    Assert.areEqual('Phone', e.Attribute__c, 'Only the phone number is missing');
                }
            }
            Assert.areEqual(1, overlaps, 'Beta Ltd (to Dec 2019) overlaps Acme Corp (from Mar 2019)');
            Assert.areEqual(1, missing);
            Assert.areEqual(88, c.Card_Completeness__c, '7 of 8 expected attributes');
        }
    }

    @IsTest
    static void flagsMissingSectionsAndNeedsReview() {
        System.runAs(CvTestFactory.recruiter()) {
            CV_Document__c doc = new CV_Document__c(File_Name__c = 'thin.pdf', File_Type__c = 'PDF');
            insert doc;
            ExtractedText text = new ExtractedText();
            text.method = 'PDF Text Layer';
            text.chunks.add(new ExtractedText.Chunk(1, 1, 'Jane Roe\nAnalyst, Gamma | 2021'));
            Map<String, Object> card = new Map<String, Object>{
                'profile' => new Map<String, Object>(),
                'evidence' => new List<Object>{
                    CvTestFactory.row('Experience', 'Role', 'Analyst', 'Analyst, Gamma', '2021', null),
                    // One-row conflict group: not a conflict.
                    new Map<String, Object>{ 'category' => 'Skill', 'value' => 'Excel', 'status' => 'Inferred', 'conflict_group' => 'x' },
                    new Map<String, Object>{ 'category' => 'Hobby', 'value' => 'Chess' }
                }
            };
            ((Map<String, Object>) ((List<Object>) card.get('evidence'))[0]).put('organization', 'Gamma');
            CandidateCardBuilder.Result r = new CandidateCardBuilder(doc, text).parse(card).save();
            Assert.areEqual('Needs Review', r.cardStatus);
            Assert.isTrue(r.completeness < 50);
            Assert.isTrue(r.missing.contains('Education'));
            Assert.isTrue(r.missing.contains('End date'), 'A past role without an end date is a gap');
            Candidate__c c = [SELECT Name, Has_Conflicts__c FROM Candidate__c WHERE Id = :r.candidateId];
            Assert.areEqual('thin (name not found)', c.Name);
            Assert.isFalse(c.Has_Conflicts__c);
            Candidate_Evidence__c excel = [SELECT Status__c, Inference_Reason__c, Conflict_Group__c FROM Candidate_Evidence__c WHERE Value__c = 'Excel'];
            Assert.areEqual('Inferred', excel.Status__c);
            Assert.isNotNull(excel.Inference_Reason__c, 'Inferred facts always carry a reason');
            Assert.isNull(excel.Conflict_Group__c);
            Assert.areEqual(0, [SELECT COUNT() FROM Candidate_Evidence__c WHERE Value__c = 'Chess'], 'Unknown categories are dropped');
            Assert.areEqual('Needs Review', [SELECT Status__c FROM CV_Document__c WHERE Id = :doc.Id].Status__c);
        }
    }

    @IsTest
    static void flagsPossibleDuplicateByEmail() {
        System.runAs(CvTestFactory.recruiter()) {
            Id first = CvTestFactory.candidate('Omar Khalil', 'omar@example.com', false);
            Id second = CvTestFactory.candidate('Omar Khalil', 'omar@example.com', false);
            Assert.areEqual(first, [SELECT Possible_Duplicate_Of__c FROM Candidate__c WHERE Id = :second].Possible_Duplicate_Of__c);
            // The delayed check flags only the later card and is a no-op once flagged.
            Test.startTest();
            System.enqueueJob(new CvDuplicateCheckJob(first, null));
            CvDuplicateCheckJob.flag(second);
            Test.stopTest();
            Assert.isNull([SELECT Possible_Duplicate_Of__c FROM Candidate__c WHERE Id = :first].Possible_Duplicate_Of__c);
        }
    }

    @IsTest
    static void delayedCheckCatchesCardsCreatedInParallel() {
        System.runAs(CvTestFactory.recruiter()) {
            Candidate__c a = new Candidate__c(Name = 'Twin', Email__c = 'twin@example.com');
            Candidate__c b = new Candidate__c(Name = 'Twin', Email__c = 'twin@example.com');
            insert new List<Candidate__c>{ a, b }; // same transaction: neither saw the other
            CvDuplicateCheckJob.flag(a.Id);
            CvDuplicateCheckJob.flag(b.Id);
            Integer flagged = [SELECT COUNT() FROM Candidate__c WHERE Possible_Duplicate_Of__c != NULL];
            Assert.areEqual(1, flagged, 'Exactly the later card is flagged');
        }
    }

    @IsTest
    static void rejectsEmptyExtraction() {
        CV_Document__c doc = new CV_Document__c(File_Name__c = 'x.pdf', File_Type__c = 'PDF');
        insert doc;
        try {
            new CandidateCardBuilder(doc, new ExtractedText()).parse(new Map<String, Object>());
            Assert.fail('Expected INVALID_JSON');
        } catch (CvAgentException e) {
            Assert.areEqual(CvAgentException.INVALID_JSON, e.code);
        }
    }
}
