// Live smoke test of the agent actions (calls the real model). Commits evaluations.
void ask(String q, String names, String keywords) {
    CvAnswerQuestionAction.Request r = new CvAnswerQuestionAction.Request();
    r.question = q;
    r.candidateNames = names;
    r.keywords = keywords;
    CvAnswerQuestionAction.Response res = CvAnswerQuestionAction.answer(new List<CvAnswerQuestionAction.Request>{ r })[0];
    System.debug('SMOKE Q: ' + q + ' [' + names + ']\nOUTCOME ' + res.outcome + ' clarify=' + res.needsClarification +
        '\nANSWER ' + res.answer + '\nSOURCES ' + res.sources + '\nCITATIONS ' + (res.citations != null));
}
ask('Does Omar have Apex experience?', 'Omar', 'apex');
ask('Does Sara have a Master\'s degree?', 'Sara', 'master');
ask('Who has worked with MuleSoft or integrations?', '', 'mulesoft, integration, rest');
ask('What is Karim\'s salary expectation?', 'Karim', 'salary');
ask('How many years of experience does Youssef have?', 'Youssef', 'experience');

CvEvaluateCandidatesAction.Request e = new CvEvaluateCandidatesAction.Request();
e.roleName = 'Senior Salesforce Developer';
e.candidateNames = 'Omar Khalil, Lina Haddad, Youssef Nasser';
CvEvaluateCandidatesAction.Response er = CvEvaluateCandidatesAction.evaluate(new List<CvEvaluateCandidatesAction.Request>{ e })[0];
System.debug('SMOKE EVAL hasEvaluation=' + er.hasEvaluation + ' top=' + er.topCandidate + '\n' + er.summary);
