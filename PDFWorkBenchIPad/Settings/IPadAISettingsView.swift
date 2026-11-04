#if os(iOS)
import SwiftUI

/// Platform presentation for the existing configuration/credential service.
/// Opening settings does not resolve secrets, contact a provider or load models.
@MainActor
struct IPadAISettingsView: View {
    @ObservedObject var configurationStore: AIConfigurationStore
    @ObservedObject var languageStore: AppLanguageStore
    @Environment(\.dismiss) private var dismiss
    @State private var configurationName: String
    @State private var apiKey = ""
    @State private var showsCloudConsent = false
    @State private var showsActiveKeyRemoval = false
    @State private var showsRetainedKeyRemoval = false
    @State private var localError: String?

    init(configurationStore: AIConfigurationStore, languageStore: AppLanguageStore) {
        self.configurationStore = configurationStore
        self.languageStore = languageStore
        _configurationName = State(initialValue: configurationStore.configuration.name)
    }

    var body: some View {
        NavigationStack {
            settingsForm.toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { apiKey = ""; dismiss() }
                }
            }
        }
    }

    private var settingsForm: some View {
        Form {
            Section("Interface Language") {
                Picker("Language", selection: $languageStore.selection) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            }
            Section("Retrieval") {
                LabeledContent("Retrieval Strategy", value: "Scheme 1 · BM25")
                Text("Search uses selectable PDF text and a local keyword index. Image-only pages require selectable text before they can be searched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            providerSection
            credentialSection
            Section("Privacy") {
                Toggle("Enable cloud AI", isOn: Binding(
                    get: { configurationStore.configuration.isCloudAIEnabled && hasCurrentConsent },
                    set: { enabled in setCloudAIEnabled(enabled) }
                ))
                if !hasCurrentConsent,
                   configurationStore.configuration.cloudConsentVersion != AIProviderConfiguration.currentCloudConsentVersion {
                    Text("Cloud AI conversation handling has changed. Enable it again to review and accept the updated disclosure.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(Self.cloudDisclosure).font(.caption).foregroundStyle(.secondary)
            }
            if let localError {
                Section { Text(localError).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .navigationTitle("Settings")
        .environment(\.locale, languageStore.locale)
        .alert("Enable cloud AI?", isPresented: $showsCloudConsent) {
            Button("Cancel", role: .cancel) {}
            Button("Enable") {
                // Publish the accepted contract and enabled state together.
                var accepted = configurationStore.configuration
                accepted.cloudConsentVersion = AIProviderConfiguration.currentCloudConsentVersion
                accepted.hasCloudConsent = true
                accepted.isCloudAIEnabled = true
                configurationStore.configuration = accepted
            }
        } message: {
            Text(Self.cloudDisclosure)
        }
        .confirmationDialog("Remove Key?", isPresented: $showsActiveKeyRemoval, titleVisibility: .visible) {
            Button("Remove Key", role: .destructive) {
                perform {
                    try configurationStore.removeAPIKey()
                    apiKey = ""
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the active API key for \(configurationStore.configuration.name).")
        }
        .confirmationDialog("Delete Keychain Key?", isPresented: $showsRetainedKeyRemoval, titleVisibility: .visible) {
            Button("Delete Keychain Key", role: .destructive) {
                perform { try configurationStore.deleteKeychainAPIKey() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the retained Keychain key for \(configurationStore.configuration.name). The local-file key, if any, is not changed.")
        }
        .onDisappear { apiKey = "" }
    }

    private var providerSection: some View {
        Section("OpenAI-compatible Responses API") {
            HStack {
                TextField("Configuration Name", text: $configurationName)
                Button("Apply Name") { perform { try applyNameIfNeeded() } }
                    .disabled(trimmedName.isEmpty || trimmedName == configurationStore.configuration.name)
            }
            TextField("Base URL", text: $configurationStore.configuration.baseURL)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Model", text: $configurationStore.configuration.model)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if !configurationStore.availableModels.isEmpty {
                Picker("Available Models", selection: $configurationStore.configuration.model) {
                    // Keep a manually specified model selectable even when a
                    // provider's /models response omitted it.
                    if !configurationStore.availableModels.contains(where: { $0.id == configurationStore.configuration.model }) {
                        Text(configurationStore.configuration.model).tag(configurationStore.configuration.model)
                    }
                    ForEach(configurationStore.availableModels) { model in Text(model.id).tag(model.id) }
                }
            }
            Picker("Image support for this model", selection: $configurationStore.configuration.imageCapability) {
                ForEach(AIImageCapability.allCases, id: \.self) { capability in
                    Text(L10n.string(String.LocalizationValue(capability.title), language: languageStore.selection)).tag(capability)
                }
            }
            Text("Confirm image support from your provider. This choice applies only to the current endpoint and model; changing either requires a separate declaration.")
                .font(.caption).foregroundStyle(.secondary)
            Button(configurationStore.isTestingConnection ? "Testing..." : "Test Connection") {
                perform {
                    try applyNameIfNeeded()
                    configurationStore.testConnection()
                }
            }
            .disabled(configurationStore.isTestingConnection || !configurationStore.isAPIKeyConfigured)
            Text("Test Connection contacts the configured provider with a model-list request and a short connection test. No PDF content is included.")
                .font(.caption).foregroundStyle(.secondary)
            if let status = configurationStore.connectionStatus {
                Text(L10n.string(String.LocalizationValue(status), language: languageStore.selection))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private var credentialSection: some View {
        Section("API Key") {
            SecureField("API Key", text: $apiKey)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Picker("API Key Storage", selection: Binding(
                get: { configurationStore.configuration.secretStorageMode },
                set: { mode in selectStorageMode(mode) }
            )) {
                Text("Local configuration file").tag(AISecretStorageMode.plaintextFile)
                Text(L10n.string(String.LocalizationValue(AIKeychainPlatformText.name), language: languageStore.selection))
                    .tag(AISecretStorageMode.keychain)
            }
            Button(configurationStore.isAPIKeyConfigured ? "Replace Key" : "Save Key") {
                perform {
                    try applyNameIfNeeded()
                    try configurationStore.saveAPIKey(apiKey)
                    apiKey = ""
                }
            }
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if configurationStore.isAPIKeyConfigured {
                Button("Remove Key", role: .destructive) { showsActiveKeyRemoval = true }
            }
            Text(configurationStore.isAPIKeyConfigured ? "Configured" : "Not configured")
                .font(.caption).foregroundStyle(.secondary)
            if configurationStore.configuration.secretStorageMode == .plaintextFile {
                Text("The active API key is stored as plaintext in the local configuration file, protected only by current-user file permissions (0600). Any retained Keychain key is ignored until Keychain storage is selected again.")
                    .font(.caption).foregroundStyle(.secondary)
                if configurationStore.hasKeychainAPIKey {
                    Text("A Keychain key for this configuration is retained but ignored while local-file storage is selected.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Delete Keychain Key…", role: .destructive) { showsRetainedKeyRemoval = true }
                }
            } else {
                Text("Dogear can use, replace, or remove this Keychain key, but it cannot display or export the saved secret. Selecting local-file storage leaves the Keychain key unchanged and ignores it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var trimmedName: String { configurationName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var hasCurrentConsent: Bool {
        configurationStore.configuration.hasCloudConsent
            && configurationStore.configuration.cloudConsentVersion == AIProviderConfiguration.currentCloudConsentVersion
    }

    private func setCloudAIEnabled(_ enabled: Bool) {
        if !enabled { configurationStore.configuration.isCloudAIEnabled = false }
        else if hasCurrentConsent { configurationStore.configuration.isCloudAIEnabled = true }
        else { showsCloudConsent = true }
    }

    private func applyNameIfNeeded() throws {
        if trimmedName != configurationStore.configuration.name {
            try configurationStore.updateConfigurationName(trimmedName)
            configurationName = configurationStore.configuration.name
        }
    }

    private func selectStorageMode(_ mode: AISecretStorageMode) {
        perform {
            try applyNameIfNeeded()
            try configurationStore.selectStorageMode(mode)
            apiKey = ""
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation(); localError = nil }
        catch { localError = error.localizedDescription }
    }

    private static let cloudDisclosure: LocalizedStringKey = "Research conversations and notes are saved locally. Send shares your question, bounded selected history, source excerpts from the files or Group you choose, and images you explicitly attach with the configured provider. It does not upload complete PDFs. Each request starts a new provider workflow; within that request, provider-stored responses or temporary memory replay may be used. Restoring local history never sends a request automatically. Deleting local history does not delete data retained by the provider under its own policy."
}
#endif
