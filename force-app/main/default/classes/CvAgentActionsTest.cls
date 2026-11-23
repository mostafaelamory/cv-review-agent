@IsTest
private class CvAgentActionsTest {
    static String assessAllMet(Integer reqCount) {
        List<Object> items = new List<Object>();
        for (Integer i = 1; i <= reqCount; i++) {
            items.add(new Map<String, Object>{ 'requirement' => 'R' + i, 'match' => 'Met', 'evidence' => new List<String>{ 'E1' }, 'rationale' => 'ok' });
        }
        return JSON.serialize(new Map<String, Object>{ 'assessments' => items });
    }

    static CvAnswerQuestionAction.Response ask(String q, String names) {
        CvAnswerQuestionAction.Request r = new CvAnswerQuestionAction.Request();
        r.question = q;
        r.candidateNames = names;
        return CvAnswerQuestionAction.answer(new List<CvAnswerQuestionAction.Request>{ r })[0];
    }

    @IsTest
    static void answersWithVerifiedCitations() {
        System.runAs(CvTestFactory.recruiter()) {
            CvTestFactory.candidate('Sara Ahmed', 'sara@example.com', true);
            StubLlmService.enqueue(PromptCatalog.ANSWER_QUESTION, '{"segments":[{"text":"Sara has Apex experience.","sources":["E1","T1"]}]}');
            CvAnswerQuestionAction.Response res = ask('Does Sara have Apex?', 'Sara');
            Assert.areEqual('Success', res.outcome);
            Assert.isTrue(res.answer.startsWith('Sara has Apex experience. [1][2]'));
            Assert.isTrue(res.sources.contains('[2] Sara Ahmed - CV text'));
            Assert.isTrue(StubLlmService.calls[0].textInputs.get('Evidence').contains('[T1]'), 'One candidate: full text included');
        }
    }

    @IsTest
    static void ungroundedAnswerIsRetriedThenNotStated() {
        System.runAs(CvTestFactory.recruiter()) {
            CvTestFactory.candidate('Sara Ahmed', 'sara@example.com', true);
            StubLlmService.enqueue(PromptCatalog.ANSWER_QUESTION, '{"segments":[{"text":"Sara earns a lot.","sources":[]}]}');
            StubLlmService.enqueue(PromptCatalog.ANSWER_QUESTION, '{"segments":[{"text":"Sara earns a lot.","sources":["E999"]}]}');
            CvAnswerQuestionAction.Response res = ask('What is Sara\'s salary?', 'Sara');
            Assert.areEqual(AnswerService.NOT_STATED, res.answer);
            Assert.areEqual('Ungrounded', res.outcome);
            Assert.areEqual(2, StubLlmService.calls.size());
            Assert.isTrue(StubLlmService.calls[1].textInputs.get('Feedback').contains('without valid evidence'));
        }
    }

    @IsTest
    static void invalidSegmentsAreDroppedAfterRetry() {
        System.runAs(CvTestFactory.recruiter()) {
            CvTestFactory.candidate('Sara Ahmed', 'sara@example.com', true);
            String mixed = '{"segments":[{"text":"Has Apex.","sources":["E1"]},{"text":"Loves cats.","sources":[]}]}';
            StubLlmService.enqueue(PromptCatalog.ANSWER_QUESTION, mixed);
            StubLlmService.enqueue(PromptCatalog.ANSWER_QUESTION, mixed);
            CvAnswerQuestionAction.Response res = ask('Tell me about Sara', 'Sara');
            Assert.areEqual('Partial', res.outcome);
            Assert.isFalse(res.answer.contains('cats'));
        }
    }

    @IsTest
    static void crossCandidateAndAmbiguousNames() {
        System.runAs(CvTestFactory.recruiter()) {
            CvTestFactory.candidate('Sara Ahmed', 'sara@example.com', true);
            CvTestFactory.candidate('Sara Nabil', 'nabil@example.com', false);
            CvTestFactory.candidate('Omar Khalil', 'omar@example.com', false);
            CvAnswerQuestionAction.Response amb = ask('Does Sara know LWC?', 'Sara');
            Assert.isTrue(amb.needsClarification);
            Assert.isTrue(amb.answer.contains('Sara Nabil'));
            Assert.isTrue(ask('Who knows Rust?', 'Nobody Here').answer.contains('No candidate found'));

            // Heuristic stub answers from keyword-matched evidence.
            CvAnswerQuestionAction.Response all = ask('Who has LWC?', '');
            Assert.isTrue(all.answer.contains('LWC'));
            Assert.isTrue(StubLlmService.calls[StubLlmService.calls.size() - 1].textInputs.get('Candidates').contains('Omar Khalil'));
        }
    }

