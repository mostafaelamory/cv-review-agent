import { createElement } from 'lwc';
import CvReviewHome, { buildPrompts } from 'c/cvReviewHome';
import getHome from '@salesforce/apex/CvHomeController.getHome';

jest.mock('@salesforce/apex/CvHomeController.getHome', () => {
    const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
    return { default: createApexTestWireAdapter(jest.fn()) };
}, { virtual: true });

const HOME = {
    firstName: 'Laila',
    stats: [
        { key: 'cards', label: 'Candidate cards', value: 9 },
        { key: 'review', label: 'Needs review', value: 1 }
    ],
    recentCandidates: [
        { Id: 'a1', Name: 'Lina Haddad', Headline__c: 'Lead Developer', Card_Status__c: 'Ready', Card_Completeness__c: 100, Has_Conflicts__c: false },
        { Id: 'a2', Name: 'Youssef Nasser', Card_Status__c: 'Ready', Card_Completeness__c: 100, Has_Conflicts__c: true }
    ],
    myShortlist: [{ Id: 'b1', Candidate__r: { Name: 'Lina Haddad' }, Job_Role__r: { Name: 'Senior Salesforce Developer' }, Score__c: 67.9, Band__c: 'Possible', Status__c: 'Shortlisted' }],
    roles: [{ id: 'r1', name: 'Senior Salesforce Developer', requirements: 9, evaluated: 3, strong: 0 }]
};

describe('c-cv-review-home', () => {
    afterEach(() => {
        while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
    });

    it('builds prompts from real role and candidate names', () => {
        const prompts = buildPrompts(HOME);
        expect(prompts.find((p) => p.id === 'p3').text).toBe('Rank all candidates for Senior Salesforce Developer');
        expect(prompts.find((p) => p.id === 'p1').text).toContain('Lina Haddad');
        expect(buildPrompts({}).length).toBe(6);
    });

    it('renders KPIs, shortlist, recent cards and roles', async () => {
        const el = createElement('c-cv-review-home', { is: CvReviewHome });
        document.body.appendChild(el);
        getHome.emit(HOME);
        await Promise.resolve();
        const text = el.shadowRoot.textContent;
        expect(text).toContain('Laila');
        expect(el.shadowRoot.querySelectorAll('.kpi').length).toBe(2);
        expect(el.shadowRoot.querySelectorAll('.prompt').length).toBe(6);
        expect(text).toContain('Conflicts');
        expect(text).toContain('67.9');
        expect(text).toContain('9 requirements');
    });

    it('shows an error message when loading fails', async () => {
        const el = createElement('c-cv-review-home', { is: CvReviewHome });
        document.body.appendChild(el);
        getHome.error({ message: 'boom' });
        await Promise.resolve();
        expect(el.shadowRoot.querySelector('[role="alert"]')).not.toBeNull();
    });
});
