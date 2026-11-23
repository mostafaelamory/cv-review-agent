/** Agent action: which CVs are ready, still processing, need review or failed. */
public with sharing class CvIngestionStatusAction {
    public class Request {
        @InvocableVariable(label='Candidate or File Name' description='Optional candidate or file name to check.')
        public String name;
        @InvocableVariable(label='Status' description='Optional filter: Queued, Processing, Extracted, Needs Review, Failed or Duplicate.')
        public String status;
        @InvocableVariable(label='Days' description='How many days back to look. Default 7.')
        public Integer days;
    }

    public class Response {
        @InvocableVariable(label='Summary' description='Counts by status and one line per matching file with its reason.')
        public String summary;
    }

    @InvocableMethod(
        label='Get Ingestion Status'
        description='Reports the processing status of uploaded CVs, with failure reasons.'
        category='CV Review'
    )
    public static List<Response> status(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request r : requests) {
            Response res = new Response();
            res.summary = summarize(r);
            out.add(res);
        }
        DecisionLogger.Entry log = DecisionLogger.start('Get ingestion status');
        log.outputSummary = out.isEmpty() ? null : out[0].summary;
        DecisionLogger.publish(log);
        return out;
    }

    private static String summarize(Request r) {
        Integer days = r.days == null || r.days <= 0 ? 7 : Math.min(r.days, 365);
        Datetime since = System.now().addDays(-days);
        String nameLike = String.isBlank(r.name) ? null : '%' + String.escapeSingleQuotes(r.name.trim()) + '%';
        String statusFilter = String.isBlank(r.status) ? null : r.status.trim();
        List<CV_Document__c> docs = [
            SELECT Name, File_Name__c, Status__c, Failure_Reason__c, Candidate__r.Name, Candidate__r.Card_Completeness__c, CreatedDate
            FROM CV_Document__c
            WHERE CreatedDate >= :since
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 200
        ];
        Map<String, Integer> counts = new Map<String, Integer>();
        List<String> lines = new List<String>();
        for (CV_Document__c d : docs) {
            if (statusFilter != null && !statusFilter.equalsIgnoreCase(d.Status__c)) {
                continue;
            }
            if (nameLike != null) {
                String needle = r.name.trim().toLowerCase();
                String hay = ((d.File_Name__c == null ? '' : d.File_Name__c) + ' ' + (d.Candidate__r?.Name == null ? '' : d.Candidate__r.Name)).toLowerCase();
                if (!hay.contains(needle)) {
                    continue;
                }
            }
            counts.put(d.Status__c, (counts.containsKey(d.Status__c) ? counts.get(d.Status__c) : 0) + 1);
            if (lines.size() < 25) {
                lines.add(
                    '- ' + d.File_Name__c + ': ' + d.Status__c +
                    (d.Candidate__r?.Name == null ? '' : ' -> ' + d.Candidate__r.Name + ' (card ' + d.Candidate__r.Card_Completeness__c + '% complete)') +
                    (d.Failure_Reason__c == null ? '' : '. ' + d.Failure_Reason__c)
                );
            }
        }
        if (lines.isEmpty()) {
            return 'No uploaded CVs match in the last ' + days + ' days.';
        }
        List<String> countParts = new List<String>();
        for (String k : counts.keySet()) {
            countParts.add(k + ' ' + counts.get(k));
        }
        return 'Last ' + days + ' days: ' + String.join(countParts, ', ') + '\n' + String.join(lines, '\n');
    }
}