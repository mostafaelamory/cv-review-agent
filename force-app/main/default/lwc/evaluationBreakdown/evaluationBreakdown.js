import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import BOOKMARK_EVALUATION from '@salesforce/schema/Candidate_Bookmark__c.Candidate_Evaluation__c';
import SCORE from '@salesforce/schema/Candidate_Evaluation__c.Total_Score__c';
import BAND from '@salesforce/schema/Candidate_Evaluation__c.Band__c';
import GAPS from '@salesforce/schema/Candidate_Evaluation__c.Must_Have_Gaps__c';
import LOW_DATA from '@salesforce/schema/Candidate_Evaluation__c.Low_Data__c';
import BREAKDOWN from '@salesforce/schema/Candidate_Evaluation__c.Breakdown_JSON__c';
import STRENGTHS from '@salesforce/schema/Candidate_Evaluation__c.Strengths__c';
import CONCERNS from '@salesforce/schema/Candidate_Evaluation__c.Concerns__c';
import PROBES from '@salesforce/schema/Candidate_Evaluation__c.Interview_Probes__c';
import RECOMMENDATION from '@salesforce/schema/Candidate_Evaluation__c.Recommendation__c';
import IS_CURRENT from '@salesforce/schema/Candidate_Evaluation__c.Is_Current__c';

const FIELDS = [SCORE, BAND, GAPS, LOW_DATA, BREAKDOWN, STRENGTHS, CONCERNS, PROBES, RECOMMENDATION, IS_CURRENT];
const BAND_CLASS = { Strong: 'slds-theme_success', Possible: 'slds-theme_warning', Weak: 'slds-theme_error' };
const MATCH_CLASS = {
    Met: 'match match_met',
    Partial: 'match match_partial',
    'Not evidenced': 'match match_none',
    Contradicted: 'match match_contra'
};

/** Parses Breakdown_JSON__c into display rows; tolerant of bad or missing JSON. */
export function toRows(json) {
    let lines = [];
    try {
        lines = JSON.parse(json || '[]');
    } catch (e) {
        lines = [];
    }
    return (Array.isArray(lines) ? lines : []).map((l, i) => {
        const possible = Number(l.pointsPossible) || 0;
        const earned = Number(l.pointsEarned) || 0;
        const pct = possible > 0 ? Math.round((earned / possible) * 100) : 0;
        return {
            key: l.requirementId || String(i),
            requirement: l.requirement,
            type: l.type,
            isMust: l.type === 'Must-have',
            match: l.match,
            matchClass: MATCH_CLASS[l.match] || 'match',
            confidence: l.confidence || '—',
            points: `${earned} / ${possible}`,
            barStyle: `width:${pct}%`,
            rationale: l.rationale,
            decidedBy: l.decidedBy === 'Apex date maths' ? 'Decided by date maths' : null,
            evidenceCount: (l.evidenceIds || []).length
        };
    });
}

export function bullets(text) {
    return (text || '')
        .split('\n')
        .map((t) => t.replace(/^\s*[•\-*]\s*/, '').trim())
        .filter(Boolean);
}

export default class EvaluationBreakdown extends LightningElement {
    @api recordId;
    @api objectApiName;

    bookmarkEvaluationId;
    evaluation;
    error;

    get isBookmark() {
        return this.objectApiName === 'Candidate_Bookmark__c';
    }

    get bookmarkRecordId() {
        return this.isBookmark ? this.recordId : undefined;
    }

    get evaluationId() {
        return this.isBookmark ? this.bookmarkEvaluationId : this.recordId;
    }

    @wire(getRecord, { recordId: '$bookmarkRecordId', fields: [BOOKMARK_EVALUATION] })
    wiredBookmark({ data, error }) {
        if (data) this.bookmarkEvaluationId = getFieldValue(data, BOOKMARK_EVALUATION);
        if (error) this.error = 'Could not load the bookmark.';
    }

    @wire(getRecord, { recordId: '$evaluationId', fields: FIELDS })
    wiredEvaluation({ data, error }) {
        if (data) {
            this.evaluation = data;
            this.error = undefined;
        } else if (error) {
            this.error = 'Could not load the evaluation.';
        }
    }

    val(field) {
        return this.evaluation ? getFieldValue(this.evaluation, field) : null;
    }

    get title() {
        return this.isBookmark ? 'Evaluation at bookmarking' : 'Score breakdown';
    }
    get score() {
        return this.val(SCORE);
    }
    get band() {
        return this.val(BAND);
    }
    get bandClass() {
        return `slds-badge ${BAND_CLASS[this.band] || ''}`;
    }
    get gaps() {
        return this.val(GAPS);
    }
    get hasGaps() {
        return Number(this.gaps) > 0;
    }
    get lowData() {
        return this.val(LOW_DATA);
    }
    get superseded() {
        return this.evaluation && this.val(IS_CURRENT) === false;
    }
    get rows() {
        return toRows(this.val(BREAKDOWN));
    }
    get hasRows() {
        return this.rows.length > 0;
    }
    get strengths() {
        return bullets(this.val(STRENGTHS));
    }
    get concerns() {
        return bullets(this.val(CONCERNS));
    }
    get probes() {
        return bullets(this.val(PROBES));
    }
    get recommendation() {
        return this.val(RECOMMENDATION);
    }
    get hasEvaluation() {
        return !!this.evaluation;
    }
    get noEvaluation() {
        return !this.evaluation && !this.error && this.isBookmark && this.bookmarkEvaluationId === null;
    }
}
