/**
 * Server side of the candidateCard LWC: the card header, facts grouped by
 * category with their status, and recruiter corrections.
 */
public with sharing class CandidateCardController {
    public class Fact {
        @AuraEnabled public Id id;
        @AuraEnabled public String category;
        @AuraEnabled public String attribute;
        @AuraEnabled public String value;
        @AuraEnabled public String organization;
        @AuraEnabled public String dates;
        @AuraEnabled public String detail;
        @AuraEnabled public String status;
        @AuraEnabled public String badge;
        @AuraEnabled public String confidence;
        @AuraEnabled public String quote;
        @AuraEnabled public Decimal page;
        @AuraEnabled public String inferenceReason;
        @AuraEnabled public String conflictGroup;
    }

    public class Section {
        @AuraEnabled public String category;
        @AuraEnabled public List<Fact> facts = new List<Fact>();
        @AuraEnabled public Integer issueCount = 0;
    }

    public class Card {
        @AuraEnabled public Candidate__c candidate;
        @AuraEnabled public List<Section> sections = new List<Section>();
        @AuraEnabled public Map<String, Integer> badgeCounts = new Map<String, Integer>();
        @AuraEnabled public List<Map<String, String>> files = new List<Map<String, String>>();
        @AuraEnabled public String experienceLabel;
    }

    @AuraEnabled(cacheable=true)
    public static Card getCard(Id candidateId) {
        List<Candidate__c> cs = [
            SELECT Id, Name, Email__c, Phone__c, Location__c, Headline__c, Summary__c, Total_Experience_Months__c,
                Card_Completeness__c, Has_Conflicts__c, Card_Status__c, Possible_Duplicate_Of__c, Possible_Duplicate_Of__r.Name
            FROM Candidate__c
            WHERE Id = :candidateId
            WITH USER_MODE
        ];
        if (cs.isEmpty()) {
            throw new AuraHandledException('Candidate not found or not visible to you.');
        }
        Card card = new Card();
        card.candidate = cs[0];
        card.experienceLabel = cs[0].Total_Experience_Months__c == null ? null : DateUtil.formatMonths(cs[0].Total_Experience_Months__c.intValue());
        Map<String, Section> byCategory = new Map<String, Section>();
        for (String cat : new List<String>{ 'Contact', 'Experience', 'Skill', 'Education', 'Certification', 'Achievement', 'Language' }) {
            Section s = new Section();
            s.category = cat;
            byCategory.put(cat, s);
        }
        for (Candidate_Evidence__c ev : EvidenceSelector.forCandidates(new Set<Id>{ candidateId })) {
            Fact f = new Fact();
            f.id = ev.Id;
            f.category = ev.Category__c;
            f.attribute = ev.Attribute__c;
            f.value = ev.Value__c;
            f.organization = ev.Organization__c;
            f.dates = EvidenceFormatter.dateRange(ev);
            f.detail = ev.Detail__c;
            f.status = ev.Status__c;
            f.badge = badgeOf(ev);
            f.confidence = ev.Confidence__c;
            f.quote = ev.Source_Quote__c;
            f.page = ev.Source_Page__c;
            f.inferenceReason = ev.Inference_Reason__c;
            f.conflictGroup = ev.Conflict_Group__c;
            Section s = byCategory.get(ev.Category__c);
            if (s == null) {
                continue;
            }
            s.facts.add(f);
            if (f.badge != 'Stated' && f.badge != 'Recruiter-verified') {
                s.issueCount++;
            }
            card.badgeCounts.put(f.badge, (card.badgeCounts.containsKey(f.badge) ? card.badgeCounts.get(f.badge) : 0) + 1);
        }
        for (Section s : byCategory.values()) {
            if (!s.facts.isEmpty()) {
                card.sections.add(s);
            }
        }
        for (CV_Document__c d : [
            SELECT Id, File_Name__c, Content_Document_Id__c, Extraction_Method__c, Status__c
            FROM CV_Document__c
            WHERE Candidate__c = :candidateId
            WITH USER_MODE
            ORDER BY CreatedDate
        ]) {
            card.files.add(new Map<String, String>{
                'documentId' => d.Id,
                'name' => d.File_Name__c,
                'contentDocumentId' => d.Content_Document_Id__c,
                'method' => d.Extraction_Method__c,
                'status' => d.Status__c
            });
        }
        return card;
    }

    /**
     * Recruiter correction: the fact becomes Recruiter-verified (High confidence).
     * Evaluations re-score automatically because the evidence hash changes.
     */
    @AuraEnabled
    public static void correctFact(Id evidenceId, String value, String note) {
        List<Candidate_Evidence__c> evs = [
            SELECT Id, Candidate__c, Value__c, Status__c, Detail__c FROM Candidate_Evidence__c WHERE Id = :evidenceId WITH USER_MODE
        ];
        if (evs.isEmpty()) {
            throw new AuraHandledException('Fact not found.');
        }
        Candidate_Evidence__c current = evs[0];
        String before = current.Value__c + ' (' + current.Status__c + ')';
        // Update only the changed fields; the master-detail field is never written.
        Candidate_Evidence__c ev = new Candidate_Evidence__c(
            Id = current.Id,
            Value__c = JsonUtil.truncate(String.isBlank(value) ? current.Value__c : value.trim(), 255),
            Status__c = 'Stated',
            Recruiter_Verified__c = true,
            Confidence__c = 'High',
            Conflict_Group__c = null,
            Detail__c = JsonUtil.truncate(
                (current.Detail__c == null ? '' : current.Detail__c + '\n') + 'Verified by ' + UserInfo.getName() + ' on ' +
                System.today().format() + (String.isBlank(note) ? '' : ': ' + note),
                5000
            )
        );
        try {
            update as user ev;
            refreshConflictFlag(current.Candidate__c);
        } catch (Exception e) {
            throw new AuraHandledException('Could not save the correction: ' + e.getMessage());
        }
        DecisionLogger.Entry log = DecisionLogger.start('Recruiter correction');
        log.candidateIds.add(current.Candidate__c);
        log.evidenceIds.add(ev.Id);
        log.inputSummary = 'Before: ' + before;
        log.outputSummary = 'After: ' + ev.Value__c + ' (Recruiter-verified)' + (String.isBlank(note) ? '' : '. Note: ' + note);
        DecisionLogger.publish(log);
    }

    private static void refreshConflictFlag(Id candidateId) {
        Map<String, Integer> groups = new Map<String, Integer>();
        for (Candidate_Evidence__c ev : [
            SELECT Conflict_Group__c FROM Candidate_Evidence__c
            WHERE Candidate__c = :candidateId AND Status__c = 'Conflicting' AND Conflict_Group__c != NULL
            WITH USER_MODE
        ]) {
            groups.put(ev.Conflict_Group__c, (groups.containsKey(ev.Conflict_Group__c) ? groups.get(ev.Conflict_Group__c) : 0) + 1);
        }
        Boolean has = false;
        for (Integer n : groups.values()) {
            has = has || n >= 2;
        }
        update as user new Candidate__c(Id = candidateId, Has_Conflicts__c = has);
    }

    public static String badgeOf(Candidate_Evidence__c ev) {
        if (ev.Recruiter_Verified__c == true) {
            return 'Recruiter-verified';
        }
        if (ev.Status__c == 'Stated' && ev.Quote_Verified__c != true) {
            return 'Unverified';
        }
        return ev.Status__c;
    }
}
