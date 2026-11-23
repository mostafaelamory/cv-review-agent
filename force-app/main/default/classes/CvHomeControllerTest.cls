@IsTest
private class CvHomeControllerTest {
    @IsTest
    static void returnsKpisCandidatesShortlistAndRoles() {
        Job_Role__c role = CvTestFactory.role();
        System.runAs(CvTestFactory.recruiter()) {
            Id cid = CvTestFactory.candidate('Sara Ahmed', 'sara@example.com', true);
            Candidate_Evaluation__c ev = new Candidate_Evaluation__c(Candidate__c = cid, Job_Role__c = role.Id, Total_Score__c = 80, Band__c = 'Strong', Is_Current__c = true);
            insert ev;
            insert new Candidate_Bookmark__c(Candidate__c = cid, Job_Role__c = role.Id, Candidate_Evaluation__c = ev.Id, Score__c = 80, Band__c = 'Strong', Status__c = 'Shortlisted', Bookmarked_At__c = System.now(), Bookmark_Key__c = 'k1');
            CvHomeController.Home h = CvHomeController.getHome();
            Map<String, Integer> stats = new Map<String, Integer>();
            for (CvHomeController.Stat s : h.stats) {
                stats.put(s.key, s.value);
            }
            Assert.areEqual(1, stats.get('cards'));
            Assert.areEqual(1, stats.get('shortlist'));
            Assert.areEqual(1, stats.get('ready') + stats.get('review'), 'The factory CV is processed');
            Assert.areEqual(cid, h.recentCandidates[0].Id);
            Assert.areEqual('Sara Ahmed', h.myShortlist[0].Candidate__r.Name);
            Assert.areEqual(1, h.roles.size());
            Assert.areEqual(1, h.roles[0].strong);
            Assert.areEqual(4, h.roles[0].requirements);
        }
    }
}
