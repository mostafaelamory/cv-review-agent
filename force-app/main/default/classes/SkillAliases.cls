/** Skill aliases from CV_Skill_Alias__mdt (SFDC = Salesforce), for matching across CV styles. */
public with sharing class SkillAliases {
    private static Map<String, String> cache;

    public static Map<String, String> all() {
        if (cache == null) {
            cache = new Map<String, String>();
            for (CV_Skill_Alias__mdt a : CV_Skill_Alias__mdt.getAll().values()) {
                if (a.Alias__c != null && a.Canonical__c != null) {
                    cache.put(a.Alias__c.toLowerCase(), a.Canonical__c);
                }
            }
        }
        return cache;
    }

    public static String asPromptText() {
        List<String> pairs = new List<String>();
        for (String alias : all().keySet()) {
            pairs.add(alias.toUpperCase() + ' = ' + all().get(alias));
        }
        pairs.sort();
        return pairs.isEmpty() ? '(none)' : String.join(pairs, '; ');
    }

    /** Appends canonical names for aliases that appear as whole words. */
    public static String expand(String lowerText) {
        String out = lowerText;
        for (String alias : all().keySet()) {
            if (Pattern.compile('(^|[^a-z0-9])' + Pattern.quote(alias) + '([^a-z0-9]|$)').matcher(lowerText).find()) {
                out += ' ' + all().get(alias).toLowerCase();
            }
        }
        return out;
    }

    /** Adds aliases and canonical forms of each keyword, for search. */
    public static List<String> expandKeywords(List<String> keywords) {
        List<String> out = new List<String>(keywords);
        for (String k : keywords) {
            String lower = k.toLowerCase();
            if (all().containsKey(lower) && !out.contains(all().get(lower).toLowerCase())) {
                out.add(all().get(lower).toLowerCase());
            }
            for (String alias : all().keySet()) {
                if (all().get(alias).toLowerCase() == lower && !out.contains(alias)) {
                    out.add(alias);
                }
            }
        }
        return out;
    }
}