    @IsTest
    static void evaluatesRanksCachesAndBookmarks() {
        Job_Role__c role = CvTestFactory.role();
        User u = CvTestFactory.recruiter();
        System.runAs(u) {
            Id sara = CvTestFactory.candidate('Sara Ahmed', 'sara@example.com', true);
            Id omar = CvTestFactory.candidate('Omar Khalil', 'omar@example.com', false);
            // Requirements sent to the model exclude the Min Years one (decided in Apex): R1 Apex, R2 LWC, R4 degree.
            StubLlmService.enqueue(PromptCatalog.ASSESS_REQUIREMENTS, assessAllMet(4));
            StubLlmService.enqueue(PromptCatalog.ASSESS_REQUIREMENTS,
                '{"assessments":[{"requirement":"R1","match":"Met","evidence":["E1"]},{"requirement":"R2","match":"Met","evidence":["E999"]}]}');
            StubLlmService.enqueue(PromptCatalog.RECOMMEND,
                '{"recommendation":"Hire Sara Ahmed (C1).","trade_offs":"C2 lacks LWC.","candidates":[{"id":"C1","strengths":["Apex [R1]"],"concerns":[],"interview_probes":["Ask about LWC testing"]}]}');

            CvEvaluateCandidatesAction.Request req = new CvEvaluateCandidatesAction.Request();
            req.roleName = 'Senior Salesforce';
            req.candidateNames = 'Sara Ahmed, Omar Khalil';
            CvEvaluateCandidatesAction.Response res = CvEvaluateCandidatesAction.evaluate(new List<CvEvaluateCandidatesAction.Request>{ req })[0];
            Assert.isTrue(res.hasEvaluation);
            Assert.areEqual('Sara Ahmed', res.topCandidate);
            CvEvaluateCandidatesAction.EvaluationResult er = res.evaluationResult;
            Assert.areEqual(2, er.rows.size());
            Assert.areEqual('Hire Sara Ahmed.', er.recommendation, 'Internal ids are stripped from prose');
            Assert.areEqual('Strong', er.rows[0].band);
            Assert.areEqual('• Apex', er.rows[0].strengths);
            Assert.isTrue(er.rows[1].mustHaveGaps >= 1, 'Omar: LWC downgraded for citing an unknown id');
            Assert.isTrue(res.summary.contains('Must-have gaps: Lightning Web Components'));

            ScoringService.Line years;
            for (ScoringService.Line l : EvaluationService.parseLines([SELECT Breakdown_JSON__c FROM Candidate_Evaluation__c WHERE Candidate__c = :sara].Breakdown_JSON__c)) {
                if (l.requirement.startsWith('3+')) {
                    years = l;
                }
            }
            Assert.areEqual('Apex date maths', years.decidedBy);
            Assert.areEqual('Met', years.match);

            // Second run: same inputs, so both evaluations come from cache (only the recommendation is called).
            Integer callsBefore = StubLlmService.calls.size();
            CvEvaluateCandidatesAction.evaluate(new List<CvEvaluateCandidatesAction.Request>{ req });
            Assert.areEqual(callsBefore + 1, StubLlmService.calls.size());
            Assert.areEqual(2, [SELECT COUNT() FROM Candidate_Evaluation__c], 'No new evaluations for unchanged inputs');

            // Why A over B
            CvExplainRankingAction.Request ex = new CvExplainRankingAction.Request();
            ex.roleName = 'Senior Salesforce Developer';
            ex.candidateA = 'Omar Khalil';
            ex.candidateB = 'Sara Ahmed';
            String explanation = CvExplainRankingAction.explain(new List<CvExplainRankingAction.Request>{ ex })[0].explanation;
            Assert.isTrue(explanation.startsWith('Sara Ahmed scored'), 'Higher scorer is named first');
            Assert.isTrue(explanation.contains('Lightning Web Components'));

            // Bookmark with notes; a second request returns the same record.
            CvCreateBookmarkAction.Request b = new CvCreateBookmarkAction.Request();
            b.candidateName = 'Sara Ahmed';
            b.roleName = 'Senior Salesforce Developer';
            b.notes = 'Strong on Apex; check LWC testing.';
            CvCreateBookmarkAction.Response br = CvCreateBookmarkAction.create(new List<CvCreateBookmarkAction.Request>{ b })[0];
            Assert.isFalse(br.alreadyExisted);
            Assert.isTrue(br.message.startsWith('Bookmarked Sara Ahmed'));
            CvCreateBookmarkAction.Response again = CvCreateBookmarkAction.create(new List<CvCreateBookmarkAction.Request>{ b })[0];
            Assert.isTrue(again.alreadyExisted);
            Assert.areEqual(br.bookmarkId, again.bookmarkId);

            Candidate_Bookmark__c bm = [SELECT Overview_Snapshot__c, Reasoning__c, Notes__c, Score__c, Band__c, Status__c FROM Candidate_Bookmark__c];
            Assert.isTrue(bm.Overview_Snapshot__c.contains('Sara Ahmed'));
            Assert.isTrue(bm.Reasoning__c.contains('Breakdown:'));
            Assert.areEqual(b.notes, bm.Notes__c);
            bm.Status__c = 'Interviewing';
            update bm;
            bm.Notes__c = 'changed';
            try {
                update bm;
                Assert.fail('Bookmarks are immutable');
            } catch (DmlException e) {
                Assert.isTrue(e.getMessage().contains('immutable'));
            }

            // Omar was never bookmarked; Karim was never evaluated.
            b.candidateName = 'Nobody';
            Assert.isTrue(CvCreateBookmarkAction.create(new List<CvCreateBookmarkAction.Request>{ b })[0].message.contains('No candidate found'));
        }
    }

