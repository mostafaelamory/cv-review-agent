/**
 * Normalises text so a model's verbatim quote can be matched against the stored
 * CV text despite differences in whitespace, quotes, dashes, bullets and case.
 */
public with sharing class TextNormalizer {
    public static String loose(String s) {
        if (s == null) {
            return '';
        }
        String t = s.toLowerCase();
        t = t.replace('‘', '\'').replace('’', '\'').replace('“', '"').replace('”', '"');
        t = t.replace('–', '-').replace('—', '-').replace(' ', ' ');
        t = t.replace('ﬁ', 'fi').replace('ﬂ', 'fl');
        t = t.replaceAll('[\\u2022\\u25CF\\u25AA\\u2023\\u2043\\u00B7]', ' ');
        return t.normalizeSpace();
    }

    /** Letters and digits only; the fallback match for quotes with punctuation drift. */
    public static String alnum(String s) {
        return loose(s).replaceAll('[^\\p{L}\\p{N}]', '');
    }

    /** Lowercased words of 3+ characters, for keyword search. */
    public static List<String> keywords(String s) {
        Set<String> stop = new Set<String>{
            'the', 'and', 'for', 'with', 'who', 'what', 'which', 'has', 'have', 'does', 'did', 'any', 'are',
            'was', 'his', 'her', 'their', 'them', 'they', 'from', 'about', 'cv', 'cvs', 'candidate',
            'candidates', 'experience', 'years', 'year', 'how', 'many', 'much', 'tell', 'show', 'list', 'all'
        };
        List<String> out = new List<String>();
        for (String w : loose(s).split('[^\\p{L}\\p{N}+#.]+')) {
            w = w.removeEnd('.');
            if (w.length() >= 2 && !stop.contains(w) && !out.contains(w)) {
                out.add(w);
            }
        }
        return out;
    }
}
