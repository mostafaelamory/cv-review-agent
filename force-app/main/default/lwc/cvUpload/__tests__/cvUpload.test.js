import { createElement } from 'lwc';
import CvUpload, { POLL_INTERVAL_MS, POLL_MAX_MS } from 'c/cvUpload';
import registerUploads from '@salesforce/apex/CvIntakeController.registerUploads';
import getStatuses from '@salesforce/apex/CvIntakeController.getStatuses';
import getRecent from '@salesforce/apex/CvIntakeController.getRecent';

jest.mock('@salesforce/apex/CvIntakeController.registerUploads', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CvIntakeController.getPdfData', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CvIntakeController.submitPdfText', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('../pdfText', () => ({ extractPdfPages: jest.fn() }));
jest.mock('@salesforce/apex/CvIntakeController.getStatuses', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CvIntakeController.getRecent', () => ({ default: jest.fn() }), { virtual: true });

const flush = async () => {
    for (let i = 0; i < 5; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
};

const ROLE_ID = 'a01000000000001AAA';

function create(recordId) {
    const el = createElement('c-cv-upload', { is: CvUpload });
    if (recordId) el.recordId = recordId;
    document.body.appendChild(el);
    return el;
}

describe('c-cv-upload', () => {
    beforeEach(() => {
        jest.useFakeTimers();
    });
    afterEach(() => {
        while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
        jest.clearAllMocks();
        jest.useRealTimers();
    });

    it('configures the file upload and shows helper text', async () => {
        getRecent.mockResolvedValue([]);
        const el = create(ROLE_ID);
        await flush();
        const upload = el.shadowRoot.querySelector('lightning-file-upload');
        expect(upload.accept).toEqual(['.pdf', '.docx', '.doc']);
        expect(upload.multiple).toBe(true);
        expect(upload.recordId).toBe(ROLE_ID);
        expect(el.shadowRoot.textContent).toContain('Legacy .doc files are rejected.');
        expect(getRecent).toHaveBeenCalledWith({ jobRoleId: ROLE_ID });
    });

    it('renders recent uploads with badges and candidate links', async () => {
        getRecent.mockResolvedValue([
            { documentId: 'd1', fileName: 'a.pdf', status: 'Extracted', candidateId: 'c1', candidateName: 'Ann', completeness: 80 },
            { documentId: 'd2', fileName: 'b.doc', status: 'Failed', reason: 'Unsupported format: save as PDF or DOCX' },
            { documentId: 'd3', fileName: 'c.pdf', status: 'Needs Review' },
            { documentId: 'd4', fileName: 'd.pdf', status: 'Duplicate' }
        ]);
        const el = create();
        await flush();
        const rows = el.shadowRoot.querySelectorAll('tbody tr');
        expect(rows).toHaveLength(4);
        const badges = [...el.shadowRoot.querySelectorAll('tbody .slds-badge')].map((b) => b.className);
        expect(badges[0]).toContain('slds-theme_success');
        expect(badges[1]).toContain('slds-theme_error');
        expect(badges[2]).toContain('slds-theme_warning');
        expect(badges[3]).toBe('slds-badge');
        const link = el.shadowRoot.querySelector('a.candidate-link');
        expect(link.getAttribute('href')).toBe('/lightning/r/Candidate__c/c1/view');
        expect(el.shadowRoot.textContent).toContain('Unsupported format');
        expect(el.shadowRoot.querySelector('lightning-formatted-number').value).toBe(0.8);
        expect(getRecent).toHaveBeenCalledWith({ jobRoleId: null });
    });

    it('registers uploads and polls until all rows are terminal', async () => {
        getRecent.mockResolvedValue([]);
        registerUploads.mockResolvedValue([{ documentId: 'd1', fileName: 'a.pdf', status: 'Queued' }]);
        getStatuses
            .mockResolvedValueOnce([{ documentId: 'd1', fileName: 'a.pdf', status: 'Processing' }])
            .mockResolvedValueOnce([{ documentId: 'd1', fileName: 'a.pdf', status: 'Extracted', candidateId: 'c1' }]);
        const el = create(ROLE_ID);
        await flush();

        el.shadowRoot
            .querySelector('lightning-file-upload')
            .dispatchEvent(new CustomEvent('uploadfinished', { detail: { files: [{ documentId: '069A' }, { documentId: '069B' }] } }));
        await flush();
        expect(registerUploads).toHaveBeenCalledWith({
            contentDocumentIds: ['069A', '069B'],
            jobRoleId: ROLE_ID,
            clientExtractsPdf: true
        });
        expect(el.shadowRoot.querySelector('tbody .slds-badge').textContent).toBe('Queued');

        jest.advanceTimersByTime(POLL_INTERVAL_MS);
        await flush();
        expect(getStatuses).toHaveBeenCalledWith({ documentIds: ['d1'] });
        expect(el.shadowRoot.querySelector('tbody .slds-badge').textContent).toBe('Processing');

        jest.advanceTimersByTime(POLL_INTERVAL_MS);
        await flush();
        expect(el.shadowRoot.querySelector('tbody .slds-badge').textContent).toBe('Extracted');

        jest.advanceTimersByTime(POLL_INTERVAL_MS * 3);
        await flush();
        expect(getStatuses).toHaveBeenCalledTimes(2);
    });

    it('stops polling after the time limit', async () => {
        getRecent.mockResolvedValue([{ documentId: 'd1', fileName: 'a.pdf', status: 'Processing' }]);
        getStatuses.mockResolvedValue([{ documentId: 'd1', fileName: 'a.pdf', status: 'Processing' }]);
        create();
        await flush();
        for (let t = 0; t <= POLL_MAX_MS + POLL_INTERVAL_MS * 2; t += POLL_INTERVAL_MS) {
            jest.advanceTimersByTime(POLL_INTERVAL_MS);
            // eslint-disable-next-line no-await-in-loop
            await flush();
        }
        const calls = getStatuses.mock.calls.length;
        jest.advanceTimersByTime(POLL_INTERVAL_MS * 5);
        await flush();
        expect(getStatuses.mock.calls.length).toBe(calls);
        expect(calls).toBeLessThanOrEqual(POLL_MAX_MS / POLL_INTERVAL_MS + 1);
    });

    it('clears the interval when removed', async () => {
        getRecent.mockResolvedValue([{ documentId: 'd1', fileName: 'a.pdf', status: 'Queued' }]);
        const spy = jest.spyOn(window, 'clearInterval');
        const el = create();
        await flush();
        document.body.removeChild(el);
        expect(spy).toHaveBeenCalled();
        jest.advanceTimersByTime(POLL_INTERVAL_MS * 3);
        await flush();
        expect(getStatuses).not.toHaveBeenCalled();
        spy.mockRestore();
    });

    it('shows a server error', async () => {
        getRecent.mockResolvedValue([]);
        registerUploads.mockRejectedValue({ body: { message: 'Upload at most 25 files at a time.' } });
        const el = create();
        await flush();
        el.shadowRoot
            .querySelector('lightning-file-upload')
            .dispatchEvent(new CustomEvent('uploadfinished', { detail: { files: [{ documentId: '069A' }] } }));
        await flush();
        expect(el.shadowRoot.querySelector('[role="alert"]').textContent).toContain('Upload at most 25 files');
    });
});
