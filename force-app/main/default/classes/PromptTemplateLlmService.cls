/**
 * Live implementation: resolves a Prompt Builder template and generates through
 * the Einstein Trust Layer via ConnectApi.EinsteinLLM.
 */
public with sharing class PromptTemplateLlmService implements ILlmService {
    public LlmModels.Response generate(LlmModels.Request request) {
        Long started = System.currentTimeMillis();
        Map<String, ConnectApi.WrappedValue> params = new Map<String, ConnectApi.WrappedValue>();
        for (String key : request.textInputs.keySet()) {
            params.put('Input:' + key, wrap(request.textInputs.get(key)));
        }
        if (request.fileContentDocumentId != null) {
            params.put(
                'Input:' + request.fileInputName,
                wrap(new Map<String, String>{ 'id' => String.valueOf(request.fileContentDocumentId), 'type' => 'ContentDocument' })
            );
        }
        ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.inputParams = params;
        input.isPreview = false;
        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.additionalConfig.applicationName = 'PromptTemplateGenerationsInvocable';

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation output;
        try {
            output = ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(request.templateName, input);
        } catch (Exception e) {
            throw new CvAgentException(request.templateName + ' failed: ' + e.getMessage())
                .withCode(CvAgentException.LLM_UNAVAILABLE);
        }
        if (output == null || output.generations == null || output.generations.isEmpty()) {
            throw new CvAgentException(request.templateName + ' returned no generation')
                .withCode(CvAgentException.LLM_UNAVAILABLE);
        }
        return new LlmModels.Response(request.templateName, unescape(output.generations[0].text), System.currentTimeMillis() - started);
    }

    private static ConnectApi.WrappedValue wrap(Object value) {
        ConnectApi.WrappedValue w = new ConnectApi.WrappedValue();
        w.value = value;
        return w;
    }

    /** The generation API HTML-encodes some characters (e.g. | as &#124;); quotes must match the CV text. */
    @TestVisible
    private static String unescape(String s) {
        if (s == null || !s.contains('&')) {
            return s;
        }
        return s.replace('&#124;', '|').replace('&quot;', '"').replace('&#39;', '\'').replace('&apos;', '\'')
            .replace('&lt;', '<').replace('&gt;', '>').replace('&amp;', '&');
    }
}
