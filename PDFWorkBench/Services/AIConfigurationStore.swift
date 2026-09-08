import Combine
import Foundation
import Security

protocol AISecretStoring {
    func readSecret(profileID: UUID) throws -> String?
    func saveSecret(_ secret: String, profileID: UUID, configurationName: String) throws
    func removeSecret(profileID: UUID) throws
    func updateLabel(profileID: UUID, configurationName: String) throws
}

struct KeychainAISecretStore: AISecretStoring {
    private let service = "com.KashiwakiS.PDFWorkBench.ai-credentials"

    func readSecret(profileID: UUID) throws -> String? {
        try KeychainAISecretReader().readSecret(profileID: profileID)
    }

    func saveSecret(
        _ secret: String,
        profileID: UUID,
        configurationName: String
    ) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(secret.utf8),
            kSecAttrLabel as String: label(configurationName: configurationName),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(
            baseQuery(profileID: profileID) as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }

        var query = baseQuery(profileID: profileID)
        attributes.forEach { query[$0.key] = $0.value }
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }

    func removeSecret(profileID: UUID) throws {
        let status = SecItemDelete(baseQuery(profileID: profileID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    func updateLabel(profileID: UUID, configurationName: String) throws {
        let status = SecItemUpdate(
            baseQuery(profileID: profileID) as CFDictionary,
            [kSecAttrLabel as String: label(configurationName: configurationName)] as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(profileID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString
        ]
    }

    private func label(configurationName: String) -> String {
        "Dogear — \(configurationName)"
    }

    private struct KeychainError: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain error \(status)."
        }
    }
}

enum AIConfigurationError: LocalizedError, Equatable {
    case invalidConfigurationName
    case keychainVerificationFailed
    case configurationChanged
    case cloudAIUnavailable
    case asynchronousCredentialReaderUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfigurationName:
            return "Enter a configuration name first."
        case .keychainVerificationFailed:
            return "The key was written to Keychain but could not be verified. The plaintext configuration was kept."
        case .configurationChanged:
            return "The AI configuration or credential changed while this request was preparing. Send the request again."
        case .cloudAIUnavailable:
            return "Cloud AI is disabled or its current data-sharing terms have not been accepted."
        case .asynchronousCredentialReaderUnavailable:
            return "The AI configuration has no asynchronous credential reader."
        }
    }
}

/// Captured at Send, before PDF preparation. It contains no secret and cannot
/// become a credential cache; an edited key invalidates it even if config is equal.
struct AIProviderRequestTicket: Equatable {
    let configuration: AIProviderConfiguration
    fileprivate let credentialRevision: UInt64
}

@MainActor
final class AIConfigurationStore: ObservableObject {
    static let shared = AIConfigurationStore()

    @Published var configuration: AIProviderConfiguration {
        didSet {
            if configuration != oldValue { credentialRevision &+= 1 }
            guard !isApplyingTransaction else { return }
            do {
                try persistConfiguration()
            } catch {
                connectionStatus = error.localizedDescription
            }
        }
    }
    @Published private(set) var availableModels: [AIModelDescriptor] = []
    @Published private(set) var isAPIKeyConfigured = false
    @Published private(set) var hasKeychainAPIKey = false
    @Published private(set) var isTestingConnection = false
    @Published private(set) var connectionStatus: String?

    let configurationURL: URL

    private var plaintextAPIKey: String
    private let secretStore: AISecretStoring
    private let backgroundSecretReader: AIBackgroundSecretReader?
    private var credentialRevision: UInt64 = 0
    private let legacyConfigurationKey = "PDFWorkBench.AIProviderConfiguration"
    private var isApplyingTransaction = false

    convenience init() {
        self.init(
            configurationURL: Self.defaultConfigurationURL,
            legacyUserDefaults: .standard,
            secretStore: KeychainAISecretStore(),
            secretReader: KeychainAISecretReader()
        )
    }

