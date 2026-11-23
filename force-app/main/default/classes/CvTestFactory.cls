/** Test data for the CV Review Agent. Tests run as a recruiter with only the CV Recruiter permission set. */
@IsTest
public class CvTestFactory {
    public static User recruiter() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String key = String.valueOf(Crypto.getRandomInteger()).remove('-');
        User u = new User(
            Alias = 'rec' + key.left(4),
            Email = 'recruiter' + key + '@example.com',
            Username = 'recruiter' + key + '@cv-agent.test',
            LastName = 'Recruiter',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Europe/London',
            LocaleSidKey = 'en_GB',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        // Setup objects in their own runAs block avoid MIXED_DML_OPERATION with test data.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
            insert new PermissionSetAssignment(
                AssigneeId = u.Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'CV_Recruiter'].Id
            );
        }
        return u;
    }

    public static Job_Role__c role() {
        Job_Role__c r = new Job_Role__c(Name = 'Senior Salesforce Developer', Status__c = 'Open');
        insert r;
        insert new List<Role_Requirement__c>{
            new Role_Requirement__c(Job_Role__c = r.Id, Requirement__c = 'Apex development', Type__c = 'Must-have', Category__c = 'Skill', Weight__c = 40, Keywords__c = 'apex'),
            new Role_Requirement__c(Job_Role__c = r.Id, Requirement__c = 'Lightning Web Components', Type__c = 'Must-have', Category__c = 'Skill', Weight__c = 30),
            new Role_Requirement__c(Job_Role__c = r.Id, Requirement__c = '3+ years of Salesforce development', Type__c = 'Must-have', Category__c = 'Experience', Weight__c = 20, Min_Years__c = 3, Keywords__c = 'salesforce'),
            new Role_Requirement__c(Job_Role__c = r.Id, Requirement__c = 'Computer Science degree', Type__c = 'Nice-to-have', Category__c = 'Education', Weight__c = 10)
        };
        return r;
    }

    /** CV text used by cardJson(); quotes in the JSON are copied from it. */
    public static String cvText(String name, String email, Boolean withLwc) {
        return name + '\nSalesforce Developer | Cairo | ' + email + ' | +20 100 555 0101\n' +
            'Summary: Developer with 8 years of experience.\n' +
            'Salesforce Developer, Acme Corp | 2019-03 - Present\n' +
            '- Built Apex services' + (withLwc ? ' and LWC components' : '') + '.\n' +
            'Developer, Beta Ltd | 2016 - 2019\n' +
            'BSc Computer Science, Cairo University, 2015\n' +
            'Skills: Apex, SOQL' + (withLwc ? ', LWC' : '');
    }

    public static String cardJson(String name, String email, Boolean withLwc) {
        List<Object> ev = new List<Object>{
            row('Contact', 'Full name', name, name, null, null),
            row('Contact', 'Email', email, email, null, null),
            row('Contact', 'Location', 'Cairo', 'Cairo', null, null),
            row('Experience', 'Role', 'Salesforce Developer', 'Salesforce Developer, Acme Corp | 2019-03 - Present', '2019-03', 'present'),
            row('Experience', 'Role', 'Developer', 'Developer, Beta Ltd | 2016 - 2019', '2016', '2019'),
            row('Experience', 'Years of experience (claimed)', '8 years', 'Developer with 8 years of experience.', null, null),
            row('Education', 'Degree', 'BSc Computer Science', 'BSc Computer Science, Cairo University, 2015', null, null),
            row('Skill', 'Skill', 'Apex', 'Built Apex services', null, null),
            row('Skill', 'Skill', 'SOQL', 'SOQL', null, null),
            // Not in the CV text: must come out Unverified / Low.
            row('Skill', 'Skill', 'Kubernetes', 'Kubernetes clusters at scale', null, null)
        };
        ((Map<String, Object>) ev[3]).put('organization', 'Acme Corp');
        ((Map<String, Object>) ev[4]).put('organization', 'Beta Ltd');
        ((Map<String, Object>) ev[6]).put('organization', 'Cairo University');
        if (withLwc) {
            ev.add(row('Skill', 'Skill', 'LWC', 'LWC components', null, null));
        }
        return JSON.serialize(new Map<String, Object>{ 'profile' => new Map<String, Object>{ 'full_name' => name }, 'evidence' => ev });
    }

    public static Map<String, Object> row(String category, String attribute, String value, String quote, String startDate, String endDate) {
        return new Map<String, Object>{
            'category' => category,
            'attribute' => attribute,
            'value' => value,
            'quote' => quote,
            'status' => 'Stated',
            'start' => startDate,
            'end' => endDate
        };
    }

    /** Builds a full card through CandidateCardBuilder, as the ingestion job does. */
    public static Id candidate(String name, String email, Boolean withLwc) {
        CV_Document__c doc = new CV_Document__c(File_Name__c = name + '.docx', File_Type__c = 'DOCX', Status__c = 'Queued');
        insert doc;
        ExtractedText text = new ExtractedText();
        text.method = 'DOCX Parser';
        text.chunks.add(new ExtractedText.Chunk(1, null, cvText(name, email, withLwc)));
        CandidateCardBuilder.Result r = new CandidateCardBuilder(doc, text)
            .parse(JsonUtil.parseObject(cardJson(name, email, withLwc)))
            .save();
        return r.candidateId;
    }

    /** A minimal DOCX package built with ZipWriter. */
    public static Blob docx(List<String> paragraphs) {
        String body = '';
        for (String p : paragraphs) {
            body += '<w:p><w:r><w:t xml:space="preserve">' + p.escapeXml() + '</w:t></w:r></w:p>';
        }
        String xml = '<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' +
            body + '</w:body></w:document>';
        Compression.ZipWriter w = new Compression.ZipWriter();
        w.addEntry('[Content_Types].xml', Blob.valueOf('<Types/>'));
        w.addEntry('word/document.xml', Blob.valueOf(xml));
        w.addEntry('word/header1.xml', Blob.valueOf('<w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:r><w:t>CONFIDENTIAL CV</w:t></w:r></w:p></w:hdr>'));
        return w.getArchive();
    }

    public static Id uploadFile(String fileName, Blob data) {
        ContentVersion cv = new ContentVersion(Title = fileName.substringBeforeLast('.'), PathOnClient = fileName, VersionData = data);
        insert cv;
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
    }
}
