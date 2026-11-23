// Deletes candidates, cards, CV documents, evaluations and bookmarks (not files, roles or logs). Development and test orgs only.
delete [SELECT Id FROM Candidate_Bookmark__c];
delete [SELECT Id FROM Candidate__c];
delete [SELECT Id FROM CV_Document__c];
System.debug('RESET done');
