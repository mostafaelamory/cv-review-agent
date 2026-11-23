/**
 * Domain exception for the CV Review Agent. `code` drives the error taxonomy
 * used in decision logs and retry decisions.
 */
public with sharing class CvAgentException extends Exception {
    public static final String UNSUPPORTED_FORMAT = 'UNSUPPORTED_FORMAT';
    public static final String UNREADABLE = 'UNREADABLE';
    public static final String INVALID_JSON = 'INVALID_JSON';
    public static final String LLM_UNAVAILABLE = 'LLM_UNAVAILABLE';
    public static final String NOT_FOUND = 'NOT_FOUND';
    public static final String ACCESS = 'ACCESS';

    public String code = 'ERROR';

    public CvAgentException withCode(String code) {
        this.code = code;
        return this;
    }

    /** Rate limits and timeouts are worth a delayed retry; everything else is not. */
    public Boolean isRetryable() {
        return code == LLM_UNAVAILABLE;
    }
}
