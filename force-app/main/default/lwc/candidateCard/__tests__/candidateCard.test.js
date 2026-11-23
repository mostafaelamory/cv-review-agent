import { createElement } from 'lwc';
import CandidateCard, { groupFacts } from 'c/candidateCard';
import getCard from '@salesforce/apex/CandidateCardController.getCard';
import correctFact from '@salesforce/apex/CandidateCardController.correctFact';
import { refreshApex } from '@salesforce/apex';

jest.mock(
    '@salesforce/apex/CandidateCardController.getCard',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock('@salesforce/apex/CandidateCardController.correctFact', () => ({ default: jest.fn() }), { virtual: true });
jest.mock(
    '@salesforce/apex',
    () => ({ refreshApex: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

const flush = async () => {
    for (let i = 0; i < 5; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
};

const CARD = {
    candidate: {
        Id: 'c1',
        Name: 'Ada Lovelace',
        Headline__c: 'Senior Salesforce Developer',
        Location__c: 'London',
        Email__c: 'ada@example.com',
        Phone__c: '+44 1234',
        Card_Completeness__c: 75,
        Card_Status__c: 'Ready',
        Has_Conflicts__c: true,
        Possible_Duplicate_Of__c: 'c2',
        Possible_Duplicate_Of__r: { Name: 'A. Lovelace' }
    },
    experienceLabel: '6 years 2 months',
    badgeCounts: { Stated: 1, Inferred: 1, Conflicting: 2, Missing: 1, 'Recruiter-verified': 1 },
    sections: [
        {
            category: 'Contact',
            issueCount: 1,
            facts: [
                { id: 'e1', category: 'Contact', attribute: 'Email', value: 'ada@example.com', badge: 'Stated', confidence: 'High', quote: 'ada@example.com', page: 1 },
                { id: 'e2', category: 'Contact', attribute: 'Phone', value: null, badge: 'Missing', detail: 'No phone number in the CV' }
            ]
        },
        {
            category: 'Experience',
            issueCount: 3,
            facts: [
                { id: 'e3', category: 'Experience', attribute: 'Title', value: 'Lead Dev', organization: 'Acme', dates: '2019 – 2024', badge: 'Conflicting', conflictGroup: 'g1', detail: 'Two different end dates' },
                { id: 'e4', category: 'Experience', attribute: 'Seniority', value: 'Senior', badge: 'Inferred', inferenceReason: 'Leads a team of five' },
                { id: 'e5', category: 'Experience', attribute: 'Title', value: 'Lead Developer', organization: 'Acme', dates: '2019 – 2023', badge: 'Conflicting', conflictGroup: 'g1' },
                { id: 'e6', category: 'Experience', attribute: 'Employer', value: 'Acme', badge: 'Recruiter-verified', confidence: 'High' }
            ]
        }
    ],
    files: [{ documentId: 'doc1', name: 'ada.pdf', contentDocumentId: '069X', method: 'PDF transcript', status: 'Extracted' }]
};

function create() {
    const el = createElement('c-candidate-card', { is: CandidateCard });
    el.recordId = 'c1';
    document.body.appendChild(el);
    return el;
}

describe('c-candidate-card', () => {
    afterEach(() => {
        while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
        jest.clearAllMocks();
    });

    it('renders the header, legend, sections and files', async () => {
        const el = create();
        getCard.emit(CARD);
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.slds-card__header-title').textContent).toBe('Ada Lovelace');
        expect(root.querySelector('.headline').textContent).toBe('Senior Salesforce Developer');
        expect(root.querySelector('.experience').textContent).toContain('inferred from dates');
        expect(root.querySelector('lightning-progress-bar').value).toBe(75);
        expect(root.querySelector('.conflicts-flag')).not.toBeNull();
        expect(root.querySelector('.duplicate a').getAttribute('href')).toBe('/lightning/r/Candidate__c/c2/view');
        expect(root.querySelectorAll('.legend-item')).toHaveLength(6);
        expect(root.querySelectorAll('.fact-section')).toHaveLength(2);
        expect(root.querySelectorAll('.fact-row')).toHaveLength(6);
        const fileLink = root.querySelector('.file-item a');
        expect(fileLink.getAttribute('href')).toBe('/lightning/r/ContentDocument/069X/view');
        expect(root.querySelector('.file-item').textContent).toContain('PDF transcript');
    });

    it('maps badges to SLDS styles and shows source and reasons', async () => {
        const el = create();
        getCard.emit(CARD);
        await flush();
        const row = (id) => el.shadowRoot.querySelector(`.fact-row[data-id="${id}"]`);
        expect(row('e1').querySelector('.slds-badge').className).toContain('badge-stated');
        expect(row('e1').querySelector('lightning-helptext').content).toBe('Source: "ada@example.com" (page 1)');
        expect(row('e2').querySelector('.slds-badge').className).toBe('slds-badge');
        expect(row('e2').querySelector('.explanation').textContent).toContain('No phone number');
        expect(row('e3').querySelector('.slds-badge').className).toContain('slds-theme_error');
        expect(row('e4').querySelector('.slds-badge').className).toContain('badge-inferred');
        expect(row('e4').querySelector('.explanation').textContent).toContain('Leads a team of five');
        expect(row('e6').querySelector('.slds-badge').className).toContain('slds-theme_success');
        expect(row('e6').querySelector('lightning-icon[icon-name="utility:check"], .slds-badge lightning-icon')).not.toBeNull();
    });

    it('groups conflicting facts together', async () => {
        const el = create();
        getCard.emit(CARD);
        await flush();
        const groups = el.shadowRoot.querySelectorAll('.conflict-group');
        expect(groups).toHaveLength(1);
        const ids = [...groups[0].querySelectorAll('.fact-row')].map((r) => r.dataset.id);
        expect(ids).toEqual(['e3', 'e5']);
    });

    it('groupFacts keeps non-conflicting rows separate', () => {
        const groups = groupFacts([
            { id: 'a', badge: 'Stated' },
            { id: 'b', badge: 'Conflicting', conflictGroup: 'x' },
            { id: 'c', badge: 'Conflicting', conflictGroup: 'x' }
        ]);
        expect(groups).toHaveLength(2);
        expect(groups[1].facts).toHaveLength(2);
    });

    it('filters to issues only', async () => {
        const el = create();
        getCard.emit(CARD);
        await flush();
        const toggle = el.shadowRoot.querySelector('.issues-toggle');
        toggle.checked = true;
        toggle.dispatchEvent(new CustomEvent('change'));
        await flush();
        const ids = [...el.shadowRoot.querySelectorAll('.fact-row')].map((r) => r.dataset.id);
        expect(ids.sort()).toEqual(['e2', 'e3', 'e4', 'e5']);
    });

    it('corrects a fact and refreshes the card', async () => {
        correctFact.mockResolvedValue();
        const el = create();
        getCard.emit(CARD);
        await flush();
        el.shadowRoot.querySelector('.correct-button[data-id="e4"]').click();
        await flush();
        const input = el.shadowRoot.querySelector('.edit-value');
        expect(input.value).toBe('Senior');
        input.value = 'Lead';
        input.dispatchEvent(new CustomEvent('change'));
        const note = el.shadowRoot.querySelector('.edit-note');
        note.value = 'Confirmed on call';
        note.dispatchEvent(new CustomEvent('change'));
        el.shadowRoot.querySelector('.save-button').click();
        await flush();
        expect(correctFact).toHaveBeenCalledWith({ evidenceId: 'e4', value: 'Lead', note: 'Confirmed on call' });
        expect(refreshApex).toHaveBeenCalled();
        expect(el.shadowRoot.querySelector('.edit-panel')).toBeNull();
    });

    it('shows an error when the card cannot load', async () => {
        const el = create();
        getCard.error({ message: 'Candidate not found or not visible to you.' });
        await flush();
        expect(el.shadowRoot.querySelector('[role="alert"]').textContent).toContain('Candidate not found');
    });
});
