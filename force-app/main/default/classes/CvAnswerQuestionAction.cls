/**
 * Agent action: answer a recruiter's question from CV evidence only, with
 * verified citations. Returns "Not stated in the CV." when nothing supports
 * an answer.
 */
public with sharing class CvAnswerQuestionAction {
    public class Request {
        @InvocableVariable(required=true label='Question' description='The recruiter\'s question, verbatim.')
        public String question;
        @InvocableVariable(label='Candidate Names' description='Comma-separated names of the candidates the question is about. Leave empty for questions across all candidates.')
        public String candidateNames;
        @InvocableVariable(label='Keywords' description='Comma-separated search terms from the question: skills, technologies, degrees, employers, languages, e.g. "apex, lwc".')
        public String keywords;
        @InvocableVariable(label='Context Record Id' description='Id of the Candidate or Job Role record the recruiter is viewing, if any.')
        public String contextRecordId;
    }

    public class Response {
        @InvocableVariable(label='Answer' description='Verified answer. Each sentence ends with source markers like [1]. Show it as is.')
        public String answer;
        @InvocableVariable(label='Sources' description='Numbered sources for the markers in the answer: candidate, fact, status and quote.')
        public String sources;
        @InvocableVariable(label='Outcome' description='Success, Partial, Ungrounded (nothing in the CVs supports an answer), Refused or Failed.')
        public String outcome;
        @InvocableVariable(label='Needs Clarification' description='True when a candidate name was ambiguous or not found; ask the recruiter which one they meant.')
        public Boolean needsClarification;
        @InvocableVariable(label='Citations' description='Evidence records cited by the answer.')
        public AiCopilot.GenAiCitationOutput citations;
    }

    @InvocableMethod(
        label='Answer Candidate Question'
        description='Answers a question about one or more candidates using only their CV evidence, with verified sources.'
        category='CV Review'
    )
    public static List<Response> answer(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request r : requests) {
            AnswerService.Answer a = AnswerService.ask(
                r.question, r.candidateNames, r.keywords, CandidateResolver.asId(r.contextRecordId)
            );
            Response res = new Response();
            res.answer = a.text;
            res.outcome = a.outcome;
            res.needsClarification = a.needsClarification;
            res.sources = sourcesText(a.sources);
            res.citations = citations(a.sources);
            out.add(res);
        }
        return out;
    }

    private static String sourcesText(List<AnswerService.Source> sources) {
        List<String> lines = new List<String>();
        for (AnswerService.Source s : sources) {
            lines.add(
                '[' + s.index + '] ' + (s.candidateName == null ? '' : s.candidateName + ' - ') + s.label +
                ' (' + s.status + (s.page == null ? '' : ', page ' + s.page) + ')' +
                (s.quote == null ? '' : ': "' + s.quote.left(200).normalizeSpace() + '"')
            );
        }
        return String.join(lines, '\n');
    }

    /** Built through JSON so the shape matches the documented citation contract. */
    @TestVisible
    private static AiCopilot.GenAiCitationOutput citations(List<AnswerService.Source> sources) {
        if (sources.isEmpty()) {
            return null;
        }
        List<Object> refs = new List<Object>();
        for (AnswerService.Source s : sources) {
            refs.add(
                new Map<String, Object>{
                    'metadata' => new List<Object>{
                        new Map<String, Object>{
                            'link' => '/lightning/r/' + s.objectApiName + '/' + s.recordId + '/view',
                            'source_object_record_id' => String.valueOf(s.recordId),
                            'source_object_api_name' => s.objectApiName,
                            'label' => '[' + s.index + '] ' + (s.candidateName == null ? '' : s.candidateName + ': ') + s.label
                        }
                    }
                }
            );
        }
        try {
            return (AiCopilot.GenAiCitationOutput) JSON.deserialize(
                JSON.serialize(new Map<String, Object>{ 'references' => refs }),
                AiCopilot.GenAiCitationOutput.class
            );
        } catch (Exception e) {
            // Citations are a convenience; the sources text carries the same links.
            return null;
        }
    }
}