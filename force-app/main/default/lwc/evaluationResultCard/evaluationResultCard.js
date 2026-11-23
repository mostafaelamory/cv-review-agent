import { LightningElement, api } from 'lwc';

const BAND_CLASS = {
    Strong: 'slds-badge slds-theme_success',
    Possible: 'slds-badge slds-theme_warning',
    Weak: 'slds-badge slds-theme_error'
};

/** Splits bullet text ("• a\n• b") into display lines without the bullet glyph. */
export function toLines(text) {
    if (!text) return [];
    return String(text)
        .split(/\r?\n/)
        .map((l) => l.replace(/^\s*[•\-*]\s*/, '').trim())
        .filter(Boolean);
}

function fmt(n) {
    if (n === null || n === undefined || n === '') return '–';
    const num = Number(n);
    return Number.isInteger(num) ? String(num) : num.toFixed(1);
}

function toList(items, prefix) {
    return (items || []).filter(Boolean).map((text, i) => ({ key: `${prefix}-${i}`, text }));
}

export default class EvaluationResultCard extends LightningElement {
    _value;
    expanded = {};

    @api
    get value() {
        return this._value;
    }
    set value(v) {
        this._value = v;
    }

    get result() {
        const v = this._value;
        if (!v) return null;
        if (typeof v === 'string') {
            try {
                return JSON.parse(v);
            } catch (e) {
                return null;
            }
        }
        return v;
    }

    get hasValue() {
        return !!this.result;
    }

    get roleLabel() {
        return this.result?.roleName ? `Ranking for ${this.result.roleName}` : 'Candidate ranking';
    }

    get roleUrl() {
        return this.result?.roleId ? `/lightning/r/Job_Role__c/${this.result.roleId}/view` : null;
    }

    get ariaLabel() {
        return this.roleLabel;
    }

    get rawRows() {
        return Array.isArray(this.result?.rows) ? this.result.rows : [];
    }

    get hasRows() {
        return this.rawRows.length > 0;
    }

    get showNoStrongBanner() {
        return this.hasRows && this.result.anyStrong === false;
    }

    get bestAvailable() {
        const first = this.rawRows[0];
        if (!first) return '';
        const score = first.score === null || first.score === undefined ? '' : ` (${fmt(first.score)}/100)`;
        return `${first.candidateName || 'Unknown candidate'}${score}`;
    }

    get rows() {
        return this.rawRows.map((r, i) => {
            const key = r.evaluationId || r.candidateId || `row-${i}`;
            const isExpanded = !!this.expanded[key];
            const flags = [];
            if (r.mustHaveGaps > 0) {
                flags.push({
                    label: `${r.mustHaveGaps} must-have gap${r.mustHaveGaps === 1 ? '' : 's'}`,
                    cssClass: 'slds-badge slds-badge_lightest slds-text-color_error slds-m-right_xx-small'
                });
            }
            if (r.lowData) {
                flags.push({ label: 'Low data', cssClass: 'slds-badge slds-badge_lightest slds-m-right_xx-small' });
            }
            if (r.gated) {
                flags.push({ label: 'Score capped', cssClass: 'slds-badge slds-badge_lightest slds-m-right_xx-small' });
            }
            const breakdown = (r.breakdown || []).map((b, j) => ({
                ...b,
                key: `${key}-b-${j}`,
                isMustHave: b.type === 'Must-have' || b.type === 'Must Have' || b.type === 'MustHave',
                points: `${fmt(b.pointsEarned)}/${fmt(b.pointsPossible)}`
            }));
            const notes = [
                { title: 'Strengths', text: r.strengths },
                { title: 'Concerns', text: r.concerns },
                { title: 'Interview probes', text: r.interviewProbes }
            ]
                .map((n) => ({
                    title: n.title,
                    lines: toLines(n.text).map((text, j) => ({ key: `${key}-${n.title}-${j}`, text }))
                }))
                .filter((n) => n.lines.length);
            const name = r.candidateName || 'Unknown candidate';
            return {
                key,
                rank: r.rank ?? i + 1,
                rankLabel: `Rank ${r.rank ?? i + 1}`,
                candidateName: name,
                candidateUrl: r.candidateId ? `/lightning/r/Candidate__c/${r.candidateId}/view` : null,
                scoreLabel: `${fmt(r.score)}/100`,
                band: r.band,
                bandClass: BAND_CLASS[r.band] || 'slds-badge',
                flags,
                hasFlags: flags.length > 0,
                breakdown,
                hasBreakdown: breakdown.length > 0,
                breakdownLabel: `Score breakdown for ${name}`,
                notes,
                expanded: isExpanded,
                ariaExpanded: isExpanded ? 'true' : 'false',
                toggleIcon: isExpanded ? 'utility:chevronup' : 'utility:chevrondown',
                toggleLabel: `${isExpanded ? 'Hide' : 'Show'} details for ${name}`
            };
        });
    }

    get pending() {
        return toList(this.result?.pending, 'p');
    }

    get hasPending() {
        return this.pending.length > 0;
    }

    get failed() {
        return toList(this.result?.failed, 'f');
    }

    get hasFailed() {
        return this.failed.length > 0;
    }

    handleToggle(event) {
        const key = event.currentTarget.dataset.key;
        this.expanded = { ...this.expanded, [key]: !this.expanded[key] };
    }
}
