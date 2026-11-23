/**
 * All reads of candidate data go through here, in user mode, so the agent can
 * only ever see what the recruiter can see.
 */
public with sharing class EvidenceSelector {
    private static final String EVIDENCE_FIELDS =
        'Id, Candidate__c, Candidate__r.Name, Category__c, Attribute__c, Value__c, Organization__c, ' +
        'Start_Date__c, End_Date__c, Is_Current__c, Date_Precision__c, Detail__c, Status__c, Confidence__c, ' +
        'Quote_Verified__c, Source_Quote__c, Source_Page__c, Conflict_Group__c, Inference_Reason__c, ' +
        'Recruiter_Verified__c, LastModifiedDate';

    public static List<Candidate_Evidence__c> forCandidates(Set<Id> candidateIds) {
        return Database.query(
            'SELECT ' + EVIDENCE_FIELDS + ' FROM Candidate_Evidence__c WHERE Candidate__c IN :candidateIds ' +
            'WITH USER_MODE ORDER BY Candidate__c, Category__c, Start_Date__c DESC NULLS LAST, Id LIMIT 2000'
        );
    }

    /**
     * Keyword-filtered evidence across candidates. Matches on Value, Attribute and
     * Organization (Text fields, so SOQL can filter them) and always includes
     * Missing and Conflicting rows in the requested categories, so gaps surface.
     */
    public static List<Candidate_Evidence__c> search(Set<Id> candidateIds, List<String> keywords, Set<String> categories, Integer maxRows) {
        List<String> likes = new List<String>();
        for (String k : keywords) {
            likes.add('%' + String.escapeSingleQuotes(k) + '%');
        }
        List<String> clauses = new List<String>{ 'Candidate__c IN :candidateIds' };
        if (categories != null && !categories.isEmpty()) {
            clauses.add('Category__c IN :categories');
        }
        if (!likes.isEmpty()) {
            clauses.add('(Value__c LIKE :likes OR Attribute__c LIKE :likes OR Organization__c LIKE :likes)');
        }
        return Database.query(
            'SELECT ' + EVIDENCE_FIELDS + ' FROM Candidate_Evidence__c WHERE ' + String.join(clauses, ' AND ') +
            ' WITH USER_MODE ORDER BY Candidate__c, Category__c LIMIT ' + Math.max(1, maxRows)
        );
    }

    /** Stored CV text for candidates (recall beyond the structured facts). */
    public static List<CV_Text_Chunk__c> chunksFor(Set<Id> candidateIds) {
        return [
            SELECT Id, Sequence__c, Page__c, Text__c, CV_Document__c, CV_Document__r.Candidate__c,
                CV_Document__r.Candidate__r.Name, CV_Document__r.File_Name__c, CV_Document__r.Content_Document_Id__c
            FROM CV_Text_Chunk__c
            WHERE CV_Document__r.Candidate__c IN :candidateIds
            WITH USER_MODE
            ORDER BY CV_Document__c, Sequence__c
            LIMIT 200
        ];
    }

    /** SOSL on stored text: chunk ids that mention any of the terms. */
    public static Set<Id> chunkIdsMatching(List<String> terms, Set<Id> candidateIds) {
        Set<Id> out = new Set<Id>();
        List<String> clean = new List<String>();
        for (String t : terms) {
            String s = t.replaceAll('[?&|!{}\\[\\]()^~*:\\\\"\'+\\-]', ' ').trim();
            if (s.length() >= 2) {
                clean.add('"' + s + '"');
            }
        }
        if (clean.isEmpty()) {
            return out;
        }
        String sosl =
            'FIND {' + String.join(clean, ' OR ') + '} IN ALL FIELDS RETURNING ' +
            'CV_Text_Chunk__c(Id, CV_Document__r.Candidate__c) LIMIT 200';
        List<List<SObject>> res = Search.query(sosl, AccessLevel.USER_MODE);
        for (SObject s : res[0]) {
            CV_Text_Chunk__c c = (CV_Text_Chunk__c) s;
            if (candidateIds == null || candidateIds.contains(c.CV_Document__r?.Candidate__c)) {
                out.add(c.Id);
            }
        }
        return out;
    }

    public static Map<Id, Candidate__c> candidates(Set<Id> ids) {
        return new Map<Id, Candidate__c>([
            SELECT Id, Name, Headline__c, Location__c, Email__c, Total_Experience_Months__c, Card_Completeness__c,
                Has_Conflicts__c, Card_Status__c, Summary__c
            FROM Candidate__c
            WHERE Id IN :ids
            WITH USER_MODE
        ]);
    }

    public static Job_Role__c role(Id roleId) {
        List<Job_Role__c> roles = [
            SELECT Id, Name, Description__c,
                (SELECT Id, Requirement__c, Type__c, Category__c, Weight__c, Min_Years__c, Keywords__c, LastModifiedDate
                 FROM Requirements__r ORDER BY Type__c, Weight__c DESC, Name)
            FROM Job_Role__c
            WHERE Id = :roleId
            WITH USER_MODE
        ];
        if (roles.isEmpty()) {
            throw new CvAgentException('Job role not found or not visible to you').withCode(CvAgentException.NOT_FOUND);
        }
        return roles[0];
    }
}
