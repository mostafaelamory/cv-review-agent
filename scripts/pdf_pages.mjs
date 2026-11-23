// Extracts PDF text per page exactly as the cvUpload component does (pdf.js 3.11.174).
// Usage: node scripts/pdf_pages.mjs <node_modules dir with pdfjs-dist> file.pdf ... (writes $OUT, default pages.json)
import { createRequire } from 'module';
import fs from 'fs';
const require = createRequire(process.argv[2] + '/');
const pdfjs = require('pdfjs-dist/legacy/build/pdf.js');

function itemsToText(items) {
    let out = '';
    let lastY;
    for (const item of items) {
        const y = item.transform ? item.transform[5] : undefined;
        if (lastY !== undefined && y !== undefined && Math.abs(y - lastY) > 2 && !out.endsWith('\n')) out += '\n';
        out += item.str || '';
        if (item.hasEOL) out += '\n';
        if (y !== undefined) lastY = y;
    }
    return out.replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
}

const result = {};
for (const file of process.argv.slice(3)) {
    const pdf = await pdfjs.getDocument({ data: new Uint8Array(fs.readFileSync(file)), isEvalSupported: false }).promise;
    const pages = [];
    for (let n = 1; n <= Math.min(pdf.numPages, 20); n++) {
        const page = await pdf.getPage(n);
        pages.push(itemsToText((await page.getTextContent()).items));
    }
    result[file.split('/').pop()] = pages;
}
fs.writeFileSync(process.env.OUT || "pages.json", JSON.stringify(result));