    @IsTest
    static void evaluationGuardsAndBookmarkBeforeScoring() {
        CvTestFactory.role();
        System.runAs(CvTestFactory.recruiter()) {
            CvTestFactory.candidate('Karim Saleh', 'karim@example.com', false);
            CvEvaluateCandidatesAction.Request req = new CvEvaluateCandidatesAction.Request();
            req.roleName = 'Astronaut';
            CvEvaluateCandidatesAction.Response res = CvEvaluateCandidatesAction.evaluate(new List<CvEvaluateCandidatesAction.Request>{ req })[0];
            Assert.isTrue(res.needsClarification);
            Assert.isFalse(res.hasEvaluation);
            req.roleName = 'Senior Salesforce Developer';
            res = CvEvaluateCandidatesAction.evaluate(new List<CvEvaluateCandidatesAction.Request>{ req })[0];
            Assert.isTrue(res.summary.contains('No candidates are linked'));

            CvCreateBookmarkAction.Request b = new CvCreateBookmarkAction.Request();
            b.candidateName = 'Karim Saleh';
            b.roleName = 'Senior Salesforce Developer';
            Assert.isTrue(CvCreateBookmarkAction.create(new List<CvCreateBookmarkAction.Request>{ b })[0].message.contains('not been evaluated'));
        }
    }

    @IsTest
    static void recommendationFailureKeepsTheRanking() {
        CvTestFactory.role();
        System.runAs(CvTestFactory.recruiter()) {
            CvTestFactory.candidate('Lina Haddad', 'lina@example.com', true);
            StubLlmService.enqueue(PromptCatalog.ASSESS_REQUIREMENTS, assessAllMet(4));
            StubLlmService.enqueue(PromptCatalog.RECOMMEND, 'not json');
            CvEvaluateCandidatesAction.Request req = new CvEvaluateCandidatesAction.Request();
            req.roleName = 'Senior Salesforce Developer';
            req.candidateNames = 'Lina';
            CvEvaluateCandidatesAction.Response res = CvEvaluateCandidatesAction.evaluate(new List<CvEvaluateCandidatesAction.Request>{ req })[0];
            Assert.isTrue(res.hasEvaluation);
            Assert.isTrue(res.evaluationResult.recommendation.contains('unavailable'));
        }
    }

    @IsTest
    static void queuesCandidatesBeyondTheInlineLimit() {
        Job_Role__c role = CvTestFactory.role();
        System.runAs(CvTestFactory.recruiter()) {
            List<Id> ids = new List<Id>{
                CvTestFactory.candidate('A One', 'a@example.com', true),
                CvTestFactory.candidate('B Two', 'b@example.com', true)
            };
            Test.startTest();
            EvaluationService.Outcome o = EvaluationService.evaluate(role.Id, ids, 1, false);
            Assert.areEqual(1, o.ranked.size());
            Assert.areEqual(1, o.queued.size());
            Test.stopTest(); // runs CvEvaluationJob for the queued candidate
            Assert.areEqual(2, [SELECT COUNT() FROM Candidate_Evaluation__c WHERE Is_Current__c = TRUE]);
        }
    }