    init(
        configurationURL: URL,
        legacyUserDefaults: UserDefaults = .standard,
        secretStore: AISecretStoring,
        secretReader: (any AISecretReading)? = nil
    ) {
        self.configurationURL = configurationURL
        self.secretStore = secretStore
        backgroundSecretReader = secretReader.map { AIBackgroundSecretReader(reader: $0) }

        if let data = try? Data(contentsOf: configurationURL),
           let stored = try? JSONDecoder().decode(StoredAIConfiguration.self, from: data) {
            configuration = stored.provider
            plaintextAPIKey = stored.apiKey
            if stored.provider.secretStorageMode == .plaintextFile {
                isAPIKeyConfigured = !stored.apiKey.isEmpty
            } else {
                isAPIKeyConfigured = stored.hasStoredKeychainAPIKey
            }
            hasKeychainAPIKey = stored.hasStoredKeychainAPIKey
        } else if let data = legacyUserDefaults.data(forKey: legacyConfigurationKey),
                  let legacy = try? JSONDecoder().decode(AIProviderConfiguration.self, from: data) {
            configuration = legacy
            plaintextAPIKey = ""
            isAPIKeyConfigured = false
            hasKeychainAPIKey = false
        } else {
            configuration = .default
            plaintextAPIKey = ""
            isAPIKeyConfigured = false
            hasKeychainAPIKey = false
        }
    }

