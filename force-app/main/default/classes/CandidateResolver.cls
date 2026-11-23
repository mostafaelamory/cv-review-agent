/**
 * Resolves the names a recruiter types ("Sara", "Omar Khalil") to candidate and
 * role records. Ambiguous names are returned as options instead of guessed.
 */
public with sharing class CandidateResolver {
    public class Resolution {
        public List<Candidate__c> matched = new List<Candidate__c>();
        /** name typed => the candidates it could mean */
        public Map<String, List<Candidate__c>> ambiguous = new Map<String, List<Candidate__c>>();
        public List<String> notFound = new List<String>();

        public Set<Id> ids() {
            return new Map<Id, Candidate__c>(matched).keySet();
        }
        public Boolean needsClarification() {
            return !ambiguous.isEmpty() || !notFound.isEmpty();
        }
        public String clarification() {
            List<String> parts = new List<String>();
            for (String n : ambiguous.keySet()) {
                List<String> options = new List<String>();
                for (Candidate__c c : ambiguous.get(n)) {
                    List<String> details = new List<String>();
                    if (c.Headline__c != null) {
                        details.add(c.Headline__c);
                    }
                    if (c.Email__c != null) {
                        details.add(c.Email__c);
                    }
                    details.add('card created ' + c.CreatedDate.format('d MMM yyyy HH:mm'));
                    if (c.Possible_Duplicate_Of__c != null) {
                        details.add('possible duplicate of an earlier card');
                    }
                    details.add('id ' + c.Id);
                    options.add(c.Name + ' (' + String.join(details, ', ') + ')');
                }
                parts.add('"' + n + '" matches several candidates: ' + String.join(options, '; ') + '. Which one did you mean?');
            }
            if (!notFound.isEmpty()) {
                parts.add('No candidate found named: ' + String.join(notFound, ', ') + '.');
            }
            return String.join(parts, ' ');
        }
    }

    /** Splits "Sara, Omar and Lina" into names. */
    public static List<String> splitNames(String raw) {
        List<String> out = new List<String>();
        if (String.isBlank(raw)) {
            return out;
        }
        for (String n : raw.replaceAll('(?i)\\s+(and|&)\\s+', ',').split('[,;\\n]')) {
            if (String.isNotBlank(n.trim())) {
                out.add(n.trim());
            }
        }
        return out;
    }

    public static Resolution resolve(List<String> names) {
        Resolution r = new Resolution();
        for (String name : names) {
            // An id is accepted as-is.
            Id asCandidateId = asId(name);
            if (asCandidateId != null) {
                List<Candidate__c> byId = [SELECT Id, Name, Headline__c FROM Candidate__c WHERE Id = :asCandidateId WITH USER_MODE];
                if (!byId.isEmpty()) {
                    r.matched.add(byId[0]);
                    continue;
                }
            }
            String nameLike = '%' + String.escapeSingleQuotes(name.trim()) + '%';
            List<Candidate__c> found = [
                SELECT Id, Name, Headline__c, Email__c, CreatedDate, Possible_Duplicate_Of__c
                FROM Candidate__c
                WHERE Name LIKE :nameLike OR Full_Name__c LIKE :nameLike
                WITH USER_MODE
                ORDER BY CreatedDate DESC
                LIMIT 6
            ];
            List<Candidate__c> exact = new List<Candidate__c>();
            for (Candidate__c c : found) {
                if (c.Name.equalsIgnoreCase(name.trim())) {
                    exact.add(c);
                }
            }
            if (exact.size() == 1) {
                r.matched.add(exact[0]);
            } else if (found.size() == 1) {
                r.matched.add(found[0]);
            } else if (found.isEmpty()) {
                r.notFound.add(name);
            } else {
                r.ambiguous.put(name, exact.size() > 1 ? exact : found);
            }
        }
        return r;
    }

    /** Most recent candidates with a usable card; the default scope of cross-candidate questions. */
    public static List<Candidate__c> recent(Integer max) {
        return [
            SELECT Id, Name, Headline__c
            FROM Candidate__c
            WHERE Card_Status__c IN ('Ready', 'Needs Review')
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT :max
        ];
    }

    /** Candidates whose CVs were uploaded against a role, or who were already evaluated for it. */
    public static List<Candidate__c> forRole(Id roleId, Integer max) {
        Set<Id> ids = new Set<Id>();
        for (CV_Document__c d : [
            SELECT Candidate__c FROM CV_Document__c
            WHERE Job_Role__c = :roleId AND Candidate__c != NULL
            WITH USER_MODE LIMIT 200
        ]) {
            ids.add(d.Candidate__c);
        }
        for (Candidate_Evaluation__c e : [
            SELECT Candidate__c FROM Candidate_Evaluation__c
            WHERE Job_Role__c = :roleId AND Is_Current__c = TRUE
            WITH USER_MODE LIMIT 200
        ]) {
            ids.add(e.Candidate__c);
        }
        return [
            SELECT Id, Name, Headline__c FROM Candidate__c
            WHERE Id IN :ids AND Card_Status__c IN ('Ready', 'Needs Review')
            WITH USER_MODE ORDER BY CreatedDate DESC LIMIT :max
        ];
    }

    /** Role by id or by (partial) name; null when not found, exception when ambiguous. */
    public static Job_Role__c resolveRole(String nameOrId) {
        if (String.isBlank(nameOrId)) {
            return null;
        }
        String nameLike = '%' + String.escapeSingleQuotes(nameOrId.trim()) + '%';
        Id roleId = asId(nameOrId);
        List<Job_Role__c> roles = [
            SELECT Id, Name FROM Job_Role__c
            WHERE Name LIKE :nameLike OR Id = :roleId
            WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 5
        ];
        for (Job_Role__c r : roles) {
            if (r.Name.equalsIgnoreCase(nameOrId.trim()) || r.Id == roleId) {
                return r;
            }
        }
        if (roles.size() > 1) {
            List<String> names = new List<String>();
            for (Job_Role__c r : roles) {
                names.add(r.Name);
            }
            throw new CvAgentException('Several roles match "' + nameOrId + '": ' + String.join(names, '; ') + '. Which one?')
                .withCode(CvAgentException.NOT_FOUND);
        }
        return roles.isEmpty() ? null : roles[0];
    }

    /** The value as an Id when it is one, else null. */
    public static Id asId(String value) {
        if (value == null || !Pattern.matches('[a-zA-Z0-9]{15}|[a-zA-Z0-9]{18}', value.trim())) {
            return null;
        }
        try {
            return Id.valueOf(value.trim());
        } catch (Exception e) {
            return null;
        }
    }
}
