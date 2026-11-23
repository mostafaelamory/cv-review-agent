/**
 * Turns the CV_Extract_Card JSON into a Candidate Card: one Candidate__c header
 * plus Candidate_Evidence__c rows, the stored CV text, and derived facts.
 *
 * Deterministic guards applied here, never left to the model:
 *  - every quote is checked against the stored text (Quote_Verified__c);
 *  - confidence comes from rules, not from the model;
 *  - tenure is computed from dates, overlaps counted once;
 *  - missing attributes become Missing rows, so gaps are visible and queryable;
 *  - disagreements become Conflicting rows that share a Conflict_Group__c.
 */
public with sharing class CandidateCardBuilder {
    public static final Set<String> CATEGORIES = new Set<String>{
        'Contact', 'Skill', 'Experience', 'Education', 'Certification', 'Achievement', 'Language'
    };
    private static final Integer MAX_EVIDENCE = 150;
    private static final Integer CLAIM_TOLERANCE_MONTHS = 18;
    private static final Integer OVERLAP_FLAG_MONTHS = 3;

    public class Result {
        public Id candidateId;
        public String cardStatus;
        public Decimal completeness;
        public Integer evidenceCount = 0;
        public Integer statedCount = 0;
        public Integer verifiedCount = 0;
        public Integer conflictCount = 0;
        public List<String> missing = new List<String>();
        public List<String> reviewReasons = new List<String>();
    }

    /** One parsed evidence row plus the information needed to link it to text. */
    private class Row {
        Candidate_Evidence__c ev;
        Integer chunkSeq;
        Boolean isRole = false;
        Row(Candidate_Evidence__c ev) {
            this.ev = ev;
        }
    }

    private CV_Document__c doc;
    private ExtractedText text;
    private List<Row> rows = new List<Row>();
    private List<String> normalizedChunks = new List<String>();
    private List<String> alnumChunks = new List<String>();
    private Result result = new Result();

    public CandidateCardBuilder(CV_Document__c doc, ExtractedText text) {
        this.doc = doc;
        this.text = text;
        for (ExtractedText.Chunk c : text.chunks) {
            normalizedChunks.add(TextNormalizer.loose(c.text));
            alnumChunks.add(TextNormalizer.alnum(c.text));
        }
    }

    /** Validates the model JSON and builds the card in memory. No DML. */
    public CandidateCardBuilder parse(Map<String, Object> card) {
        List<Object> items = JsonUtil.arr(card, 'evidence');
        if (items.isEmpty() && JsonUtil.obj(card.get('profile')).isEmpty()) {
            throw new CvAgentException('The extraction returned no profile and no evidence')
                .withCode(CvAgentException.INVALID_JSON);
        }
        for (Object o : items) {
            if (rows.size() >= MAX_EVIDENCE) {
                break;
            }
            Row r = toRow(JsonUtil.obj(o));
            if (r != null) {
                rows.add(r);
            }
        }
        addProfileFallbacks(JsonUtil.obj(card.get('profile')));
        applyModelConflictGroups();
        addExperienceFacts();
        addMissingRows();
        for (Row r : rows) {
            r.ev.Confidence__c = confidenceOf(r.ev);
        }
        return this;
    }

    private Row toRow(Map<String, Object> m) {
        String category = normalizeCategory(JsonUtil.str(m, 'category'));
        String value = JsonUtil.str(m, 'value');
        String attribute = JsonUtil.str(m, 'attribute');
        if (category == null || (value == null && attribute == null)) {
            return null;
        }
        String status = JsonUtil.str(m, 'status');
        status = status != null && status.equalsIgnoreCase('Inferred') ? 'Inferred' : 'Stated';

        Candidate_Evidence__c ev = new Candidate_Evidence__c(
            Category__c = category,
            Attribute__c = JsonUtil.truncate(attribute == null ? category : attribute, 255),
            Value__c = JsonUtil.truncate(value, 255),
            Organization__c = JsonUtil.truncate(JsonUtil.str(m, 'organization'), 255),
            Detail__c = JsonUtil.truncate(JsonUtil.str(m, 'detail'), 5000),
            Status__c = status,
            Source_Quote__c = JsonUtil.truncate(JsonUtil.str(m, 'quote'), 2000),
            Conflict_Group__c = JsonUtil.truncate(JsonUtil.str(m, 'conflict_group'), 80),
            Inference_Reason__c = JsonUtil.truncate(JsonUtil.str(m, 'inference_reason'), 255),
            Quote_Verified__c = false
        );
        if (status == 'Inferred' && ev.Inference_Reason__c == null) {
            ev.Inference_Reason__c = 'Inferred by the extraction model; not written in the CV';
        }
        Row r = new Row(ev);
        r.isRole = category == 'Experience' && (ev.Organization__c != null || JsonUtil.str(m, 'start') != null);

        DateUtil.Parsed s = DateUtil.parse(JsonUtil.str(m, 'start'), false);
        DateUtil.Parsed e = DateUtil.parse(JsonUtil.str(m, 'end'), true);
        Boolean current = m.get('is_current') == true || (e != null && e.isCurrent);
        if (s != null) {
            ev.Start_Date__c = s.value;
            ev.Date_Precision__c = s.precision;
        }
        if (e != null) {
            ev.End_Date__c = e.value;
            if (ev.Date_Precision__c == null || e.precision == 'Year') {
                ev.Date_Precision__c = e.isCurrent ? ev.Date_Precision__c : e.precision;
            }
        }
        ev.Is_Current__c = current;
        if (current && ev.End_Date__c == null) {
            ev.End_Date__c = Date.today();
        }
        if (ev.Start_Date__c != null && ev.End_Date__c != null && ev.End_Date__c < ev.Start_Date__c) {
            ev.Detail__c = appendNote(ev.Detail__c, 'End date is before start date in the CV.');
            ev.Status__c = 'Inferred';
            ev.Inference_Reason__c = 'Dates are inconsistent: end before start';
            ev.End_Date__c = null;
        }
        verifyQuote(r);
        return r;
    }

    /** Finds the quote in the stored text: loose match first, then letters and digits only. */
    private void verifyQuote(Row r) {
        String quote = r.ev.Source_Quote__c;
        if (String.isBlank(quote)) {
            return;
        }
        String loose = TextNormalizer.loose(quote);
        String strict = TextNormalizer.alnum(quote);
        for (Integer i = 0; i < normalizedChunks.size(); i++) {
            if (normalizedChunks[i].contains(loose) || (strict.length() >= 4 && alnumChunks[i].contains(strict))) {
                r.ev.Quote_Verified__c = true;
                r.chunkSeq = text.chunks[i].sequence;
                r.ev.Source_Page__c = text.chunks[i].page;
                return;
            }
        }
    }

    /** Contact facts the model put only in "profile" still become evidence rows. */
    private void addProfileFallbacks(Map<String, Object> profile) {
        Map<String, String> attrs = new Map<String, String>{
            'full_name' => 'Full name',
            'email' => 'Email',
            'phone' => 'Phone',
            'location' => 'Location',
            'headline' => 'Headline'
        };
        for (String key : attrs.keySet()) {
            String v = JsonUtil.str(profile, key);
            if (v == null || findContact(attrs.get(key)) != null) {
                continue;
            }
            Row r = new Row(
                new Candidate_Evidence__c(
                    Category__c = 'Contact',
                    Attribute__c = attrs.get(key),
                    Value__c = JsonUtil.truncate(v, 255),
                    Status__c = 'Stated',
                    Source_Quote__c = v,
                    Quote_Verified__c = false
                )
            );
            verifyQuote(r);
            rows.add(r);
        }
    }

    /** A model conflict group only counts when at least two rows share it. */
    private void applyModelConflictGroups() {
        Map<String, Integer> counts = new Map<String, Integer>();
        for (Row r : rows) {
            String g = r.ev.Conflict_Group__c;
            if (g != null) {
                counts.put(g, (counts.containsKey(g) ? counts.get(g) : 0) + 1);
            }
        }
        for (Row r : rows) {
            String g = r.ev.Conflict_Group__c;
            if (g == null) {
                continue;
            }
            if (counts.get(g) >= 2) {
                r.ev.Status__c = 'Conflicting';
            } else {
                r.ev.Conflict_Group__c = null;
            }
        }
    }

    /** Total tenure, overlapping roles, and a claimed-versus-dated conflict. */
    private void addExperienceFacts() {
        List<Row> dated = new List<Row>();
        Boolean anyYearOnly = false;
        for (Row r : rows) {
            if (r.isRole && r.ev.Start_Date__c != null && r.ev.End_Date__c != null) {
                dated.add(r);
                anyYearOnly = anyYearOnly || r.ev.Date_Precision__c == 'Year';
            }
        }
        if (dated.isEmpty()) {
            return;
        }
        List<List<Date>> ranges = new List<List<Date>>();
        for (Row r : dated) {
            ranges.add(new List<Date>{ r.ev.Start_Date__c, r.ev.End_Date__c });
        }
        Integer months = DateUtil.mergedMonths(ranges);
        totalMonths = months;

        Candidate_Evidence__c total = new Candidate_Evidence__c(
            Category__c = 'Experience',
            Attribute__c = 'Total experience',
            Value__c = DateUtil.formatMonths(months),
            Status__c = 'Inferred',
            Inference_Reason__c = JsonUtil.truncate(
                'Merged ' + dated.size() + ' dated role(s); overlapping periods counted once.' +
                (anyYearOnly ? ' Some dates give only the year.' : ''),
                255
            ),
            Quote_Verified__c = false
        );
        Row totalRow = new Row(total);
        rows.add(totalRow);

        // Overlaps between roles are worth a look: part-time, contract, or an error.
        for (Integer i = 0; i < dated.size(); i++) {
            for (Integer j = i + 1; j < dated.size(); j++) {
                Candidate_Evidence__c a = dated[i].ev;
                Candidate_Evidence__c b = dated[j].ev;
                Integer overlap = DateUtil.overlapMonths(a.Start_Date__c, a.End_Date__c, b.Start_Date__c, b.End_Date__c);
                if (overlap > OVERLAP_FLAG_MONTHS) {
                    rows.add(
                        new Row(
                            new Candidate_Evidence__c(
                                Category__c = 'Experience',
                                Attribute__c = 'Overlapping roles',
                                Value__c = JsonUtil.truncate(roleLabel(a) + ' and ' + roleLabel(b) + ' overlap by ' + DateUtil.formatMonths(overlap), 255),
                                Status__c = 'Inferred',
                                Inference_Reason__c = 'Dated roles overlap; may be part-time or contract work, or a date error. Confirm at interview.',
                                Quote_Verified__c = false
                            )
                        )
                    );
                }
            }
        }

        // "8 years of experience" in the summary versus what the dated roles add up to.
        for (Row r : rows) {
            if (r.ev.Category__c != 'Experience' || r === totalRow || r.ev.Attribute__c == null) {
                continue;
            }
            String attr = r.ev.Attribute__c.toLowerCase();
            if (!(attr.contains('years') && (attr.contains('experience') || attr.contains('claimed')))) {
                continue;
            }
            Decimal claimedYears = firstNumber(r.ev.Value__c);
            if (claimedYears == null) {
                continue;
            }
            Integer diff = Math.abs((claimedYears * 12).intValue() - months);
            if (diff >= CLAIM_TOLERANCE_MONTHS) {
                String g = 'experience-total';
                r.ev.Status__c = 'Conflicting';
                r.ev.Conflict_Group__c = g;
                total.Status__c = 'Conflicting';
                total.Conflict_Group__c = g;
                total.Detail__c = 'The CV states ' + r.ev.Value__c + ', but the dated roles add up to ' + total.Value__c + '.';
            }
        }
    }

    private Integer totalMonths;

    /** Expected attributes that were not found become Missing rows. */
    private void addMissingRows() {
        Integer expected = 0;
        Integer found = 0;
        for (String attr : new List<String>{ 'Full name', 'Email', 'Phone', 'Location' }) {
            expected++;
            if (findContact(attr) != null) {
                found++;
            } else {
                rows.add(missing('Contact', attr, 'No ' + attr.toLowerCase() + ' found in the CV.'));
            }
        }
        Map<String, String> sections = new Map<String, String>{
            'Skill' => 'Skills',
            'Experience' => 'Work experience',
            'Education' => 'Education'
        };
        for (String category : sections.keySet()) {
            expected++;
            if (hasCategory(category)) {
                found++;
            } else {
                rows.add(missing(category, sections.get(category), 'No ' + sections.get(category).toLowerCase() + ' section or entries found.'));
            }
        }
        // Every role should have dates; missing ones block tenure maths.
        expected++;
        Boolean allDated = true;
        List<Row> roles = new List<Row>();
        for (Row r : rows) {
            if (r.isRole) {
                roles.add(r);
            }
        }
        for (Row r : roles) {
            if (r.ev.Start_Date__c == null) {
                allDated = false;
                rows.add(missing('Experience', 'Start date', 'No start date for ' + roleLabel(r.ev) + '.', r.ev.Organization__c));
            }
            if (r.ev.End_Date__c == null && r.ev.Is_Current__c != true) {
                allDated = false;
                rows.add(missing('Experience', 'End date', 'No end date for ' + roleLabel(r.ev) + ', and it is not marked current.', r.ev.Organization__c));
            }
        }
        if (allDated && !roles.isEmpty()) {
            found++;
        }
        result.completeness = expected == 0 ? 0 : (Decimal.valueOf(found) * 100 / expected).setScale(0);
    }

    private Row missing(String category, String attribute, String detail) {
        return missing(category, attribute, detail, null);
    }

    private Row missing(String category, String attribute, String detail, String org) {
        return new Row(
            new Candidate_Evidence__c(
                Category__c = category,
                Attribute__c = attribute,
                Organization__c = org,
                Status__c = 'Missing',
                Detail__c = detail,
                Quote_Verified__c = false
            )
        );
    }

    /** Rule-based confidence. */
    public static String confidenceOf(Candidate_Evidence__c ev) {
        if (ev.Recruiter_Verified__c == true) {
            return 'High';
        }
        switch on ev.Status__c {
            when 'Missing' {
                return null;
            }
            when 'Conflicting' {
                return 'Low';
            }
            when 'Inferred' {
                return String.isNotBlank(ev.Source_Quote__c) && ev.Quote_Verified__c != true ? 'Low' : 'Medium';
            }
            when else {
                if (ev.Quote_Verified__c != true) {
                    return 'Low';
                }
                return ev.Date_Precision__c == 'Year' ? 'Medium' : 'High';
            }
        }
    }

    /** Writes candidate, text chunks and evidence in one transaction. */
    public Result save() {
        Savepoint sp = Database.setSavepoint();
        try {
            Candidate__c c = buildHeader();
            insert as user c;
            result.candidateId = c.Id;

            List<CV_Text_Chunk__c> chunkRows = new List<CV_Text_Chunk__c>();
            for (ExtractedText.Chunk ch : text.chunks) {
                chunkRows.add(
                    new CV_Text_Chunk__c(
                        CV_Document__c = doc.Id,
                        Sequence__c = ch.sequence,
                        Page__c = ch.page,
                        Text__c = JsonUtil.truncate(ch.text, 131072)
                    )
                );
            }
            insert as user chunkRows;
            Map<Integer, Id> chunkIdBySeq = new Map<Integer, Id>();
            for (CV_Text_Chunk__c ch : chunkRows) {
                chunkIdBySeq.put(ch.Sequence__c.intValue(), ch.Id);
            }

            List<Candidate_Evidence__c> evidence = new List<Candidate_Evidence__c>();
            for (Row r : rows) {
                r.ev.Candidate__c = c.Id;
                r.ev.CV_Document__c = doc.Id;
                if (r.chunkSeq != null) {
                    r.ev.Source_Chunk__c = chunkIdBySeq.get(r.chunkSeq);
                }
                evidence.add(r.ev);
            }
            insert as user evidence;

            update as user new CV_Document__c(
                Id = doc.Id,
                Candidate__c = c.Id,
                Status__c = result.cardStatus == 'Ready' ? 'Extracted' : 'Needs Review',
                Failure_Reason__c = result.reviewReasons.isEmpty() ? null : JsonUtil.truncate(String.join(result.reviewReasons, '; '), 255),
                Extraction_Method__c = text.method,
                Prompt_Version__c = PromptCatalog.versionOf(PromptCatalog.EXTRACT_CARD),
                Processed_At__c = System.now()
            );
            linkFile(c.Id);
            return result;
        } catch (Exception e) {
            Database.rollback(sp);
            throw e;
        }
    }

    private Candidate__c buildHeader() {
        Candidate_Evidence__c name = findContact('Full name');
        Candidate_Evidence__c email = findContact('Email');
        Candidate_Evidence__c phone = findContact('Phone');
        Candidate_Evidence__c location = findContact('Location');
        Candidate_Evidence__c headline = findContact('Headline');

        for (Row r : rows) {
            result.evidenceCount++;
            if (r.ev.Status__c == 'Stated') {
                result.statedCount++;
                if (r.ev.Quote_Verified__c) {
                    result.verifiedCount++;
                }
            }
            if (r.ev.Status__c == 'Conflicting') {
                result.conflictCount++;
            }
            if (r.ev.Status__c == 'Missing') {
                result.missing.add(r.ev.Attribute__c);
            }
        }

        if (text.quality != 'Good') {
            result.reviewReasons.add('Transcript quality: ' + text.quality);
        }
        if (!text.complete) {
            result.reviewReasons.add('Transcript may be incomplete');
        }
        if (result.completeness < CvAgentSettings.lowDataThreshold()) {
            result.reviewReasons.add('Card is ' + result.completeness + '% complete');
        }
        if (result.statedCount > 0 && Decimal.valueOf(result.verifiedCount) / result.statedCount < 0.7) {
            result.reviewReasons.add(result.statedCount - result.verifiedCount + ' quote(s) not found in the CV text');
        }
        result.cardStatus = result.reviewReasons.isEmpty() ? 'Ready' : 'Needs Review';

        String fullName = name != null ? name.Value__c : null;
        String fallbackName = (doc.File_Name__c == null ? 'Unnamed CV' : doc.File_Name__c.substringBeforeLast('.')) + ' (name not found)';
        Candidate__c c = new Candidate__c(
            Name = JsonUtil.truncate(fullName != null ? fullName : fallbackName, 80),
            Full_Name__c = fullName,
            Email__c = email != null && isEmail(email.Value__c) ? email.Value__c : null,
            Phone__c = phone != null ? JsonUtil.truncate(phone.Value__c, 40) : null,
            Location__c = location != null ? location.Value__c : null,
            Headline__c = headline != null ? headline.Value__c : latestRoleTitle(),
            Total_Experience_Months__c = totalMonths,
            Card_Completeness__c = result.completeness,
            Has_Conflicts__c = result.conflictCount > 0,
            Card_Status__c = result.cardStatus,
            Summary__c = JsonUtil.truncate(summary(), 5000)
        );
        if (c.Email__c != null) {
            List<Candidate__c> dupes = [
                SELECT Id
                FROM Candidate__c
                WHERE Email__c = :c.Email__c
                WITH USER_MODE
                ORDER BY CreatedDate
                LIMIT 1
            ];
            if (!dupes.isEmpty()) {
                c.Possible_Duplicate_Of__c = dupes[0].Id;
            }
        }
        return c;
    }

    /** Deterministic overview from verified facts; no model call. */
    private String summary() {
        List<String> parts = new List<String>();
        String title = latestRoleTitle();
        if (title != null) {
            parts.add('Latest role: ' + title + '.');
        }
        if (totalMonths != null) {
            parts.add('Experience (inferred from dates): ' + DateUtil.formatMonths(totalMonths) + '.');
        }
        List<String> skills = new List<String>();
        List<String> education = new List<String>();
        for (Row r : rows) {
            if (r.ev.Status__c == 'Missing' || r.ev.Value__c == null) {
                continue;
            }
            if (r.ev.Category__c == 'Skill' && skills.size() < 10 && !skills.contains(r.ev.Value__c)) {
                skills.add(r.ev.Value__c);
            } else if (r.ev.Category__c == 'Education' && education.size() < 2) {
                education.add(r.ev.Value__c + (r.ev.Organization__c != null ? ', ' + r.ev.Organization__c : ''));
            }
        }
        if (!skills.isEmpty()) {
            parts.add('Skills: ' + String.join(skills, ', ') + '.');
        }
        if (!education.isEmpty()) {
            parts.add('Education: ' + String.join(education, '; ') + '.');
        }
        return String.join(parts, ' ');
    }

    private String latestRoleTitle() {
        Candidate_Evidence__c latest;
        for (Row r : rows) {
            if (r.isRole && r.ev.Value__c != null) {
                if (latest == null || r.ev.Is_Current__c == true ||
                    (latest.Is_Current__c != true && r.ev.Start_Date__c != null &&
                     (latest.Start_Date__c == null || r.ev.Start_Date__c > latest.Start_Date__c))) {
                    latest = r.ev;
                }
            }
        }
        return latest == null ? null : roleLabel(latest);
    }

    private void linkFile(Id candidateId) {
        if (doc.Content_Document_Id__c == null) {
            return;
        }
        try {
            insert as user new ContentDocumentLink(
                ContentDocumentId = doc.Content_Document_Id__c,
                LinkedEntityId = candidateId,
                ShareType = 'V'
            );
        } catch (Exception e) {
            // Non-fatal: the card still links to the file through its CV document.
            System.debug(LoggingLevel.WARN, 'Could not link file to candidate: ' + e.getMessage());
        }
    }

    private Candidate_Evidence__c findContact(String attribute) {
        for (Row r : rows) {
            if (r.ev.Category__c == 'Contact' && r.ev.Status__c != 'Missing' && r.ev.Value__c != null &&
                r.ev.Attribute__c != null && r.ev.Attribute__c.equalsIgnoreCase(attribute)) {
                return r.ev;
            }
        }
        return null;
    }

    private Boolean hasCategory(String category) {
        for (Row r : rows) {
            if (r.ev.Category__c == category && r.ev.Status__c != 'Missing') {
                return true;
            }
        }
        return false;
    }

    private static String normalizeCategory(String raw) {
        if (raw == null) {
            return null;
        }
        String c = raw.trim().toLowerCase().capitalize().removeEnd('s');
        if (c == 'Certificate' || c == 'Certification') {
            return 'Certification';
        }
        if (c == 'Work' || c == 'Role' || c == 'Employment') {
            return 'Experience';
        }
        return CATEGORIES.contains(c) ? c : null;
    }

    private static String roleLabel(Candidate_Evidence__c ev) {
        String v = ev.Value__c == null ? 'Role' : ev.Value__c;
        return ev.Organization__c == null ? v : v + ' at ' + ev.Organization__c;
    }

    private static Decimal firstNumber(String s) {
        Matcher m = Pattern.compile('(\\d+(?:\\.\\d+)?)').matcher(s == null ? '' : s);
        return m.find() ? Decimal.valueOf(m.group(1)) : null;
    }

    private static Boolean isEmail(String s) {
        return s != null && Pattern.matches('[^@\\s]+@[^@\\s]+\\.[^@\\s]+', s);
    }

    private static String appendNote(String existing, String note) {
        return JsonUtil.truncate(String.isBlank(existing) ? note : existing + ' ' + note, 5000);
    }
}