    @IsTest
    static void reportsIngestionStatus() {
        System.runAs(CvTestFactory.recruiter()) {
            insert new List<CV_Document__c>{
                new CV_Document__c(File_Name__c = 'a.pdf', Status__c = 'Failed', Failure_Reason__c = 'Unreadable'),
                new CV_Document__c(File_Name__c = 'b.docx', Status__c = 'Extracted')
            };
            CvIngestionStatusAction.Request r = new CvIngestionStatusAction.Request();
            r.status = 'Failed';
            String s = CvIngestionStatusAction.status(new List<CvIngestionStatusAction.Request>{ r })[0].summary;
            Assert.isTrue(s.contains('a.pdf: Failed. Unreadable'));
            Assert.isFalse(s.contains('b.docx'));
            r.status = null;
            r.name = 'nothing-matches';
            Assert.isTrue(CvIngestionStatusAction.status(new List<CvIngestionStatusAction.Request>{ r })[0].summary.startsWith('No uploaded CVs'));
        }
    }

    @IsTest
    static void cardControllerShowsBadgesAndAcceptsCorrections() {
        System.runAs(CvTestFactory.recruiter()) {
            Id cid = CvTestFactory.candidate('Sara Ahmed', 'sara@example.com', true);
            CandidateCardController.Card card = CandidateCardController.getCard(cid);
            Assert.isTrue(card.badgeCounts.containsKey('Unverified'));
            Assert.isTrue(card.badgeCounts.containsKey('Conflicting'));
            Assert.isTrue(card.badgeCounts.containsKey('Missing'));
            Assert.areEqual('Contact', card.sections[0].category);

            Candidate_Evidence__c claimed = [SELECT Id FROM Candidate_Evidence__c WHERE Candidate__c = :cid AND Attribute__c = 'Years of experience (claimed)'];
            CandidateCardController.correctFact(claimed.Id, '11 years', 'Confirmed by phone');
            Candidate_Evidence__c after = [SELECT Status__c, Confidence__c, Recruiter_Verified__c, Value__c, Detail__c FROM Candidate_Evidence__c WHERE Id = :claimed.Id];
            Assert.areEqual('High', after.Confidence__c);
            Assert.isTrue(after.Recruiter_Verified__c);
            Assert.areEqual('Recruiter-verified', CandidateCardController.badgeOf([SELECT Status__c, Quote_Verified__c, Recruiter_Verified__c FROM Candidate_Evidence__c WHERE Id = :claimed.Id]));
            Assert.isFalse([SELECT Has_Conflicts__c FROM Candidate__c WHERE Id = :cid].Has_Conflicts__c, 'The other side of the conflict is alone now');
        }
    }

    @IsTest
    static void decisionLogsAreWrittenFromEvents() {
        DecisionLogger.Entry e = DecisionLogger.start('Test action').template(PromptCatalog.ANSWER_QUESTION);
        e.jobRoleId = UserInfo.getUserId(); // wrong type on purpose
        e.outcome = 'Ungrounded';
        Test.startTest();
        DecisionLogger.publish(e);
        Test.stopTest();
        Agent_Decision_Log__c row = [SELECT Action__c, Outcome__c, Prompt_Version__c, User__c, Job_Role__c FROM Agent_Decision_Log__c];
        Assert.areEqual('Test action', row.Action__c);
        Assert.areEqual('Ungrounded', row.Outcome__c);
        Assert.areEqual('CV_Answer_Question:v2', row.Prompt_Version__c);
        Assert.areEqual(UserInfo.getUserId(), row.User__c);
        Assert.isNull(row.Job_Role__c, 'An id of the wrong type or a deleted role is dropped, not fatal');
    }

    @IsTest
    static void usersWithoutAccessSeeNothing() {
        Id cid;
        System.runAs(CvTestFactory.recruiter()) {
            cid = CvTestFactory.candidate('Private Person', 'private@example.com', true);
        }
        System.runAs(CvTestFactory.recruiter()) {
            // Another recruiter: Candidate__c is private, so the card is invisible.
            CvAnswerQuestionAction.Response res = ask('Does Private know Apex?', 'Private Person');
            Assert.isTrue(res.needsClarification, 'Not found for a user who cannot see the record');
            try {
                CandidateCardController.getCard(cid);
                Assert.fail('Expected no access');
            } catch (AuraHandledException e) {
                Assert.isNotNull(e);
            }
        }
    }
}
