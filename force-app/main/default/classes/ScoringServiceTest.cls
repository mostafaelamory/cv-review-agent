@IsTest
private class ScoringServiceTest {
    static Role_Requirement__c req(String name, String type, Decimal weight) {
        return new Role_Requirement__c(
            Id = fflibId(Role_Requirement__c.SObjectType),
            Requirement__c = name,
            Type__c = type,
            Weight__c = weight
        );
    }

    static Integer counter = 1;
    static Id fflibId(Schema.SObjectType t) {
        String n = String.valueOf(counter++);
        return Id.valueOf(t.getDescribe().getKeyPrefix() + '0'.repeat(12 - n.length()) + n);
    }

    static ScoringService.Assessment a(String match, List<Id> ids) {
        ScoringService.Assessment x = new ScoringService.Assessment();
        x.match = match;
        x.evidenceIds = ids;
        return x;
    }

    @IsTest
    static void computesWeightedScoreWithConfidence() {
        Role_Requirement__c apex = req('Apex', 'Must-have', 50);
        Role_Requirement__c lwc = req('LWC', 'Must-have', 30);
        Role_Requirement__c degree = req('Degree', 'Nice-to-have', 20);
        Candidate_Evidence__c high = new Candidate_Evidence__c(Id = fflibId(Candidate_Evidence__c.SObjectType), Confidence__c = 'High');
        Candidate_Evidence__c medium = new Candidate_Evidence__c(Id = fflibId(Candidate_Evidence__c.SObjectType), Confidence__c = 'Medium');
        Map<Id, Candidate_Evidence__c> evidence = new Map<Id, Candidate_Evidence__c>{ high.Id => high, medium.Id => medium };
        Map<Id, ScoringService.Assessment> assessments = new Map<Id, ScoringService.Assessment>{
            apex.Id => a(ScoringService.MET, new List<Id>{ high.Id, medium.Id }),
            lwc.Id => a(ScoringService.PARTIAL, new List<Id>{ medium.Id }),
            degree.Id => a(ScoringService.NOT_EVIDENCED, new List<Id>())
        };
        ScoringService.Score s = ScoringService.score(new List<Role_Requirement__c>{ apex, lwc, degree }, assessments, evidence, 90);
        // 100 * (50*1*1 + 30*0.5*0.8 + 0) / 100 = 62
        Assert.areEqual(62.0, s.total);
        Assert.areEqual('Possible', s.band);
        Assert.areEqual(0, s.mustHaveGaps);
        Assert.areEqual(1, s.mustHavesMet);
        Assert.areEqual(1, s.highConfidenceEvidence);
        Assert.areEqual('High', s.lines[0].confidence, 'Strongest cited evidence counts');
        Assert.areEqual(50.0, s.lines[0].pointsEarned);
        Assert.areEqual(18.0, s.lines[1].pointsLost);
        Assert.isFalse(s.lowData);
    }

    @IsTest
    static void mustHaveGapCapsStrongAtPossible() {
        Role_Requirement__c big = req('Apex', 'Nice-to-have', 90);
        Role_Requirement__c must = req('LWC', 'Must-have', 10);
        Candidate_Evidence__c high = new Candidate_Evidence__c(Id = fflibId(Candidate_Evidence__c.SObjectType), Confidence__c = 'High');
        ScoringService.Score s = ScoringService.score(
            new List<Role_Requirement__c>{ big, must },
            new Map<Id, ScoringService.Assessment>{ big.Id => a(ScoringService.MET, new List<Id>{ high.Id }) },
            new Map<Id, Candidate_Evidence__c>{ high.Id => high },
            30
        );
        Assert.areEqual(90.0, s.total);
        Assert.areEqual('Possible', s.band, 'Capped by the must-have gap');
        Assert.isTrue(s.gated);
        Assert.isTrue(s.lowData);
        Assert.areEqual('Weak', ScoringService.bandOf(40));
        Assert.areEqual('Strong', ScoringService.bandOf(80));
    }

    @IsTest
    static void ranksAndExplainsDifferences() {
        ScoringService.Score a = new ScoringService.Score();
        a.total = 70;
        a.mustHavesMet = 2;
        ScoringService.Score b = new ScoringService.Score();
        b.total = 70;
        b.mustHavesMet = 1;
        Assert.areEqual(-1, ScoringService.compare(a, b), 'Tie broken by must-haves met');
        b.mustHavesMet = 2;
        b.highConfidenceEvidence = 3;
        Assert.areEqual(1, ScoringService.compare(a, b), 'Then by high-confidence evidence');

        Id reqId = fflibId(Role_Requirement__c.SObjectType);
        Id reqId2 = fflibId(Role_Requirement__c.SObjectType);
        ScoringService.Line la = line(reqId, 'Apex', 'Met', 40);
        ScoringService.Line lb = line(reqId, 'Apex', 'Partial', 16);
        ScoringService.Line la2 = line(reqId2, 'LWC', 'Met', 30);
        ScoringService.Line lb2 = line(reqId2, 'LWC', 'Met', 30);
        List<String> diff = ScoringService.explainDifference(
            'Sara', new List<ScoringService.Line>{ la, la2 }, 'Omar', new List<ScoringService.Line>{ lb, lb2 }
        );
        Assert.areEqual(1, diff.size(), 'Only requirements whose points differ');
        Assert.isTrue(diff[0].contains('+24'));
    }

    static ScoringService.Line line(Id reqId, String name, String match, Decimal earned) {
        ScoringService.Line l = new ScoringService.Line();
        l.requirementId = reqId;
        l.requirement = name;
        l.type = 'Must-have';
        l.match = match;
        l.pointsEarned = earned;
        return l;
    }
}
