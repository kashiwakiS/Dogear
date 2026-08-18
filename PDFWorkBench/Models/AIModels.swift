import Foundation

struct PDFTextSelectionSnapshot: Equatable {
    let text: String
    let pageNumbers: [Int]

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum AISecretStorageMode: String, Codable, CaseIterable, Identifiable {
    case plaintextFile
    case keychain

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .plaintextFile:
            return "Local configuration file"
        case .keychain:
            return "macOS Keychain"
        }
    }
}

struct AIProviderConfiguration: Codable, Equatable {
    var id: UUID
    var name: String
    var baseURL: String
    var model: String
    var isCloudAIEnabled: Bool
    var hasCloudConsent: Bool
    var secretStorageMode: AISecretStorageMode

    static let `default` = AIProviderConfiguration(
        id: UUID(),
        name: "DeepSeek",
        baseURL: "https://api.deepseek.com/v1",
        model: "",
        isCloudAIEnabled: false,
        hasCloudConsent: false,
        secretStorageMode: .plaintextFile
    )

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL
        case model
        case isCloudAIEnabled
        case hasCloudConsent
        case secretStorageMode
    }

    init(
        id: UUID,
        name: String,
        baseURL: String,
        model: String,
        isCloudAIEnabled: Bool,
        hasCloudConsent: Bool,
        secretStorageMode: AISecretStorageMode
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.isCloudAIEnabled = isCloudAIEnabled
        self.hasCloudConsent = hasCloudConsent
        self.secretStorageMode = secretStorageMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "DeepSeek"
        baseURL = try container.decode(String.self, forKey: .baseURL)
        model = try container.decode(String.self, forKey: .model)
        isCloudAIEnabled = try container.decode(Bool.self, forKey: .isCloudAIEnabled)
        hasCloudConsent = try container.decode(Bool.self, forKey: .hasCloudConsent)
        secretStorageMode = try container.decodeIfPresent(
            AISecretStorageMode.self,
            forKey: .secretStorageMode
        ) ?? .plaintextFile
    }
}

struct AIModelDescriptor: Codable, Identifiable, Equatable {
    let id: String
}

struct AIResponseRequest: Equatable {
    let instructions: String
    let input: String
    let file: AIFileAttachment?

    init(instructions: String, input: String, file: AIFileAttachment? = nil) {
        self.instructions = instructions
        self.input = input
        self.file = file
    }
}

struct AIFileAttachment: Equatable {
    let filename: String
    let data: Data
    let pageCount: Int

    var byteCount: Int { data.count }
}

struct AIResponseResult: Equatable {
    let text: String
    let responseID: String?
    let reasoningSummary: String?
}

protocol AIProvider {
    func listModels() async throws -> [AIModelDescriptor]
    func respond(to request: AIResponseRequest) async throws -> AIResponseResult
}

protocol AIResultStoring: AnyObject {
    var summaryMarkdown: String { get set }
    var conversation: [AIConversationTurn] { get set }
    func clear()
}

final class InMemoryAIResultStore: AIResultStoring {
    var summaryMarkdown = ""
    var conversation: [AIConversationTurn] = []

    func clear() {
        summaryMarkdown = ""
        conversation = []
    }
}

struct AIConversationTurn: Identifiable, Equatable {
    let id: UUID
    let question: String
    let answer: String
    let selectionText: String
    let pageNumbers: [Int]
    let reasoningSummary: String?
    let duration: TimeInterval
}

struct AIContextPackage: Equatable {
    let title: String
    let text: String
    let pageNumbers: [Int]
    let file: AIFileAttachment?

    init(
        title: String,
        text: String,
        pageNumbers: [Int],
        file: AIFileAttachment? = nil
    ) {
        self.title = title
        self.text = text
        self.pageNumbers = pageNumbers
        self.file = file
    }

    var characterCount: Int { text.count }
}

enum AIReadingTaskKind: String, Equatable {
    case summarizeDocument = "Document Summary"
    case askSelection = "Ask About Selection"
}

struct AIPendingRequest: Identifiable, Equatable {
    let id: UUID
    let kind: AIReadingTaskKind
    let context: AIContextPackage
    let question: String?
    let previewText: String
    let estimatedRequestCount: Int
}

enum AIProviderError: LocalizedError {
    case invalidBaseURL
    case missingAPIKey
    case missingModel
    case invalidResponse
    case emptyResponse
    case server(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "The API Base URL is invalid."
        case .missingAPIKey:
            return "No API key is configured."
        case .missingModel:
            return "Choose an AI model first."
        case .invalidResponse:
            return "The provider returned an unsupported response."
        case .emptyResponse:
            return "The provider returned no answer text."
        case .server(let statusCode, let message):
            return "Provider error \(statusCode): \(message)"
        }
    }
}
