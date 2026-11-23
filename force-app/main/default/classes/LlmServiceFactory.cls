/** Chooses the LLM implementation: an injected one (tests), Stub mode, or Live. */
public with sharing class LlmServiceFactory {
    @TestVisible
    private static ILlmService injected;

    public static ILlmService get() {
        if (injected != null) {
            return injected;
        }
        if (Test.isRunningTest() || CvAgentSettings.isStubMode()) {
            return new StubLlmService();
        }
        return new PromptTemplateLlmService();
    }

    @TestVisible
    private static void inject(ILlmService service) {
        injected = service;
    }
}
