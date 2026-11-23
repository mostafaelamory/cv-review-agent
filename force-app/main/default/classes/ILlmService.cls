/**
 * Every model call goes through this interface: production uses Prompt Builder
 * templates (and so the Einstein Trust Layer); tests and offline use go through a stub.
 */
public interface ILlmService {
    LlmModels.Response generate(LlmModels.Request request);
}
