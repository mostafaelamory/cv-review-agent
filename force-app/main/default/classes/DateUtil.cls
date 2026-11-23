/**
 * CV date parsing and range arithmetic. Dates in CVs are often month or year
 * only, so every parsed date keeps its precision. Ranges are counted in whole
 * months, inclusive, and overlapping ranges are merged before summing.
 */
public with sharing class DateUtil {
    public class Parsed {
        public Date value;
        public String precision; // Day, Month, Year
        public Boolean isCurrent = false;
    }

    private static final Map<String, Integer> MONTHS = new Map<String, Integer>{
        'jan' => 1, 'feb' => 2, 'mar' => 3, 'apr' => 4, 'may' => 5, 'jun' => 6,
        'jul' => 7, 'aug' => 8, 'sep' => 9, 'sept' => 9, 'oct' => 10, 'nov' => 11, 'dec' => 12
    };
    private static final Set<String> CURRENT = new Set<String>{ 'present', 'current', 'now', 'today', 'ongoing', 'to date', 'date' };

    @TestVisible
    private static Date today = Date.today();

    /** Parses a CV date. isEnd picks the last month of a year-only end date. */
    public static Parsed parse(String raw, Boolean isEnd) {
        if (String.isBlank(raw)) {
            return null;
        }
        String s = raw.trim().toLowerCase();
        Parsed p = new Parsed();
        if (CURRENT.contains(s)) {
            p.value = today;
            p.precision = 'Month';
            p.isCurrent = true;
            return p;
        }
        Matcher m;
        m = Pattern.compile('^(\\d{4})-(\\d{1,2})-(\\d{1,2})$').matcher(s);
        if (m.matches()) {
            return make(Integer.valueOf(m.group(1)), Integer.valueOf(m.group(2)), Integer.valueOf(m.group(3)), 'Day');
        }
        m = Pattern.compile('^(\\d{4})[-/.](\\d{1,2})$').matcher(s);
        if (m.matches()) {
            return make(Integer.valueOf(m.group(1)), Integer.valueOf(m.group(2)), 1, 'Month');
        }
        m = Pattern.compile('^(\\d{1,2})[-/.](\\d{4})$').matcher(s);
        if (m.matches()) {
            return make(Integer.valueOf(m.group(2)), Integer.valueOf(m.group(1)), 1, 'Month');
        }
        m = Pattern.compile('^([a-z]{3,9})\\.?,?\\s+(\\d{4})$').matcher(s);
        if (m.matches()) {
            String key = m.group(1).left(4) == 'sept' ? 'sept' : m.group(1).left(3);
            if (MONTHS.containsKey(key)) {
                return make(Integer.valueOf(m.group(2)), MONTHS.get(key), 1, 'Month');
            }
        }
        m = Pattern.compile('^(\\d{4})$').matcher(s);
        if (m.matches()) {
            return make(Integer.valueOf(m.group(1)), isEnd ? 12 : 1, 1, 'Year');
        }
        return null;
    }

    private static Parsed make(Integer y, Integer mo, Integer d, String precision) {
        if (y < 1950 || y > today.year() + 1 || mo < 1 || mo > 12) {
            return null;
        }
        Parsed p = new Parsed();
        p.value = Date.newInstance(y, mo, Math.min(d, Date.daysInMonth(y, mo)));
        p.precision = precision;
        return p;
    }

    /** Month index used for range arithmetic. */
    public static Integer monthIndex(Date d) {
        return d.year() * 12 + d.month() - 1;
    }

    /** Inclusive months covered by a list of [start, end] ranges, overlaps counted once. */
    public static Integer mergedMonths(List<List<Date>> ranges) {
        List<List<Integer>> spans = new List<List<Integer>>();
        for (List<Date> r : ranges) {
            if (r[0] != null && r[1] != null && r[1] >= r[0]) {
                spans.add(new List<Integer>{ monthIndex(r[0]), monthIndex(r[1]) });
            }
        }
        // Insertion sort by start; lists are short.
        for (Integer i = 1; i < spans.size(); i++) {
            List<Integer> cur = spans[i];
            Integer j = i - 1;
            while (j >= 0 && spans[j][0] > cur[0]) {
                spans[j + 1] = spans[j];
                j--;
            }
            spans[j + 1] = cur;
        }
        Integer total = 0;
        Integer curStart;
        Integer curEnd;
        for (List<Integer> s : spans) {
            if (curStart == null) {
                curStart = s[0];
                curEnd = s[1];
            } else if (s[0] <= curEnd + 1) {
                curEnd = Math.max(curEnd, s[1]);
            } else {
                total += curEnd - curStart + 1;
                curStart = s[0];
                curEnd = s[1];
            }
        }
        if (curStart != null) {
            total += curEnd - curStart + 1;
        }
        return total;
    }

    /** Months two inclusive ranges share; 0 when they don't overlap. */
    public static Integer overlapMonths(Date s1, Date e1, Date s2, Date e2) {
        if (s1 == null || e1 == null || s2 == null || e2 == null) {
            return 0;
        }
        Integer start = Math.max(monthIndex(s1), monthIndex(s2));
        Integer stop = Math.min(monthIndex(e1), monthIndex(e2));
        return Math.max(0, stop - start + 1);
    }

    public static String formatMonths(Integer months) {
        if (months == null) {
            return null;
        }
        Integer y = months / 12;
        Integer m = Math.mod(months, 12);
        String out = '';
        if (y > 0) {
            out = y + (y == 1 ? ' year' : ' years');
        }
        if (m > 0) {
            out += (out == '' ? '' : ' ') + m + (m == 1 ? ' month' : ' months');
        }
        return out == '' ? '0 months' : out;
    }
}
