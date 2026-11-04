import SwiftUI

extension Color {
    init(pdfColor: PDFPlatformColor) {
        #if os(macOS)
        self.init(nsColor: pdfColor)
        #else
        self.init(uiColor: pdfColor)
        #endif
    }

    var pdfPlatformColor: PDFPlatformColor {
        PDFPlatformColor(self)
    }
}
