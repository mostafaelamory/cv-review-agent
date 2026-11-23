/** Data for the CV Review home page: KPIs, recent candidates, my shortlist and open roles. */
public with sharing class CvHomeController {
    public class Stat {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public Integer value;
        @AuraEnabled public String helpText;
        Stat(String key, String label, Integer value, String helpText) {
            this.key = key;
            this.label = label;
            this.value = value;
            this.helpText = helpText;
        }
    }

    public class Home {
        @AuraEnabled public String firstName;
        @AuraEnabled public List<Stat> stats = new List<Stat>();
        @AuraEnabled public List<Candidate__c> recentCandidates;
        @AuraEnabled public List<Candidate_Bookmark__c> myShortlist;
        @AuraEnabled public List<RoleSummary> roles = new List<RoleSummary>();
    }

    public class RoleSummary {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public Integer requirements;
        @AuraEnabled public Integer evaluated;
        @AuraEnabled public Integer strong;
    }

    @AuraEnabled(cacheable=true)
    public static Home getHome() {
        Home h = new Home();
        h.firstName = UserInfo.getFirstName();

        Map<String, Integer> byStatus = new Map<String, Integer>();
        for (AggregateResult ar : [
            SELECT Status__c status, COUNT(Id) n FROM CV_Document__c
            WHERE CreatedDate = LAST_N_DAYS:30 WITH USER_MODE GROUP BY Status__c
        ]) {
            byStatus.put((String) ar.get('status'), (Integer) ar.get('n'));
        }
        Integer inFlight = val(byStatus, 'Queued') + val(byStatus, 'Processing');
        h.stats.add(new Stat('cards', 'Candidate cards', [SELECT COUNT() FROM Candidate__c WITH USER_MODE], 'Cards you can see'));
        h.stats.add(new Stat('ready', 'Ready', val(byStatus, 'Extracted'), 'CVs extracted, last 30 days'));
        h.stats.add(new Stat('review', 'Needs review', val(byStatus, 'Needs Review'), 'Low completeness or unverified quotes'));
        h.stats.add(new Stat('failed', 'Failed', val(byStatus, 'Failed'), 'Unsupported or unreadable files'));
        if (inFlight > 0) {
            h.stats.add(new Stat('processing', 'Processing', inFlight, 'Still being read'));
        }
        h.stats.add(new Stat('shortlist', 'My shortlist', [
            SELECT COUNT() FROM Candidate_Bookmark__c
            WHERE OwnerId = :UserInfo.getUserId() AND Status__c IN ('Shortlisted', 'Interviewing') WITH USER_MODE
        ], 'Bookmarked and still active'));

        h.recentCandidates = [
            SELECT Id, Name, Headline__c, Card_Status__c, Card_Completeness__c, Has_Conflicts__c, Possible_Duplicate_Of__c, CreatedDate
            FROM Candidate__c WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 6
        ];
        h.myShortlist = [
            SELECT Id, Name, Candidate__c, Candidate__r.Name, Job_Role__r.Name, Score__c, Band__c, Status__c, Bookmarked_At__c, Notes__c
            FROM Candidate_Bookmark__c
            WHERE OwnerId = :UserInfo.getUserId() AND Status__c IN ('Shortlisted', 'Interviewing')
            WITH USER_MODE ORDER BY Bookmarked_At__c DESC LIMIT 6
        ];

        Map<Id, RoleSummary> roles = new Map<Id, RoleSummary>();
        for (Job_Role__c r : [
            SELECT Id, Name, (SELECT Id FROM Requirements__r) FROM Job_Role__c
            WHERE Status__c = 'Open' WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 5
        ]) {
            RoleSummary s = new RoleSummary();
            s.id = r.Id;
            s.name = r.Name;
            s.requirements = r.Requirements__r.size();
            s.evaluated = 0;
            s.strong = 0;
            roles.put(r.Id, s);
        }
        for (AggregateResult ar : [
            SELECT Job_Role__c role, Band__c band, COUNT(Id) n FROM Candidate_Evaluation__c
            WHERE Job_Role__c IN :roles.keySet() AND Is_Current__c = TRUE WITH USER_MODE GROUP BY Job_Role__c, Band__c
        ]) {
            RoleSummary s = roles.get((Id) ar.get('role'));
            Integer n = (Integer) ar.get('n');
            s.evaluated += n;
            if (ar.get('band') == 'Strong') {
                s.strong += n;
            }
        }
        h.roles = roles.values();
        return h;
    }

    private static Integer val(Map<String, Integer> m, String key) {
        return m.containsKey(key) ? m.get(key) : 0;
    }
}
