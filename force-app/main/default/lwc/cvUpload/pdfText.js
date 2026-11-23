/**
 * Reads the text layer of a PDF in the browser with pdf.js (static resource
 * "pdfjs"). Returns one string per page. A scanned PDF returns empty pages; the
 * server then falls back to model transcription.
 */
import { loadScript } from 'lightning/platformResourceLoader';
import PDFJS from '@salesforce/resourceUrl/pdfjs';

let loading;

function load(component) {
    if (!loading) {
        loading = loadScript(component, PDFJS + '/pdf.min.js').then(() => {
            // eslint-disable-next-line no-undef
            const lib = window.pdfjsLib;
            lib.GlobalWorkerOptions.workerSrc = PDFJS + '/pdf.worker.min.js';
            return lib;
        });
        loading.catch(() => {
            loading = undefined;
        });
    }
    return loading;
}

function base64ToBytes(b64) {
    const bin = atob(b64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return bytes;
}

/** Joins text items into lines: a new line on hasEOL or when the baseline moves. */
export function itemsToText(items) {
    let out = '';
    let lastY;
    for (const item of items) {
        const y = item.transform ? item.transform[5] : undefined;
        if (lastY !== undefined && y !== undefined && Math.abs(y - lastY) > 2 && !out.endsWith('\n')) {
            out += '\n';
        }
        out += item.str || '';
        if (item.hasEOL) out += '\n';
        if (y !== undefined) lastY = y;
    }
    return out.replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
}

export async function extractPdfPages(component, base64) {
    const lib = await load(component);
    const pdf = await lib.getDocument({ data: base64ToBytes(base64), isEvalSupported: false }).promise;
    const pages = [];
    for (let n = 1; n <= Math.min(pdf.numPages, 20); n++) {
        // eslint-disable-next-line no-await-in-loop
        const page = await pdf.getPage(n);
        // eslint-disable-next-line no-await-in-loop
        const content = await page.getTextContent();
        pages.push(itemsToText(content.items));
    }
    return pages;
}
