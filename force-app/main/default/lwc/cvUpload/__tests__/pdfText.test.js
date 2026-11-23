jest.mock('lightning/platformResourceLoader', () => ({ loadScript: jest.fn() }), { virtual: true });
jest.mock('@salesforce/resourceUrl/pdfjs', () => ({ default: '/resource/pdfjs' }), { virtual: true });
import { itemsToText } from '../pdfText';

describe('itemsToText', () => {
    it('breaks lines on hasEOL and on baseline changes', () => {
        const items = [
            { str: 'Sara Ahmed', transform: [1, 0, 0, 1, 50, 800], hasEOL: true },
            { str: 'Apex,', transform: [1, 0, 0, 1, 50, 780] },
            { str: ' LWC', transform: [1, 0, 0, 1, 80, 780] },
            { str: 'Cairo', transform: [1, 0, 0, 1, 50, 760] }
        ];
        expect(itemsToText(items)).toBe('Sara Ahmed\nApex, LWC\nCairo');
    });

    it('returns empty text for a scanned page', () => {
        expect(itemsToText([])).toBe('');
    });
});