    func updateConfigurationName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AIConfigurationError.invalidConfigurationName
        }
        guard trimmed != configuration.name else { return }

        let previous = configuration
        if hasKeychainAPIKey {
            try secretStore.updateLabel(
                profileID: configuration.id,
                configurationName: trimmed
            )
        }

        var updated = configuration
        updated.name = trimmed
        do {
            try applyConfigurationTransaction(updated)
            connectionStatus = "Configuration name updated."
        } catch {
            if hasKeychainAPIKey {
                try? secretStore.updateLabel(
                    profileID: previous.id,
                    configurationName: previous.name
                )
            }
            throw error
        }
    }

    func selectStorageMode(_ mode: AISecretStorageMode) throws {
        guard mode != configuration.secretStorageMode else { return }

        switch mode {
        case .keychain:
            if hasKeychainAPIKey {
                var updated = configuration
                updated.secretStorageMode = .keychain
                try applyConfigurationTransaction(updated, configuredState: true)
                connectionStatus = plaintextAPIKey.isEmpty
                    ? "Saved Keychain storage selected."
                    : "Keychain storage selected. The separate local-file key is retained and ignored."
            } else {
                try migratePlaintextKeyToKeychain()
            }
        case .plaintextFile:
            var updated = configuration
            updated.secretStorageMode = .plaintextFile
            try applyConfigurationTransaction(
                updated,
                configuredState: !plaintextAPIKey.isEmpty
            )
            connectionStatus = hasKeychainAPIKey
                ? "Local-file storage selected. The saved Keychain key is retained and ignored."
                : "New keys will be stored in the local configuration file."
        }
    }

    func saveAPIKey(_ apiKey: String) throws {
        credentialRevision &+= 1
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try removeAPIKey()
            return
        }

        switch configuration.secretStorageMode {
        case .plaintextFile:
            let previousKey = plaintextAPIKey
            plaintextAPIKey = trimmed
            isAPIKeyConfigured = true
            do {
                try persistConfiguration()
                connectionStatus = "API key saved in the local configuration file."
            } catch {
                plaintextAPIKey = previousKey
                isAPIKeyConfigured = !previousKey.isEmpty
                throw error
            }
        case .keychain:
            try secretStore.saveSecret(
                trimmed,
                profileID: configuration.id,
                configurationName: configuration.name
            )
            guard try secretStore.readSecret(profileID: configuration.id) == trimmed else {
                throw AIConfigurationError.keychainVerificationFailed
            }
            hasKeychainAPIKey = true
            isAPIKeyConfigured = true
            try persistConfiguration()
            connectionStatus = "API key saved in macOS Keychain."
        }
    }

    func removeAPIKey() throws {
        credentialRevision &+= 1
        switch configuration.secretStorageMode {
        case .plaintextFile:
            let previousKey = plaintextAPIKey
            plaintextAPIKey = ""
            isAPIKeyConfigured = false
            do {
                try persistConfiguration()
            } catch {
                plaintextAPIKey = previousKey
                isAPIKeyConfigured = !previousKey.isEmpty
                throw error
            }
        case .keychain:
            try secretStore.removeSecret(profileID: configuration.id)
            hasKeychainAPIKey = false
            isAPIKeyConfigured = false
            try persistConfiguration()
        }
        connectionStatus = "API key removed from \(configuration.secretStorageMode.displayName)."
    }

    func deleteKeychainAPIKey() throws {
        credentialRevision &+= 1
        try secretStore.removeSecret(profileID: configuration.id)
        hasKeychainAPIKey = false
        if configuration.secretStorageMode == .keychain {
            isAPIKeyConfigured = false
        }
        try persistConfiguration()
        connectionStatus = "Keychain API key deleted."
    }

    func provider() throws -> OpenAICompatibleResponsesProvider {
        try OpenAICompatibleResponsesProvider(
            configuration: configuration,
            apiKey: resolvedAPIKey()
        )
    }

    func toolCallingProvider() throws -> OpenAICompatibleToolCallingProvider {
        try OpenAICompatibleToolCallingProvider(
            configuration: configuration,
            apiKey: resolvedAPIKey()
        )
    }

    func captureProviderRequest() -> AIProviderRequestTicket {
        AIProviderRequestTicket(configuration: configuration, credentialRevision: credentialRevision)
    }

    func toolCallingProvider(
        for ticket: AIProviderRequestTicket
    ) async throws -> OpenAICompatibleToolCallingProvider {
        let key = try await resolvedAPIKey(for: ticket, requiresCloudConsent: true)
        try validate(ticket, requiresCloudConsent: true)
        return try OpenAICompatibleToolCallingProvider(configuration: ticket.configuration, apiKey: key)
    }

    /// Compatibility overload. Callers that prepare PDFs first must capture and
    /// pass a ticket at Send so same-configuration key edits are also detected.
    func toolCallingProvider(
        for expectedConfiguration: AIProviderConfiguration
    ) async throws -> OpenAICompatibleToolCallingProvider {
        guard configuration == expectedConfiguration else {
            throw AIConfigurationError.configurationChanged
        }
        return try await toolCallingProvider(for: captureProviderRequest())
    }

    func provider(
        for ticket: AIProviderRequestTicket
    ) async throws -> OpenAICompatibleResponsesProvider {
        let key = try await resolvedAPIKey(for: ticket, requiresCloudConsent: false)
        try validate(ticket, requiresCloudConsent: false)
        return try OpenAICompatibleResponsesProvider(configuration: ticket.configuration, apiKey: key)
    }

    private func validate(_ ticket: AIProviderRequestTicket, requiresCloudConsent: Bool) throws {
        try Task.checkCancellation()
        guard ticket.configuration == configuration,
              ticket.credentialRevision == credentialRevision
        else { throw AIConfigurationError.configurationChanged }
        if requiresCloudConsent {
            guard configuration.isCloudAIEnabled, configuration.hasCloudConsent,
                  configuration.cloudConsentVersion == AIProviderConfiguration.currentCloudConsentVersion
            else { throw AIConfigurationError.cloudAIUnavailable }
        }
    }

    private func resolvedAPIKey(
        for ticket: AIProviderRequestTicket,
        requiresCloudConsent: Bool
    ) async throws -> String {
        try validate(ticket, requiresCloudConsent: requiresCloudConsent)
        let key: String?
        switch ticket.configuration.secretStorageMode {
        case .plaintextFile:
            key = plaintextAPIKey
        case .keychain:
            guard let backgroundSecretReader else {
                throw AIConfigurationError.asynchronousCredentialReaderUnavailable
            }
            key = try await backgroundSecretReader.readSecret(profileID: ticket.configuration.id)
        }
        // In particular, an old nil result must not mark a newly selected
        // profile/key as missing. Never write a late secret into global state.
        try validate(ticket, requiresCloudConsent: requiresCloudConsent)
        guard let key, !key.isEmpty else {
            if ticket.configuration.secretStorageMode == .keychain {
                hasKeychainAPIKey = false
                isAPIKeyConfigured = false
                try? persistConfiguration()
            }
            throw AIProviderError.missingAPIKey
        }
        return key
    }

    private func resolvedAPIKey() throws -> String {
        let key: String
        switch configuration.secretStorageMode {
        case .plaintextFile:
            key = plaintextAPIKey
        case .keychain:
            if let storedKey = try secretStore.readSecret(profileID: configuration.id),
                      !storedKey.isEmpty {
                key = storedKey
            } else {
                hasKeychainAPIKey = false
                isAPIKeyConfigured = false
                try? persistConfiguration()
                throw AIProviderError.missingAPIKey
            }
        }

        guard !key.isEmpty else {
            throw AIProviderError.missingAPIKey
        }
        return key
    }

    func testConnection() {
        guard !isTestingConnection else { return }
        isTestingConnection = true
        connectionStatus = "Testing model list and Responses API..."

        Task {
            defer { isTestingConnection = false }
            do {
                let initialTicket = captureProviderRequest()
                let modelProvider = try await provider(for: initialTicket)
                let models = try await modelProvider.listModels()
                try validate(initialTicket, requiresCloudConsent: false)
                availableModels = models
                if configuration.model.isEmpty {
                    if let preferred = models.first(where: { $0.id.localizedCaseInsensitiveContains("flash") }) {
                        configuration.model = preferred.id
                    } else if let first = models.first {
                        configuration.model = first.id
                    }
                }

                let testTicket = captureProviderRequest()
                let testedProvider = try await provider(for: testTicket)
                _ = try await testedProvider.respond(
                    to: AIResponseRequest(
                        instructions: "Return only the word OK.",
                        input: "Connection test"
                    )
                )
                try validate(testTicket, requiresCloudConsent: false)
                connectionStatus = "Connected. Models and /responses are available."
            } catch {
                connectionStatus = error.localizedDescription
            }
        }
    }

    private func migratePlaintextKeyToKeychain() throws {
        credentialRevision &+= 1
        let key = plaintextAPIKey
        if !key.isEmpty {
            try secretStore.saveSecret(
                key,
                profileID: configuration.id,
                configurationName: configuration.name
            )
            guard try secretStore.readSecret(profileID: configuration.id) == key else {
                throw AIConfigurationError.keychainVerificationFailed
            }
        }

        let previousConfiguration = configuration
        let previousKey = plaintextAPIKey
        let previousConfiguredState = isAPIKeyConfigured
        let previousKeychainState = hasKeychainAPIKey
        var updated = configuration
        updated.secretStorageMode = .keychain

        isApplyingTransaction = true
        configuration = updated
        plaintextAPIKey = ""
        if !key.isEmpty {
            hasKeychainAPIKey = true
        }
        isAPIKeyConfigured = hasKeychainAPIKey
        isApplyingTransaction = false

        do {
            try persistConfiguration()
            connectionStatus = key.isEmpty
                ? (hasKeychainAPIKey
                    ? "Saved Keychain storage selected."
                    : "New keys will be stored in macOS Keychain.")
                : "API key moved from the local configuration file to macOS Keychain."
        } catch {
            isApplyingTransaction = true
            configuration = previousConfiguration
            plaintextAPIKey = previousKey
            isAPIKeyConfigured = previousConfiguredState
            hasKeychainAPIKey = previousKeychainState
            isApplyingTransaction = false
            throw error
        }
    }

    private func applyConfigurationTransaction(
        _ updated: AIProviderConfiguration,
        configuredState: Bool? = nil
    ) throws {
        let previous = configuration
        let previousConfiguredState = isAPIKeyConfigured
        isApplyingTransaction = true
        configuration = updated
        if let configuredState {
            isAPIKeyConfigured = configuredState
        }
        isApplyingTransaction = false
        do {
            try persistConfiguration()
        } catch {
            isApplyingTransaction = true
            configuration = previous
            isAPIKeyConfigured = previousConfiguredState
            isApplyingTransaction = false
            throw error
        }
    }

    private func persistConfiguration() throws {
        let directory = configurationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(
            StoredAIConfiguration(
                provider: configuration,
                apiKey: plaintextAPIKey,
                hasStoredKeychainAPIKey: hasKeychainAPIKey
            )
        )
        try data.write(to: configurationURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configurationURL.path
        )
    }

    private static var defaultConfigurationURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDFWorkBench", isDirectory: true)
            .appendingPathComponent("ai-configuration.json", isDirectory: false)
    }

    private struct StoredAIConfiguration: Codable {
        let provider: AIProviderConfiguration
        let apiKey: String
        let hasStoredKeychainAPIKey: Bool

        private enum CodingKeys: String, CodingKey {
            case provider
            case apiKey
            case hasStoredKeychainAPIKey
            case hasStoredAPIKey
        }

        init(
            provider: AIProviderConfiguration,
            apiKey: String,
            hasStoredKeychainAPIKey: Bool
        ) {
            self.provider = provider
            self.apiKey = apiKey
            self.hasStoredKeychainAPIKey = hasStoredKeychainAPIKey
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            provider = try container.decode(AIProviderConfiguration.self, forKey: .provider)
            apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
            let legacyStoredState = try container.decodeIfPresent(
                Bool.self,
                forKey: .hasStoredAPIKey
            ) ?? false
            hasStoredKeychainAPIKey = try container.decodeIfPresent(
                Bool.self,
                forKey: .hasStoredKeychainAPIKey
            ) ?? (provider.secretStorageMode == .keychain && legacyStoredState)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(provider, forKey: .provider)
            try container.encode(apiKey, forKey: .apiKey)
            try container.encode(
                hasStoredKeychainAPIKey,
                forKey: .hasStoredKeychainAPIKey
            )
        }
    }
}
