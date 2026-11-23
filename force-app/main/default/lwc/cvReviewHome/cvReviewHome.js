import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getHome from '@salesforce/apex/CvHomeController.getHome';

const STAT_TONE = { review: 'warning', failed: 'error', ready: 'success', shortlist: 'brand', processing: 'info' };
const CARD_BADGE = {
    Ready: 'slds-badge slds-theme_success',
    'Needs Review': 'slds-badge slds-theme_warning',
    Failed: 'slds-badge slds-theme_error'
};
const BAND_BADGE = {
    Strong: 'slds-badge slds-theme_success',
    Possible: 'slds-badge slds-theme_warning',
    Weak: 'slds-badge slds-theme_error'
};

/** Prompts for the agent, filled with real role and candidate names when available. */
export function buildPrompts(home) {
    const role = home?.roles?.[0]?.name || 'Senior Salesforce Developer';
    const names = (home?.recentCandidates || []).map((c) => c.Name).filter((n) => !/name not found/i.test(n));
    const unique = [...new Set(names)];
    const a = unique[0] || 'Omar Khalil';
    const b = unique[1] || 'Lina Haddad';
    return [
        { id: 'p1', group: 'Ask', text: `Does ${a} have Lightning Web Components experience?` },
        { id: 'p2', group: 'Ask', text: 'Who has worked with MuleSoft or integrations?' },
        { id: 'p3', group: 'Rank', text: `Rank all candidates for ${role}` },
        { id: 'p4', group: 'Explain', text: `Why is ${b} ranked above ${a}?` },
        { id: 'p5', group: 'Bookmark', text: `Bookmark ${b} for ${role} with the note: strong fit, check integrations` },
        { id: 'p6', group: 'Status', text: 'Which CVs failed or need review?' }
    ];
}

export default class CvReviewHome extends NavigationMixin(LightningElement) {
    home;
    error;
    _wired;

    @wire(getHome)
    wiredHome(result) {
        this._wired = result;
        if (result.data) {
            this.home = result.data;
            this.error = undefined;
        } else if (result.error) {
            this.error = result.error?.body?.message || 'Could not load the home page.';
        }
    }

    get greeting() {
        const h = new Date().getHours();
        const part = h < 12 ? 'Good morning' : h < 18 ? 'Good afternoon' : 'Good evening';
        return this.home?.firstName ? `${part}, ${this.home.firstName}` : part;
    }

    get stats() {
        return (this.home?.stats || []).map((s) => ({
            ...s,
            tileClass: `kpi kpi_${STAT_TONE[s.key] || 'neutral'}`
        }));
    }

    get prompts() {
        return buildPrompts(this.home);
    }

    get recent() {
        return (this.home?.recentCandidates || []).map((c) => ({
            ...c,
            badgeClass: CARD_BADGE[c.Card_Status__c] || 'slds-badge',
            completeness: c.Card_Completeness__c == null ? null : c.Card_Completeness__c / 100,
            flags: [c.Has_Conflicts__c ? 'Conflicts' : null, c.Possible_Duplicate_Of__c ? 'Possible duplicate' : null]
                .filter(Boolean)
                .join(' · ')
        }));
    }

    get shortlist() {
        return (this.home?.myShortlist || []).map((b) => ({
            ...b,
            candidateName: b.Candidate__r?.Name,
            roleName: b.Job_Role__r?.Name,
            badgeClass: BAND_BADGE[b.Band__c] || 'slds-badge'
        }));
    }

    get roles() {
        return this.home?.roles || [];
    }

    get hasRecent() {
        return this.recent.length > 0;
    }
    get hasShortlist() {
        return this.shortlist.length > 0;
    }
    get hasRoles() {
        return this.roles.length > 0;
    }

    async handlePrompt(event) {
        const text = event.currentTarget.dataset.text;
        let copied = false;
        try {
            await navigator.clipboard.writeText(text);
            copied = true;
        } catch (e) {
            copied = false;
        }
        this.dispatchEvent(
            new ShowToastEvent({
                title: copied ? 'Prompt copied' : 'Prompt',
                message: copied
                    ? 'Open Agentforce from the header (top right) and paste it.'
                    : `Open Agentforce from the header (top right) and ask: "${text}"`,
                variant: 'success'
            })
        );
    }

    openRecord(event) {
        event.preventDefault();
        const { id, object } = event.currentTarget.dataset;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: id, objectApiName: object, actionName: 'view' }
        });
    }

    goUpload() {
        this[NavigationMixin.Navigate]({ type: 'standard__navItemPage', attributes: { apiName: 'CV_Intake' } });
    }

    goList(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: event.currentTarget.dataset.object, actionName: 'list' },
            state: { filterName: event.currentTarget.dataset.filter || 'Recent' }
        });
    }

    refresh() {
        return refreshApex(this._wired);
    }
}
