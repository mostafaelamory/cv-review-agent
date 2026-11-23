import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getCard from '@salesforce/apex/CandidateCardController.getCard';
import correctFact from '@salesforce/apex/CandidateCardController.correctFact';

const BADGE_ORDER = ['Stated', 'Recruiter-verified', 'Inferred', 'Unverified', 'Conflicting', 'Missing'];
const BADGE_CLASS = {
    Stated: 'slds-badge badge-stated',
    Inferred: 'slds-badge badge-inferred',
    Missing: 'slds-badge',
    Conflicting: 'slds-badge slds-theme_error',
    Unverified: 'slds-badge slds-theme_warning',
    'Recruiter-verified': 'slds-badge slds-theme_success'
};
const NON_ISSUE = new Set(['Stated', 'Recruiter-verified']);

export function badgeClass(badge) {
    return BADGE_CLASS[badge] || 'slds-badge';
}

export function isIssue(fact) {
    return !NON_ISSUE.has(fact.badge);
}

function errorText(error) {
    if (!error) return 'Unknown error';
    if (Array.isArray(error.body)) return error.body.map((e) => e.message).join(', ');
    return error.body?.message || error.message || 'Unknown error';
}

function decorateFact(fact, editingId) {
    const sourceParts = [];
    if (fact.quote) sourceParts.push(`"${fact.quote}"`);
    if (fact.page !== null && fact.page !== undefined) sourceParts.push(`(page ${fact.page})`);
    let explanation;
    let explanationLabel;
    if (fact.badge === 'Inferred' && fact.inferenceReason) {
        explanation = fact.inferenceReason;
        explanationLabel = 'Inferred because';
    } else if ((fact.badge === 'Missing' || fact.badge === 'Conflicting') && fact.detail) {
        explanation = fact.detail;
        explanationLabel = 'Detail';
    }
    const subParts = [fact.organization, fact.dates].filter(Boolean);
    const attributeLabel = fact.attribute && fact.attribute !== fact.value ? fact.attribute : null;
    return {
        ...fact,
        attributeLabel,
        displayValue: fact.value || (fact.badge === 'Missing' ? 'Not found in CV' : '—'),
        subLine: subParts.join(' · '),
        badgeClass: badgeClass(fact.badge),
        showCheck: fact.badge === 'Recruiter-verified',
        sourceText: sourceParts.length ? `Source: ${sourceParts.join(' ')}` : null,
        explanation,
        explanationLabel,
        correctLabel: `Correct ${fact.attribute || fact.category || 'fact'}`,
        isEditing: fact.id === editingId
    };
}

/** Builds display groups so rows sharing a conflictGroup render together. */
export function groupFacts(facts) {
    const groups = [];
    const conflictGroups = new Map();
    facts.forEach((f) => {
        if (f.badge === 'Conflicting' && f.conflictGroup) {
            let g = conflictGroups.get(f.conflictGroup);
            if (!g) {
                g = {
                    key: `conflict-${f.conflictGroup}`,
                    isConflict: true,
                    label: f.attribute || f.conflictGroup,
                    cssClass: 'conflict-group slds-m-bottom_x-small',
                    facts: []
                };
                conflictGroups.set(f.conflictGroup, g);
                groups.push(g);
            }
            g.facts.push(f);
        } else {
            groups.push({ key: `fact-${f.id}`, isConflict: false, cssClass: '', facts: [f] });
        }
    });
    return groups;
}

export default class CandidateCard extends LightningElement {
    @api recordId;

    card;
    errorMessage;
    showIssuesOnly = false;
    editingId;
    editValue = '';
    editNote = '';
    isSaving = false;

    _wired;
    _loaded = false;

    @wire(getCard, { candidateId: '$recordId' })
    wiredCard(result) {
        this._wired = result;
        const { data, error } = result;
        if (data) {
            this.card = data;
            this.errorMessage = undefined;
            this._loaded = true;
        } else if (error) {
            this.card = undefined;
            this.errorMessage = errorText(error);
            this._loaded = true;
        }
    }

    get isLoading() {
        return !this._loaded;
    }

    get candidate() {
        return this.card?.candidate || {};
    }

    get name() {
        return this.candidate.Name || 'Candidate';
    }

    get completenessValue() {
        const v = this.candidate.Card_Completeness__c;
        return v === null || v === undefined ? 0 : Number(v);
    }

    get completenessLabel() {
        const v = this.candidate.Card_Completeness__c;
        return v === null || v === undefined ? 'n/a' : `${Math.round(Number(v))}%`;
    }

    get duplicateUrl() {
        const id = this.candidate.Possible_Duplicate_Of__c;
        return id ? `/lightning/r/Candidate__c/${id}/view` : null;
    }

    get duplicateName() {
        return this.candidate.Possible_Duplicate_Of__r?.Name || 'another candidate';
    }

    get legend() {
        const counts = this.card?.badgeCounts || {};
        const extra = Object.keys(counts).filter((b) => !BADGE_ORDER.includes(b));
        return [...BADGE_ORDER, ...extra].map((badge) => ({
            badge,
            count: counts[badge] || 0,
            badgeClass: badgeClass(badge),
            showCheck: badge === 'Recruiter-verified'
        }));
    }

    get visibleSections() {
        const sections = this.card?.sections || [];
        return sections
            .map((s) => {
                const facts = (s.facts || [])
                    .filter((f) => !this.showIssuesOnly || isIssue(f))
                    .map((f) => decorateFact(f, this.editingId));
                return {
                    category: s.category,
                    issueCount: s.issueCount || 0,
                    issueLabel: `${s.issueCount} to review`,
                    groups: groupFacts(facts),
                    size: facts.length
                };
            })
            .filter((s) => s.size > 0);
    }

    get hasVisibleSections() {
        return this.visibleSections.length > 0;
    }

    get emptyMessage() {
        return this.showIssuesOnly ? 'No issues: every fact is stated or verified.' : 'No facts extracted yet.';
    }

    get files() {
        return (this.card?.files || []).map((f) => ({
            ...f,
            url: f.contentDocumentId ? `/lightning/r/ContentDocument/${f.contentDocumentId}/view` : null,
            meta: [f.method, f.status].filter(Boolean).join(' · ')
        }));
    }

    get hasFiles() {
        return this.files.length > 0;
    }

    handleToggleIssues(event) {
        this.showIssuesOnly = event.target.checked;
    }

    findFact(id) {
        for (const s of this.card?.sections || []) {
            const f = (s.facts || []).find((x) => x.id === id);
            if (f) return f;
        }
        return undefined;
    }

    handleStartEdit(event) {
        const id = event.currentTarget.dataset.id;
        const fact = this.findFact(id);
        this.editingId = id;
        this.editValue = fact?.value || '';
        this.editNote = '';
    }

    handleEditValue(event) {
        this.editValue = event.target.value;
    }

    handleEditNote(event) {
        this.editNote = event.target.value;
    }

    handleCancelEdit() {
        this.editingId = undefined;
        this.editValue = '';
        this.editNote = '';
    }

    async handleSaveEdit() {
        if (!this.editingId) return;
        this.isSaving = true;
        try {
            await correctFact({ evidenceId: this.editingId, value: this.editValue, note: this.editNote });
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Fact corrected', message: 'Marked as recruiter-verified.', variant: 'success' })
            );
            this.handleCancelEdit();
            await refreshApex(this._wired);
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Could not save the correction', message: errorText(e), variant: 'error' }));
        } finally {
            this.isSaving = false;
        }
    }
}
