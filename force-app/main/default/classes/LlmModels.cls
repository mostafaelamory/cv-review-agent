/** Request and response shapes for ILlmService. */
public with sharing class LlmModels {
    public class Request {
        public String templateName;
        /** Text inputs keyed by the template input API name, without the "Input:" prefix. */
        public Map<String, String> textInputs = new Map<String, String>();
        /** Optional file input: input API name and ContentDocument id. */
        public String fileInputName;
        public Id fileContentDocumentId;

        public Request(String templateName) {
            this.templateName = templateName;
        }
        public Request put(String inputName, String value) {
            textInputs.put(inputName, value == null ? '' : value);
            return this;
        }
        public Request withFile(String inputName, Id contentDocumentId) {
            this.fileInputName = inputName;
            this.fileContentDocumentId = contentDocumentId;
            return this;
        }
    }

    public class Response {
        public String text;
        public String templateName;
        public Long latencyMs;
        public Response(String templateName, String text, Long latencyMs) {
            this.templateName = templateName;
            this.text = text;
            this.latencyMs = latencyMs;
        }
    }
}
