import { LightningElement, api } from 'lwc';
import registerUploads from '@salesforce/apex/CvIntakeController.registerUploads';
import getStatuses from '@salesforce/apex/CvIntakeController.getStatuses';
import getRecent from '@salesforce/apex/CvIntakeController.getRecent';
import getPdfData from '@salesforce/apex/CvIntakeController.getPdfData';
import submitPdfText from '@salesforce/apex/CvIntakeController.submitPdfText';
import { extractPdfPages } from './pdfText';

export const POLL_INTERVAL_MS = 4000;
export const POLL_MAX_MS = 5 * 60 * 1000;
const TERMINAL = new Set(['Extracted', 'Needs Review', 'Failed', 'Duplicate']);
const BADGE_CLASS = {
    Extracted: 'slds-badge slds-theme_success',
    'Needs Review': 'slds-badge slds-theme_warning',
    Failed: 'slds-badge slds-theme_error'
};

export function errorText(error) {
    if (!error) return 'Unknown error';
    if (Array.isArray(error.body)) return error.body.map((e) => e.message).join(', ');
    return error.body?.message || error.message || 'Unknown error';
}

export default class CvUpload extends LightningElement {
    @api recordId;

    acceptedFormats = ['.pdf', '.docx', '.doc'];
    helpText = 'PDF or DOCX, up to 10 files at a time. Legacy .doc files are rejected.';

    rows = [];
    errorMessage;
    isBusy = false;
    isPolling = false;
    loaded = false;

    _timer;
    _pollStarted;

    connectedCallback() {
        this.loadRecent();
    }

    disconnectedCallback() {
        this.stopPolling();
    }

    async loadRecent() {
        this.isBusy = true;
        try {
            const result = await getRecent({ jobRoleId: this.recordId || null });
            this.rows = result || [];
            this.errorMessage = undefined;
            this.ensurePolling();
        } catch (e) {
            this.errorMessage = errorText(e);
        } finally {
            this.isBusy = false;
            this.loaded = true;
        }
    }

    async handleUploadFinished(event) {
        const files = event.detail?.files || [];
        const contentDocumentIds = files.map((f) => f.documentId).filter(Boolean);
        if (!contentDocumentIds.length) return;
        this.isBusy = true;
        try {
            const result = await registerUploads({
                contentDocumentIds,
                jobRoleId: this.recordId || null,
                clientExtractsPdf: true
            });
            this.mergeRows(result || [], true);
            this.errorMessage = undefined;
            await this.submitPdfTexts((result || []).filter((r) => r.awaitingText));
            this._pollStarted = Date.now();
            this.ensurePolling();
        } catch (e) {
            this.errorMessage = errorText(e);
        } finally {
            this.isBusy = false;
        }
    }

    /**
     * Reads each PDF's text layer in the browser and hands it to the server.
     * On any failure the server is still told to start, with no text, so it
     * falls back to model transcription instead of leaving the file queued.
     */
    async submitPdfTexts(pdfRows) {
        for (const row of pdfRows) {
            let pages = [];
            try {
                // eslint-disable-next-line no-await-in-loop
                const data = await getPdfData({ documentId: row.documentId });
                // eslint-disable-next-line no-await-in-loop
                if (data) pages = await extractPdfPages(this, data);
            } catch (e) {
                pages = [];
            }
            try {
                // eslint-disable-next-line no-await-in-loop
                const status = await submitPdfText({ documentId: row.documentId, pages });
                if (status) this.mergeRows([status], false);
            } catch (e) {
                this.errorMessage = errorText(e);
            }
        }
    }

    mergeRows(incoming, prepend) {
        const byId = new Map(incoming.map((r) => [r.documentId, r]));
        const kept = this.rows.map((r) => byId.get(r.documentId) || r);
        const existing = new Set(this.rows.map((r) => r.documentId));
        const added = incoming.filter((r) => !existing.has(r.documentId));
        this.rows = prepend ? [...added, ...kept] : [...kept, ...added];
    }

    get pendingIds() {
        return this.rows.filter((r) => !TERMINAL.has(r.status)).map((r) => r.documentId);
    }

    ensurePolling() {
        if (!this.pendingIds.length) {
            this.stopPolling();
            return;
        }
        if (this._timer) return;
        if (!this._pollStarted) this._pollStarted = Date.now();
        this.isPolling = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._timer = setInterval(() => this.poll(), POLL_INTERVAL_MS);
    }

    stopPolling() {
        if (this._timer) {
            clearInterval(this._timer);
        }
        this._timer = undefined;
        this._pollStarted = undefined;
        this.isPolling = false;
    }

    async poll() {
        const ids = this.pendingIds;
        if (!ids.length || Date.now() - this._pollStarted > POLL_MAX_MS) {
            this.stopPolling();
            return;
        }
        try {
            const result = await getStatuses({ documentIds: ids });
            this.mergeRows(result || [], false);
            if (!this.pendingIds.length) this.stopPolling();
        } catch (e) {
            this.errorMessage = errorText(e);
            this.stopPolling();
        }
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get showEmpty() {
        return this.loaded && !this.isBusy;
    }

    get displayRows() {
        return this.rows.map((r) => {
            const hasCompleteness = r.completeness !== null && r.completeness !== undefined;
            return {
                ...r,
                badgeClass: BADGE_CLASS[r.status] || 'slds-badge',
                candidateUrl: r.candidateId ? `/lightning/r/Candidate__c/${r.candidateId}/view` : null,
                candidateLabel: r.candidateName || 'View candidate',
                hasCompleteness,
                completenessFraction: hasCompleteness ? Number(r.completeness) / 100 : null
            };
        });
    }
}
