/** Helpers for reading model output that should be JSON. */
public with sharing class JsonUtil {
    /**
     * Returns the outermost JSON object in a model response, dropping code fences
     * and any prose around it. Throws INVALID_JSON when none can be parsed.
     */
    public static Map<String, Object> parseObject(String raw) {
        if (String.isBlank(raw)) {
            throw new CvAgentException('Empty model response').withCode(CvAgentException.INVALID_JSON);
        }
        Integer startIdx = raw.indexOf('{');
        Integer endIdx = raw.lastIndexOf('}');
        if (startIdx < 0 || endIdx <= startIdx) {
            throw new CvAgentException('No JSON object in model response').withCode(CvAgentException.INVALID_JSON);
        }
        try {
            Object parsed = JSON.deserializeUntyped(raw.substring(startIdx, endIdx + 1));
            return (Map<String, Object>) parsed;
        } catch (Exception e) {
            throw new CvAgentException('Model response is not valid JSON: ' + e.getMessage())
                .withCode(CvAgentException.INVALID_JSON);
        }
    }

    public static String str(Map<String, Object> m, String key) {
        if (m == null || !m.containsKey(key) || m.get(key) == null) {
            return null;
        }
        String s = String.valueOf(m.get(key)).trim();
        return String.isBlank(s) || s.equalsIgnoreCase('null') ? null : s;
    }

    public static List<Object> arr(Map<String, Object> m, String key) {
        if (m == null || !(m.get(key) instanceof List<Object>)) {
            return new List<Object>();
        }
        return (List<Object>) m.get(key);
    }

    public static Map<String, Object> obj(Object o) {
        return o instanceof Map<String, Object> ? (Map<String, Object>) o : new Map<String, Object>();
    }

    public static List<String> strings(Map<String, Object> m, String key) {
        List<String> out = new List<String>();
        for (Object o : arr(m, key)) {
            if (o != null && String.isNotBlank(String.valueOf(o))) {
                out.add(String.valueOf(o).trim());
            }
        }
        return out;
    }

    public static Decimal num(Map<String, Object> m, String key) {
        String s = str(m, key);
        if (s == null) {
            return null;
        }
        try {
            return Decimal.valueOf(s.replaceAll('[^0-9.\\-]', ''));
        } catch (Exception e) {
            return null;
        }
    }

    public static String truncate(String s, Integer max) {
        if (s == null || s.length() <= max) {
            return s;
        }
        return s.substring(0, Math.max(0, max - 1)) + '…';
    }
}
