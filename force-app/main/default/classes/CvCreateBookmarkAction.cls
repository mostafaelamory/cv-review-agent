/**
 * Agent action: bookmark an evaluated candidate with optional notes. The agent
 * only offers it after an evaluation and asks the recruiter to confirm first.
 */
public with sharing class CvCreateBookmarkAction {
    public class Request {
        @InvocableVariable(required=true label='Candidate Name' description='Name of the candidate to bookmark.')
        public String candidateName;
        @InvocableVariable(required=true label='Role' description='Job role the candidate was evaluated for.')
        public String roleName;
        @InvocableVariable(label='Notes' description='The recruiter\'s notes, verbatim. Leave empty if they gave none.')
        public String notes;
    }

    public class Response {
        @InvocableVariable(label='Message' description='Confirmation or the reason the bookmark was not created.')
        public String message;
        @InvocableVariable(label='Bookmark Id' description='Id of the bookmark record.')
        public String bookmarkId;
        @InvocableVariable(label='Bookmark Link' description='Link to the bookmark record.')
        public String bookmarkLink;
        @InvocableVariable(label='Already Existed' description='True when this recruiter had already bookmarked this evaluation.')
        public Boolean alreadyExisted;
    }

    @InvocableMethod(
        label='Create Bookmark'
        description='Saves one bookmark record with the candidate overview, score, reasoning, role and the recruiter\'s notes.'
        category='CV Review'
    )
    public static List<Response> create(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request r : requests) {
            Response res = new Response();
            res.alreadyExisted = false;
            try {
                Job_Role__c role = CandidateResolver.resolveRole(r.roleName);
                CandidateResolver.Resolution cand = CandidateResolver.resolve(new List<String>{ r.candidateName });
                if (role == null) {
                    res.message = 'No job role found named "' + r.roleName + '".';
                } else if (cand.needsClarification()) {
                    res.message = cand.clarification();
                } else {
                    BookmarkService.Result b = BookmarkService.create(cand.matched[0].Id, role.Id, r.notes);
                    res.bookmarkId = b.bookmark.Id;
                    res.bookmarkLink = '/lightning/r/Candidate_Bookmark__c/' + b.bookmark.Id + '/view';
                    res.alreadyExisted = b.alreadyExisted;
                    res.message = b.alreadyExisted
                        ? cand.matched[0].Name + ' was already bookmarked for ' + role.Name + '. The existing bookmark was kept unchanged; add later comments as Notes on it.'
                        : 'Bookmarked ' + cand.matched[0].Name + ' for ' + role.Name + ' (score ' + b.bookmark.Score__c + ', ' + b.bookmark.Band__c + ').';
                }
            } catch (Exception e) {
                res.message = e.getMessage();
            }
            out.add(res);
        }
        return out;
    }
}