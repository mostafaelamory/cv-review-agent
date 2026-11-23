/**
 * Names and versions of the Prompt Builder templates. The version is stored on
 * every record a template produces and is part of the evaluation cache key, so
 * bump it whenever a template's wording changes.
 */
public with sharing class PromptCatalog {
    public static final String TRANSCRIBE = 'CV_Transcribe';
    public static final String EXTRACT_CARD = 'CV_Extract_Card';
    public static final String ANSWER_QUESTION = 'CV_Answer_Question';
    public static final String ASSESS_REQUIREMENTS = 'CV_Assess_Requirements';
    public static final String RECOMMEND = 'CV_Recommend';

    private static final Map<String, String> VERSIONS = new Map<String, String>{
        TRANSCRIBE => 'v1',
        EXTRACT_CARD => 'v1',
        ANSWER_QUESTION => 'v2',
        ASSESS_REQUIREMENTS => 'v1',
        RECOMMEND => 'v2'
    };

    public static String versionOf(String templateName) {
        return templateName + ':' + (VERSIONS.containsKey(templateName) ? VERSIONS.get(templateName) : 'v0');
    }
}
