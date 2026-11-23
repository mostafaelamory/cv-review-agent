import { createElement } from 'lwc';
import EvaluationBreakdown, { toRows, bullets } from 'c/evaluationBreakdown';
import { getRecord } from 'lightning/uiRecordApi';

const BREAKDOWN = JSON.stringify([
    { requirementId: 'r1', requirement: 'Apex', type: 'Must-have', match: 'Met', confidence: 'High', pointsEarned: 40, pointsPossible: 40, evidenceIds: ['e1'], rationale: 'Built Apex services' },
    { requirementId: 'r2', requirement: '3+ years', type: 'Must-have', match: 'Partial', pointsEarned: 8, pointsPossible: 20, evidenceIds: [], decidedBy: 'Apex date maths' }
]);

function record(fields) {
    const out = { apiName: 'Candidate_Evaluation__c', fields: {} };
    Object.entries(fields).forEach(([k, v]) => {
        out.fields[k] = { value: v, displayValue: null };
    });
    return out;
}

describe('c-evaluation-breakdown', () => {
    afterEach(() => {
        while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
    });

    it('parses the breakdown and bullets safely', () => {
        const rows = toRows(BREAKDOWN);
        expect(rows[0].barStyle).toBe('width:100%');
        expect(rows[1].barStyle).toBe('width:40%');
        expect(rows[1].decidedBy).toBe('Decided by date maths');
        expect(toRows('not json')).toEqual([]);
        expect(bullets('• Apex\n• LWC\n')).toEqual(['Apex', 'LWC']);
    });

    it('renders the score, band, requirement lines and reasoning', async () => {
        const el = createElement('c-evaluation-breakdown', { is: EvaluationBreakdown });
        el.recordId = 'a0E000000000001AAA';
        el.objectApiName = 'Candidate_Evaluation__c';
        document.body.appendChild(el);
        getRecord.emit(
            record({
                Total_Score__c: 64.4,
                Band__c: 'Possible',
                Must_Have_Gaps__c: 1,
                Low_Data__c: false,
                Breakdown_JSON__c: BREAKDOWN,
                Strengths__c: '• Strong Apex',
                Concerns__c: '• No integrations',
                Interview_Probes__c: '• Ask about REST',
                Recommendation__c: 'Best available.',
                Is_Current__c: true
            })
        );
        await Promise.resolve();
        const text = el.shadowRoot.textContent;
        expect(text).toContain('64.4');
        expect(text).toContain('1 must-have gap(s)');
        expect(el.shadowRoot.querySelectorAll('.line').length).toBe(2);
        expect(text).toContain('Ask about REST');
        expect(text).toContain('Best available.');
    });
});
