import SwiftUI

struct AISettingsView: View {
    @ObservedObject var configurationStore: AIConfigurationStore
    @ObservedObject var languageStore: AppLanguageStore
    @State private var apiKey = ""
    @State private var configurationName: String
    @State private var isShowingConsent = false
    @State private var isShowingKeychainDeleteConfirmation = false
    @State private var localError: String?

    init(
        configurationStore: AIConfigurationStore,
        languageStore: AppLanguageStore
    ) {
        self.configurationStore = configurationStore
        self.languageStore = languageStore
        _configurationName = State(initialValue: configurationStore.configuration.name)
    }

    var body: some View {
        Form {
            Section("Interface Language") {
                Picker("Language", selection: $languageStore.selection) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }

                Text("This setting changes only Dogear and is intended to make localization testing easy. It does not change the macOS system language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OpenAI-compatible Responses API") {
                HStack {
                    TextField("Configuration Name", text: $configurationName)
                        .textFieldStyle(.roundedBorder)
                    Button("Apply Name") {
                        applyConfigurationName()
                    }
                    .disabled(
                        configurationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || configurationName.trimmingCharacters(in: .whitespacesAndNewlines)
                                == configurationStore.configuration.name
                    )
                }

                Toggle(
                    "Enable cloud AI",
                    isOn: Binding(
                        get: { configurationStore.configuration.isCloudAIEnabled },
                        set: setCloudAIEnabled
                    )
                )

                TextField(
                    "Base URL",
                    text: Binding(
                        get: { configurationStore.configuration.baseURL },
                        set: { configurationStore.configuration.baseURL = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)

                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                Picker(
                    "API Key Storage",
                    selection: Binding(
                        get: { configurationStore.configuration.secretStorageMode },
                        set: changeStorageMode
                    )
                ) {
                    ForEach(AISecretStorageMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Button(configurationStore.isAPIKeyConfigured ? "Replace Key" : "Save Key") {
                        saveAPIKey()
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if configurationStore.isAPIKeyConfigured {
                        Button("Remove Key", role: .destructive) {
                            removeAPIKey()
                        }
                    }

                    Text(storageStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if configurationStore.configuration.secretStorageMode == .plaintextFile {
                    Text(configurationStore.configurationURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    if configurationStore.hasKeychainAPIKey {
                        HStack {
                            Text("A Keychain key for this configuration is retained but ignored while local-file storage is selected.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button("Delete Keychain Key…", role: .destructive) {
                                isShowingKeychainDeleteConfirmation = true
                            }
                        }
                    }
                } else {
                    Text("Dogear can use, replace, or remove this Keychain key, but it cannot display or export the saved secret. Selecting local-file storage leaves the Keychain key unchanged and ignores it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if configurationStore.availableModels.isEmpty {
                    TextField(
                        "Model",
                        text: Binding(
                            get: { configurationStore.configuration.model },
                            set: { configurationStore.configuration.model = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                } else {
                    Picker(
                        "Model",
                        selection: Binding(
                            get: { configurationStore.configuration.model },
                            set: { configurationStore.configuration.model = $0 }
                        )
                    ) {
                        ForEach(configurationStore.availableModels) { model in
                            Text(model.id).tag(model.id)
                        }
                    }
                }

                Button(configurationStore.isTestingConnection ? "Testing..." : "Test Connection") {
                    configurationStore.testConnection()
                }
                .disabled(configurationStore.isTestingConnection || !configurationStore.isAPIKeyConfigured)

                if let status = configurationStore.connectionStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if let localError {
                    Text(localError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Privacy") {
                Text(privacyDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 580, height: 680)
        .alert("Enable cloud AI?", isPresented: $isShowingConsent) {
            Button("Cancel", role: .cancel) {}
            Button("Enable") {
                configurationStore.configuration.hasCloudConsent = true
                configurationStore.configuration.isCloudAIEnabled = true
            }
        } message: {
            Text("When you confirm a document summary, the complete PDF will be uploaded to the configured provider. Selection questions send the displayed selection and conversation instead.")
        }
        .confirmationDialog(
            "Delete Keychain Key?",
            isPresented: $isShowingKeychainDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Keychain Key", role: .destructive) {
                deleteKeychainAPIKey()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the retained Keychain key for \(configurationStore.configuration.name). The local-file key, if any, is not changed.")
        }
    }

    private func setCloudAIEnabled(_ enabled: Bool) {
        if !enabled {
            configurationStore.configuration.isCloudAIEnabled = false
        } else if configurationStore.configuration.hasCloudConsent {
            configurationStore.configuration.isCloudAIEnabled = true
        } else {
            isShowingConsent = true
        }
    }

    private func saveAPIKey() {
        do {
            try applyConfigurationNameIfNeeded()
            try configurationStore.saveAPIKey(apiKey)
            apiKey = ""
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }

    private func removeAPIKey() {
        do {
            try configurationStore.removeAPIKey()
            apiKey = ""
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }

    private var storageStatus: String {
        guard configurationStore.isAPIKeyConfigured else {
            if configurationStore.configuration.secretStorageMode == .plaintextFile,
               configurationStore.hasKeychainAPIKey {
                return "No local key · Keychain key retained (ignored)"
            }
            return "Not configured"
        }
        return configurationStore.configuration.secretStorageMode == .keychain
            ? "Stored in Keychain as Dogear — \(configurationStore.configuration.name)"
            : "Stored in local config"
    }

    private var privacyDescription: String {
        let storageDescription = configurationStore.configuration.secretStorageMode == .keychain
            ? "The API key is stored in macOS Keychain and cannot be displayed or exported by Dogear."
            : "The active API key is stored as plaintext in the local configuration file, protected only by current-user file permissions (0600). Any retained Keychain key is ignored until Keychain storage is selected again."
        return "Document summaries upload the complete PDF after you review and confirm the request. Selection questions send only the displayed selection and conversation. \(storageDescription) The app requests that compatible providers do not store Responses API results."
    }

    private func applyConfigurationName() {
        do {
            try applyConfigurationNameIfNeeded()
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }

    private func applyConfigurationNameIfNeeded() throws {
        let trimmed = configurationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != configurationStore.configuration.name {
            try configurationStore.updateConfigurationName(trimmed)
            configurationName = configurationStore.configuration.name
        }
    }

    private func changeStorageMode(_ mode: AISecretStorageMode) {
        do {
            try applyConfigurationNameIfNeeded()
            try configurationStore.selectStorageMode(mode)
            apiKey = ""
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }

    private func deleteKeychainAPIKey() {
        do {
            try configurationStore.deleteKeychainAPIKey()
            localError = nil
        } catch {
            localError = "The Keychain key was not deleted: \(error.localizedDescription)"
        }
    }
}
