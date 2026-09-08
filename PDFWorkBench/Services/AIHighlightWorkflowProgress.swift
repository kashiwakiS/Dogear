import Foundation

nonisolated enum AIHighlightProgressPhase: Equatable, Sendable {
    case preparingSnapshot
    case mappingDocument
    case indexingEvidence
    case searching
    case readingEvidence
    case reviewingEvidence
    case validatingDraft
    case generatingAnswer
    case resolvingAnchors
    case committingBatch
    case waitingForCredentials
    case waitingForProvider
    case retrying

    @MainActor var localizedDescription: String {
        switch self {
        case .preparingSnapshot:
            return L10n.string("Preparing the document snapshot…")
        case .mappingDocument:
            return L10n.string("Mapping the document…")
        case .indexingEvidence:
            return L10n.string("Building the local evidence index…")
        case .searching:
            return L10n.string("Searching for relevant evidence…")
        case .readingEvidence:
            return L10n.string("Reading selected evidence…")
        case .reviewingEvidence:
            return L10n.string("Reviewing answer against evidence…")
        case .validatingDraft:
            return L10n.string("Validating optional highlights…")
        case .generatingAnswer:
            return L10n.string("Preparing the answer…")
        case .resolvingAnchors:
            return L10n.string("Resolving highlight locations…")
        case .committingBatch:
            return L10n.string("Applying verified highlights…")
        case .waitingForCredentials:
            return L10n.string("Preparing credentials; check for a macOS Keychain prompt…")
        case .waitingForProvider:
            return L10n.string("Waiting for the AI provider…")
        case .retrying:
            return L10n.string("Retrying the AI provider…")
        }
    }

    static func phase(forToolName name: String) -> AIHighlightProgressPhase {
        switch name {
        case AIHighlightToolName.documentMap:
            return .mappingDocument
        case AIHighlightToolName.searchSegments:
            return .searching
        case AIHighlightToolName.readSegments:
            return .readingEvidence
        case AIAnswerEvidenceReview.toolName:
            return .reviewingEvidence
        case AIHighlightToolName.stageHighlights:
            return .validatingDraft
        case AIHighlightToolName.publishAnswer:
            return .generatingAnswer
        default:
            return .waitingForProvider
        }
    }
}

nonisolated enum AIHighlightFailureKind: Equatable, Sendable {
    case configuration
    case authentication
    case rateLimited
    case serviceUnavailable
    case transport
    case timeout
    case malformedProviderResponse
    case providerCapabilityUnsupported
    case internalBudget
    case noProgress
    case internalOutcome
    case documentChanged
    case cancellation
    case unknown
}

