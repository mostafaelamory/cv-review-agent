/**
 * Deterministic scoring. The model only labels each requirement (Met, Partial,
 * Not evidenced, Contradicted); all arithmetic is here, so scores are
 * reproducible, explainable and testable without a model.
 *
 *   Score = 100 * sum(w * m * c) / sum(w)
 *   m: Met 1.0, Partial 0.5, otherwise 0
 *   c: confidence of the strongest cited evidence: High 1.0, Medium 0.8, Low 0.6
 */
public with sharing class ScoringService {
    public static final String MET = 'Met';
    public static final String PARTIAL = 'Partial';
    public static final String NOT_EVIDENCED = 'Not evidenced';
    public static final String CONTRADICTED = 'Contradicted';

    public static final Map<String, Decimal> MATCH_VALUE = new Map<String, Decimal>{
        MET => 1.0, PARTIAL => 0.5, NOT_EVIDENCED => 0, CONTRADICTED => 0
    };
    public static final Map<String, Decimal> CONFIDENCE_FACTOR = new Map<String, Decimal>{
        'High' => 1.0, 'Medium' => 0.8, 'Low' => 0.6
    };

    /** One requirement's judgement, after validation. */
    public class Assessment {
        public String match = NOT_EVIDENCED;
        public List<Id> evidenceIds = new List<Id>();
        public String rationale;
        public String decidedBy = 'Model';
    }

    /** One row of the explainable breakdown (serialised to Breakdown_JSON__c). */
    public class Line {
        public Id requirementId;
        public String requirement;
        public String type;
        public Decimal weight;
        public String match;
        public String confidence;
        public Decimal confidenceFactor;
        public Decimal pointsPossible;
        public Decimal pointsEarned;
        public Decimal pointsLost;
        public List<Id> evidenceIds;
        public String rationale;
        public String decidedBy;
    }

    public class Score {
        public Decimal total = 0;
        public String band;
        public Integer mustHaveGaps = 0;
        public Integer mustHavesMet = 0;
        public Integer highConfidenceEvidence = 0;
        public Boolean lowData = false;
        public Boolean gated = false;
        public List<Line> lines = new List<Line>();
    }

    public static Score score(
        List<Role_Requirement__c> requirements,
        Map<Id, Assessment> assessments,
        Map<Id, Candidate_Evidence__c> evidence,
        Decimal completeness
    ) {
        Score s = new Score();
        Decimal totalWeight = 0;
        for (Role_Requirement__c r : requirements) {
            totalWeight += weightOf(r);
        }
        Set<Id> highIds = new Set<Id>();
        for (Role_Requirement__c r : requirements) {
            Assessment a = assessments.containsKey(r.Id) ? assessments.get(r.Id) : new Assessment();
            Line l = new Line();
            l.requirementId = r.Id;
            l.requirement = r.Requirement__c;
            l.type = r.Type__c;
            l.weight = weightOf(r);
            l.match = a.match;
            l.evidenceIds = a.evidenceIds;
            l.rationale = a.rationale;
            l.decidedBy = a.decidedBy;
            l.confidence = strongestConfidence(a.evidenceIds, evidence);
            l.confidenceFactor = l.confidence == null ? 0 : CONFIDENCE_FACTOR.get(l.confidence);
            l.pointsPossible = totalWeight == 0 ? 0 : (100 * l.weight / totalWeight).setScale(1);
            l.pointsEarned = totalWeight == 0 ? 0 : (100 * l.weight * MATCH_VALUE.get(l.match) * l.confidenceFactor / totalWeight).setScale(1);
            l.pointsLost = l.pointsPossible - l.pointsEarned;
            s.total += totalWeight == 0 ? 0 : 100 * l.weight * MATCH_VALUE.get(l.match) * l.confidenceFactor / totalWeight;
            s.lines.add(l);

            if (r.Type__c == 'Must-have') {
                if (l.match == NOT_EVIDENCED || l.match == CONTRADICTED) {
                    s.mustHaveGaps++;
                } else if (l.match == MET) {
                    s.mustHavesMet++;
                }
            }
            for (Id evId : a.evidenceIds) {
                if (evidence.containsKey(evId) && evidence.get(evId).Confidence__c == 'High') {
                    highIds.add(evId);
                }
            }
        }
        s.total = s.total.setScale(1);
        s.highConfidenceEvidence = highIds.size();
        s.band = bandOf(s.total);
        if (s.mustHaveGaps > 0 && s.band == 'Strong') {
            s.band = 'Possible';
            s.gated = true;
        }
        s.lowData = completeness != null && completeness < CvAgentSettings.lowDataThreshold();
        return s;
    }

    public static String bandOf(Decimal total) {
        if (total >= CvAgentSettings.strongThreshold()) {
            return 'Strong';
        }
        return total >= CvAgentSettings.possibleThreshold() ? 'Possible' : 'Weak';
    }

    /** Ranking order: score, then must-haves met, then high-confidence evidence. */
    public static Integer compare(Score a, Score b) {
        if (a.total != b.total) {
            return a.total > b.total ? -1 : 1;
        }
        if (a.mustHavesMet != b.mustHavesMet) {
            return a.mustHavesMet > b.mustHavesMet ? -1 : 1;
        }
        if (a.highConfidenceEvidence != b.highConfidenceEvidence) {
            return a.highConfidenceEvidence > b.highConfidenceEvidence ? -1 : 1;
        }
        return 0;
    }

    /** "Why A over B": the requirements where their points differ, largest gap first. */
    public static List<String> explainDifference(String nameA, List<Line> a, String nameB, List<Line> b) {
        Map<Id, Line> byReqB = new Map<Id, Line>();
        for (Line l : b) {
            byReqB.put(l.requirementId, l);
        }
        List<DiffItem> diffs = new List<DiffItem>();
        for (Line la : a) {
            Line lb = byReqB.get(la.requirementId);
            if (lb == null || la.pointsEarned == lb.pointsEarned) {
                continue;
            }
            diffs.add(new DiffItem(la, lb));
        }
        diffs.sort();
        List<String> out = new List<String>();
        for (DiffItem d : diffs) {
            Decimal delta = d.a.pointsEarned - d.b.pointsEarned;
            out.add(
                d.a.requirement + ' (' + d.a.type + '): ' +
                nameA + ' ' + d.a.match + (d.a.confidence == null ? '' : ', ' + d.a.confidence) + ' = ' + d.a.pointsEarned + ' pts; ' +
                nameB + ' ' + d.b.match + (d.b.confidence == null ? '' : ', ' + d.b.confidence) + ' = ' + d.b.pointsEarned + ' pts ' +
                '(' + (delta > 0 ? '+' : '') + delta + ' for ' + nameA + ')'
            );
        }
        return out;
    }

    private class DiffItem implements Comparable {
        Line a;
        Line b;
        DiffItem(Line a, Line b) {
            this.a = a;
            this.b = b;
        }
        public Integer compareTo(Object other) {
            Decimal mine = Math.abs(a.pointsEarned - b.pointsEarned);
            DiffItem o = (DiffItem) other;
            Decimal theirs = Math.abs(o.a.pointsEarned - o.b.pointsEarned);
            return mine == theirs ? 0 : (mine > theirs ? -1 : 1);
        }
    }

    private static Decimal weightOf(Role_Requirement__c r) {
        return r.Weight__c == null || r.Weight__c <= 0 ? 10 : r.Weight__c;
    }

    private static String strongestConfidence(List<Id> ids, Map<Id, Candidate_Evidence__c> evidence) {
        String best;
        for (Id i : ids) {
            Candidate_Evidence__c ev = evidence.get(i);
            if (ev == null || ev.Confidence__c == null) {
                continue;
            }
            if (best == null || CONFIDENCE_FACTOR.get(ev.Confidence__c) > CONFIDENCE_FACTOR.get(best)) {
                best = ev.Confidence__c;
            }
        }
        return best;
    }
}
