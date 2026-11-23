import { createElement } from 'lwc';
import EvaluationResultCard, { toLines } from 'c/evaluationResultCard';

const flush = () => Promise.resolve();

const VALUE = {
    roleName: 'Senior Salesforce Developer',
    roleId: 'a01X',
    recommendation: 'Interview Ada first.',
    tradeOffs: 'Ada is stronger on Apex; Bob on LWC.',
    anyStrong: true,
    rows: [
        {
            rank: 1,
            candidateId: 'c1',
            candidateName: 'Ada',
            evaluationId: 'ev1',
            score: 86,
            band: 'Strong',
            mustHaveGaps: 0,
            lowData: false,
            gated: false,
            strengths: '• Apex expert\n• Led a team',
            concerns: '• No CPQ',
            interviewProbes: '• Ask about CPQ',
            breakdown: [
                { requirement: 'Apex', type: 'Must-have', match: 'Strong', confidence: 'High', pointsEarned: 20, pointsPossible: 20, rationale: '5 years Apex' },
                { requirement: 'CPQ', type: 'Nice-to-have', match: 'Not evidenced', confidence: 'Low', pointsEarned: 0, pointsPossible: 5 }
            ]
        },
        {
            rank: 2,
            candidateId: 'c2',
            candidateName: 'Bob',
            evaluationId: 'ev2',
            score: 48.5,
            band: 'Weak',
            mustHaveGaps: 2,
            lowData: true,
            gated: true,
            breakdown: []
        }
    ],
    pending: ['Cara'],
    failed: ['Dan: CV could not be read']
};

function create(value) {
    const el = createElement('c-evaluation-result-card', { is: EvaluationResultCard });
    el.value = value;
    document.body.appendChild(el);
    return el;
}

describe('c-evaluation-result-card', () => {
    afterEach(() => {
        while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
    });

    it('handles a null value', () => {
        const el = create(null);
        expect(el.shadowRoot.querySelector('.empty')).not.toBeNull();
    });

    it('handles an empty result', () => {
        const el = create({ roleName: 'X', rows: [] });
        expect(el.shadowRoot.querySelector('.no-rows')).not.toBeNull();
        expect(el.shadowRoot.querySelector('.no-strong')).toBeNull();
    });

    it('renders ranked rows with score, band and flags', () => {
        const el = create(VALUE);
        const root = el.shadowRoot;
        expect(root.querySelector('.recommendation').textContent).toBe('Interview Ada first.');
        expect(root.querySelector('.trade-offs').textContent).toContain('Bob on LWC');
        const rows = root.querySelectorAll('.result-row');
        expect(rows).toHaveLength(2);
        expect(rows[0].querySelector('.candidate-link').getAttribute('href')).toBe('/lightning/r/Candidate__c/c1/view');
        expect(rows[0].querySelector('.score').textContent).toBe('86/100');
        expect(rows[0].querySelector('.slds-theme_success').textContent).toBe('Strong');
        expect(rows[0].querySelector('.flags')).toBeNull();
        expect(rows[1].querySelector('.score').textContent).toBe('48.5/100');
        expect(rows[1].querySelector('.slds-theme_error').textContent).toBe('Weak');
        const flags = rows[1].querySelector('.flags').textContent;
        expect(flags).toContain('2 must-have gaps');
        expect(flags).toContain('Low data');
        expect(flags).toContain('Score capped');
        expect(root.querySelector('.pending').textContent).toContain('Cara');
        expect(root.querySelector('.failed').textContent).toContain('Dan');
        expect(root.querySelector('.no-strong')).toBeNull();
    });

    it('expands a row to show breakdown and notes', async () => {
        const el = create(VALUE);
        const btn = el.shadowRoot.querySelector('.toggle-button[data-key="ev1"]');
        expect(btn.getAttribute('aria-expanded')).toBe('false');
        btn.click();
        await flush();
        const row = el.shadowRoot.querySelector('.result-row[data-id="ev1"]');
        expect(row.querySelectorAll('.breakdown-table tbody tr')).toHaveLength(2);
        expect(row.querySelector('.breakdown-table').textContent).toContain('20/20');
        const bullets = [...row.querySelectorAll('.bullets li')].map((li) => li.textContent);
        expect(bullets).toEqual(['Apex expert', 'Led a team', 'No CPQ', 'Ask about CPQ']);
        expect(el.shadowRoot.querySelector('.toggle-button[data-key="ev1"]').getAttribute('aria-expanded')).toBe('true');
    });

    it('shows the no-strong-match banner', () => {
        const el = create({ ...VALUE, anyStrong: false });
        expect(el.shadowRoot.querySelector('.no-strong').textContent).toContain('best available: Ada (86/100)');
    });

    it('toLines strips bullets and blank lines', () => {
        expect(toLines('• a\n\n• b\r\n- c')).toEqual(['a', 'b', 'c']);
        expect(toLines(null)).toEqual([]);
    });
});
