import Foundation

struct OpenAICompatibleResponsesProvider: AIProvider {
    private let configuration: AIProviderConfiguration
    private let apiKey: String
    private let session: URLSession
    private let baseURL: URL

    init(
        configuration: AIProviderConfiguration,
        apiKey: String,
        session: URLSession? = nil
    ) throws {
        guard let url = URL(string: configuration.baseURL),
              let scheme = url.scheme,
              ["https", "http"].contains(scheme.lowercased())
        else {
            throw AIProviderError.invalidBaseURL
        }
        self.configuration = configuration
        self.apiKey = apiKey
        self.baseURL = url
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 90
            config.timeoutIntervalForResource = 600
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
    }

    func listModels() async throws -> [AIModelDescriptor] {
        let request = authorizedRequest(path: "models", method: "GET")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let envelope = try JSONDecoder().decode(ModelListEnvelope.self, from: data)
        return envelope.data.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    func respond(to request: AIResponseRequest) async throws -> AIResponseResult {
        guard !configuration.model.isEmpty else {
            throw AIProviderError.missingModel
        }

        var urlRequest = authorizedRequest(path: "responses", method: "POST")
        if let file = request.file {
            urlRequest.httpBody = try JSONEncoder().encode(
                FileResponsesRequestBody(
                    model: configuration.model,
                    instructions: request.instructions,
                    input: [
                        InputMessage(
                            role: "user",
                            content: [
                                InputContent(
                                    type: "input_file",
                                    text: nil,
                                    filename: file.filename,
                                    fileData: "data:application/pdf;base64,\(file.data.base64EncodedString())"
                                ),
                                InputContent(
                                    type: "input_text",
                                    text: request.input,
                                    filename: nil,
                                    fileData: nil
                                )
                            ]
                        )
                    ],
                    store: false
                )
            )
        } else {
            urlRequest.httpBody = try JSONEncoder().encode(
                TextResponsesRequestBody(
                    model: configuration.model,
                    instructions: request.instructions,
                    input: request.input,
                    store: false
                )
            )
        }

        let (data, response) = try await session.data(for: urlRequest)
        try validate(response: response, data: data)
        let envelope = try JSONDecoder().decode(ResponsesEnvelope.self, from: data)
        let text = envelope.outputText
            ?? envelope.output?
                .flatMap(\.content)
                .compactMap(\.text)
                .joined(separator: "\n")

        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.emptyResponse
        }
        return AIResponseResult(text: text, responseID: envelope.id)
    }

    private func authorizedRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: endpoint(path: path))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func endpoint(path: String) -> URL {
        if baseURL.lastPathComponent == path {
            return baseURL
        }
        return baseURL.appendingPathComponent(path)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
                ?? String(data: data.prefix(500), encoding: .utf8)
                ?? "Unknown provider error"
            throw AIProviderError.server(statusCode: response.statusCode, message: message)
        }
    }

    private struct ModelListEnvelope: Decodable {
        let data: [AIModelDescriptor]
    }

    private struct TextResponsesRequestBody: Encodable {
        let model: String
        let instructions: String
        let input: String
        let store: Bool
    }

    private struct FileResponsesRequestBody: Encodable {
        let model: String
        let instructions: String
        let input: [InputMessage]
        let store: Bool
    }

    private struct InputMessage: Encodable {
        let role: String
        let content: [InputContent]
    }

    private struct InputContent: Encodable {
        let type: String
        let text: String?
        let filename: String?
        let fileData: String?

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case filename
            case fileData = "file_data"
        }
    }

    private struct ResponsesEnvelope: Decodable {
        let id: String?
        let outputText: String?
        let output: [OutputItem]?

        enum CodingKeys: String, CodingKey {
            case id
            case outputText = "output_text"
            case output
        }
    }

    private struct OutputItem: Decodable {
        let content: [OutputContent]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            content = try container.decodeIfPresent([OutputContent].self, forKey: .content) ?? []
        }

        private enum CodingKeys: String, CodingKey { case content }
    }

    private struct OutputContent: Decodable {
        let text: String?
    }

    private struct ErrorEnvelope: Decodable {
        let error: ProviderError
    }

    private struct ProviderError: Decodable {
        let message: String
    }
}