nonisolated enum AIHighlightFailureMessage {
    static func kind(of error: Error) -> AIHighlightFailureKind {
        if error is CancellationError { return .cancellation }
        if error is AIConfigurationError { return .configuration }
        if error is AIRetrievalError { return .configuration }
        if let urlError = error as? URLError {
            return urlError.code == .timedOut ? .timeout : .transport
        }
        if let foundationError = error as? AIWorkflowFoundationError {
            switch foundationError {
            case .budgetExceeded:
                return .internalBudget
            case .noProgress:
                return .noProgress
            case .functionToolsUnsupported:
                return .providerCapabilityUnsupported
            case .duplicateToolCallID:
                return .malformedProviderResponse
            }
        }
        if let providerError = error as? AIProviderError {
            switch providerError {
            case .invalidBaseURL, .missingAPIKey, .missingModel:
                return .configuration
            case .server(let statusCode, _):
                if statusCode == 401 || statusCode == 403 { return .authentication }
                if statusCode == 429 { return .rateLimited }
                if statusCode >= 500 { return .serviceUnavailable }
                return .malformedProviderResponse
            case .invalidResponse, .emptyResponse:
                return .malformedProviderResponse
            }
        }
        if let error = error as? OpenAICompatibleToolProviderError,
           error == .serverContinuationUnsupported {
            return .providerCapabilityUnsupported
        }
        if error is OpenAICompatibleToolProviderError {
            return .malformedProviderResponse
        }
        if error is AIHighlightWorkflowError || error is AIAnswerEvidenceReviewError { return .internalOutcome }
        if let generationError = error as? AIHighlightGenerationError {
            switch generationError {
            case .documentChanged: return .documentChanged
            case .noUsableNativeText: return .internalOutcome
            }
        }
        return .unknown
    }

    static func code(for error: Error) -> String {
        switch kind(of: error) {
        case .configuration: return "configuration"
        case .authentication: return "authentication"
        case .rateLimited: return "rate_limited"
        case .serviceUnavailable: return "service_unavailable"
        case .transport: return "transport"
        case .timeout: return "timeout"
        case .malformedProviderResponse: return "malformed_provider_response"
        case .providerCapabilityUnsupported: return "provider_capability_unsupported"
        case .internalBudget: return "internal_budget"
        case .noProgress: return "no_progress"
        case .internalOutcome: return "internal_outcome"
        case .documentChanged: return "document_changed"
        case .cancellation: return "cancelled"
        case .unknown: return "unknown"
        }
    }

    @MainActor static func userMessage(for error: Error) -> String {
        if let reviewError = error as? AIAnswerEvidenceReviewError {
            switch reviewError {
            case .attemptsExhausted: return L10n.string("The answer still failed evidence review after one correction. No final answer or annotations were accepted.")
            case .evidenceTooLarge: return L10n.string("The proposed answer or its cited evidence exceeds the bounded review size. Ask a narrower question. No annotations were applied.")
            case .malformedReview: return L10n.string("The evidence reviewer returned an invalid result. No final answer or annotations were accepted.")
            }
        }
        if let retrievalError = error as? AIRetrievalError {
            switch retrievalError {
            case .modelMissing: return L10n.string("Import the BGE Small EN model in Settings before using semantic retrieval.")
            case .invalidSelection: return L10n.string("Choose a supported retrieval mode in Settings.")
            case .invalidModel: return L10n.string("The local embedding model is invalid or incompatible. Import a verified model package.")
            case .invalidVector: return L10n.string("The local embedding model returned invalid vectors. No result was accepted.")
            case .inputTooLong: return L10n.string("A source sentence or search query exceeds this model's token limit. No text was silently truncated.")
            case .indexTooLarge: return L10n.string("This document exceeds the local embedding index limit. Choose lightweight retrieval.")
            }
        }
        if let configurationError = error as? AIConfigurationError {
            switch configurationError {
            case .configurationChanged:
                return L10n.string("The AI configuration or credential changed while this request was preparing. Send the request again.")
            case .cloudAIUnavailable:
                return L10n.string("Cloud AI is disabled or its current data-sharing terms have not been accepted.")
            default:
                return L10n.string("Dogear could not prepare the configured AI credentials. No provider request was sent.")
            }
        }
        if let urlError = error as? URLError {
            if urlError.code == .timedOut {
                return L10n.string("The AI provider did not respond in time. No result was accepted.")
            }
            return L10n.string(
                "Dogear could not reach the AI provider. No result was accepted."
            )
        }
        if let foundationError = error as? AIWorkflowFoundationError {
            return message(for: foundationError)
        }
        if let providerError = error as? AIProviderError {
            return message(for: providerError)
        }
        if let error = error as? OpenAICompatibleToolProviderError,
           error == .serverContinuationUnsupported {
            return L10n.string(
                "This provider does not support the server-stored conversation required by this workflow. No result was accepted."
            )
        }
        if error is OpenAICompatibleToolProviderError {
            return L10n.string(
                "The AI provider returned a response that did not match the active workflow. No result was accepted."
            )
        }
        if error is AIHighlightWorkflowError {
            return L10n.string(
                "The AI workflow ended without a verified result."
            )
        }
        if let generationError = error as? AIHighlightGenerationError {
            switch generationError {
            case .documentChanged:
                return L10n.string("The PDF changed while the AI request was running. No result was accepted.")
            case .noUsableNativeText:
                return L10n.string("This PDF has no usable native text. OCR is not enabled.")
            }
        }
        return L10n.string("The AI request failed. No result was accepted.")
    }

    @MainActor private static func message(for error: AIWorkflowFoundationError) -> String {
        switch error {
        case .budgetExceeded(let metric):
            switch metric {
            case .providerTurns:
                return L10n.string(
                    "Dogear reached its internal step limit before the AI finished. This is not an API account quota error."
                )
            case .toolCalls:
                return L10n.string(
                    "Dogear reached its internal tool-call limit before the AI finished. This is not an API account quota error."
                )
            case .readCharacters:
                return L10n.string(
                    "Dogear reached its internal source-reading limit before the AI finished. This is not an API account quota error."
                )
            case .inputTokens:
                return L10n.string(
                    "Dogear reached its internal input limit before the AI finished. This is not an API account quota error."
                )
            case .elapsedTime:
                return L10n.string(
                    "Dogear reached its internal time limit before the AI finished. This is not an API account quota error."
                )
            }
        case .noProgress:
            return L10n.string(
                "The AI repeated the same request without making progress, so Dogear stopped."
            )
        case .duplicateToolCallID:
            return L10n.string(
                "The AI provider repeated a tool-call identifier. No result was accepted."
            )
        case .functionToolsUnsupported:
            return L10n.string(
                "The configured AI provider does not support the required function tools."
            )
        }
    }

    @MainActor private static func message(for error: AIProviderError) -> String {
        switch error {
        case .server(let statusCode, _):
            if statusCode == 401 || statusCode == 403 {
                return L10n.string(
                    "The AI provider rejected the configured credentials (HTTP \(statusCode))."
                )
            }
            if statusCode == 429 {
                return L10n.string(
                    "The AI provider is rate limiting requests (HTTP 429). Try again shortly."
                )
            }
            if statusCode >= 500 {
                return L10n.string(
                    "The AI provider is temporarily unavailable (HTTP \(statusCode))."
                )
            }
            return L10n.string(
                "The AI provider returned an error (HTTP \(statusCode))."
            )
        case .invalidBaseURL:
            return L10n.string("The API Base URL is invalid.")
        case .missingAPIKey:
            return L10n.string("No API key is configured.")
        case .missingModel:
            return L10n.string("Choose an AI model first.")
        case .invalidResponse, .emptyResponse:
            return L10n.string(
                "The AI provider returned an unexpected response. No result was accepted."
            )
        }
    }
}
