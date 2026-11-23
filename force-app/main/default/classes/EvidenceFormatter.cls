/** Compact one-line rendering of an evidence row for prompts and sources. */
public with sharing class EvidenceFormatter {
    public static String line(Candidate_Evidence__c ev, Boolean includeCandidate) {
        List<String> parts = new List<String>();
        if (includeCandidate && ev.Candidate__r != null) {
            parts.add('Candidate: ' + ev.Candidate__r.Name);
        }
        parts.add(ev.Category__c + (ev.Attribute__c == null || ev.Attribute__c == ev.Category__c ? '' : ' / ' + ev.Attribute__c));
        if (ev.Value__c != null) {
            parts.add(ev.Value__c);
        }
        if (ev.Organization__c != null) {
            parts.add('at ' + ev.Organization__c);
        }
        String dates = dateRange(ev);
        if (dates != null) {
            parts.add(dates);
        }
        parts.add(statusLabel(ev));
        if (ev.Detail__c != null) {
            parts.add('detail: ' + ev.Detail__c.left(300).normalizeSpace());
        }
        if (ev.Inference_Reason__c != null && ev.Status__c != 'Stated') {
            parts.add('why: ' + ev.Inference_Reason__c);
        }
        if (ev.Source_Quote__c != null && ev.Quote_Verified__c == true) {
            parts.add('quote: "' + ev.Source_Quote__c.left(240).normalizeSpace() + '"' + (ev.Source_Page__c == null ? '' : ' (p.' + ev.Source_Page__c + ')'));
        }
        return String.join(parts, ' | ');
    }

    /** Stated / Inferred / Missing / Conflicting / Unverified, plus confidence. */
    public static String statusLabel(Candidate_Evidence__c ev) {
        String status = ev.Status__c;
        if (ev.Recruiter_Verified__c == true) {
            status = 'Recruiter-verified';
        } else if (status == 'Stated' && ev.Quote_Verified__c != true) {
            status = 'Unverified';
        }
        if (status == 'Conflicting' && ev.Conflict_Group__c != null) {
            status += ' (group ' + ev.Conflict_Group__c + ')';
        }
        return status + (ev.Confidence__c == null ? '' : ', ' + ev.Confidence__c + ' confidence');
    }

    public static String dateRange(Candidate_Evidence__c ev) {
        if (ev.Start_Date__c == null && ev.End_Date__c == null) {
            return null;
        }
        String fmt = ev.Date_Precision__c == 'Year' ? 'yyyy' : 'yyyy-MM';
        String s = ev.Start_Date__c == null ? '?' : Datetime.newInstance(ev.Start_Date__c, Time.newInstance(12, 0, 0, 0)).format(fmt);
        String e = ev.Is_Current__c == true
            ? 'present'
            : (ev.End_Date__c == null ? '?' : Datetime.newInstance(ev.End_Date__c, Time.newInstance(12, 0, 0, 0)).format(fmt));
        return s + ' to ' + e;
    }
}
