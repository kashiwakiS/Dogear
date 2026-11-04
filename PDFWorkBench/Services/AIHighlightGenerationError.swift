import Foundation

nonisolated enum AIHighlightGenerationError: LocalizedError, Equatable {
    case documentChanged
    case noUsableNativeText

    var errorDescription: String? {
        switch self {
        case .documentChanged:
            return "The PDF changed while the AI request was running."
        case .noUsableNativeText:
            return "This PDF has no usable native text. OCR is not enabled in this version."
        }
    }
}
