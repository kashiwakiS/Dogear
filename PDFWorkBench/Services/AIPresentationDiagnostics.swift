import Foundation

@MainActor
enum AIPresentationDiagnostics {
    static func run() -> AIHighlightFoundationDiagnosticReport {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }
        do {
            var configuration = AIProviderConfiguration.default
            configuration.model = "offline-fixture"
            configuration.hasCloudConsent = true
            configuration.isCloudAIEnabled = true
            let encoded = try JSONEncoder().encode(configuration)
            let reloaded = try JSONDecoder().decode(AIProviderConfiguration.self, from: encoded)
            check(reloaded == configuration, "Current cloud consent did not survive a configuration round trip.")

            var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            legacy.removeValue(forKey: "cloudConsentVersion")
            let legacyData = try JSONSerialization.data(withJSONObject: legacy)
            let migrated = try JSONDecoder().decode(AIProviderConfiguration.self, from: legacyData)
            check(!migrated.hasCloudConsent && !migrated.isCloudAIEnabled,
                  "Old store:false consent silently authorized provider-retained conversations.")
            check(migrated.id == configuration.id && migrated.model == configuration.model
                  && migrated.baseURL == configuration.baseURL && migrated.secretStorageMode == configuration.secretStorageMode,
                  "Consent migration altered unrelated provider settings.")
            legacy["cloudConsentVersion"] = 2
            let serverOnly = try JSONDecoder().decode(AIProviderConfiguration.self,
                from: JSONSerialization.data(withJSONObject: legacy))
            check(!serverOnly.hasCloudConsent && !serverOnly.isCloudAIEnabled,
                  "Server-only consent silently authorized stateless memory replay.")
            legacy["cloudConsentVersion"] = AIProviderConfiguration.currentCloudConsentVersion + 1
            let future = try JSONDecoder().decode(AIProviderConfiguration.self,
                from: JSONSerialization.data(withJSONObject: legacy))
            check(!future.hasCloudConsent && !future.isCloudAIEnabled, "Unknown consent version was accepted.")
        } catch { check(false, "Consent fixture failed: \(error.localizedDescription)") }

        check(L10n.string("Waiting for the AI provider…", language: .simplifiedChinese) == "正在等待 AI 供应商返回结果…",
              "Provider-wait text is missing Simplified Chinese localization.")
        check(L10n.string("Turn \(2) of \(20)", language: .simplifiedChinese) == "第 2 / 20 轮",
              "Turn progress interpolation is not localized correctly.")
        check(L10n.string("Local outline", language: .simplifiedChinese) == "本地提纲",
              "Local outline label is missing Simplified Chinese localization.")
        check(L10n.string("Cloud AI conversation handling has changed. Enable it again to review and accept the updated disclosure.",
                          language: .simplifiedChinese)
              == "云端 AI 的会话处理方式已更新。请重新启用并确认更新后的说明。",
              "Updated conversation disclosure notice is missing Simplified Chinese localization.")
        check(L10n.string("Preparing credentials; check for a macOS Keychain prompt…", language: .simplifiedChinese)
              == "正在准备凭据；请留意 macOS 钥匙串授权提示…",
              "Credential preparation is missing its distinct localized waiting state.")
        check(L10n.string("Waiting for the AI provider…", language: .english) == "Waiting for the AI provider…",
              "Forced English workflow text is not English.")
        check(AIHighlightProgressPhase.phase(forToolName: AIHighlightToolName.publishAnswer) == .generatingAnswer,
              "Answer publication is incorrectly shown as provider waiting.")
        check(AIHighlightFailureMessage.kind(of: URLError(.timedOut)) == .timeout,
              "Provider timeout lost its distinct failure kind.")
        check(AIHighlightFailureMessage.userMessage(for: URLError(.timedOut))
              != AIHighlightFailureMessage.userMessage(for: URLError(.notConnectedToInternet)),
              "Timeout and connection failure have indistinguishable user messages.")
        check(AIHighlightFailureMessage.userMessage(for: AIHighlightGenerationError.noUsableNativeText)
              != AIHighlightFailureMessage.userMessage(for: AIHighlightGenerationError.documentChanged),
              "Image-only PDFs are incorrectly reported as document mutation.")
        let unsupported = OpenAICompatibleToolProviderError.serverContinuationUnsupported
        check(AIHighlightFailureMessage.kind(of: unsupported) == .providerCapabilityUnsupported,
              "Unsupported continuation was misclassified as malformed provider data.")
        check(AIHighlightFailureMessage.kind(of: AIConfigurationError.configurationChanged) == .configuration,
              "A changed credential ticket was misclassified as an unknown provider failure.")
        check(AIHighlightFailureMessage.userMessage(for: AIConfigurationError.configurationChanged)
              != AIHighlightFailureMessage.userMessage(for: unsupported),
              "Credential changes and unsupported server continuation share misleading error text.")
        check(AIHighlightFailureMessage.code(for: unsupported) == "provider_capability_unsupported",
              "Unsupported continuation does not have a stable trace error code.")
        check(AIHighlightFailureMessage.userMessage(for: unsupported)
              != AIHighlightFailureMessage.userMessage(for: AIProviderError.server(statusCode: 400, message: "ignored")),
              "Unsupported continuation has only a generic HTTP 400 message.")
        check(L10n.string("This provider does not support the server-stored conversation required by this workflow. No result was accepted.",
                          language: .simplifiedChinese)
              == "此供应商不支持当前工作流所需的服务端会话保存与续接。未接受任何结果。",
              "Unsupported continuation message is missing Simplified Chinese localization.")
        return AIHighlightFoundationDiagnosticReport(checkCount: checks, failures: failures)
    }
}
