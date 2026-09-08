import Foundation

/// Offline fixtures only: never use configured credentials or open user PDFs.
@MainActor
enum AIWorkflowDiagnosticSuite {
    static func run() async -> Bool {
        var failures: [String] = []
        var total = 0
        func report(_ name: String, checks: Int, failures items: [String]) {
            total += checks
            failures.append(contentsOf: items.map { "\(name): \($0)" })
            print("\(items.isEmpty ? "PASS" : "FAIL") \(name): \(checks) checks")
            for item in items { print("  \(item)") }
        }
        let foundation = await AIHighlightFoundationDiagnostics.run()
        let bugfix = await AIRAGBugfixDiagnostics.run()
        report("RAG bugfix", checks: bugfix.checkCount, failures: bugfix.failures)
        let retrieval = await AIEvidenceRetrievalDiagnostics.run()
        report("evidence retrieval", checks: retrieval.checks, failures: retrieval.failures)
        report("foundation", checks: foundation.checkCount, failures: foundation.failures)
        let runtime = await AIToolRuntimeDiagnostics.run()
        report("bounded runtime", checks: runtime.checks, failures: runtime.failures)
        let codec = await AIHighlightCodecDiagnostics.run()
        report("wire codec", checks: codec.checks, failures: codec.failures)
        let workflow = await AIHighlightToolWorkflowDiagnostics.run()
        report("workflow", checks: workflow.checks, failures: workflow.failures)
        let provider = await OpenAICompatibleToolProviderDiagnostics.run()
        report("provider", checks: provider.checks, failures: provider.failures)
        let native = AIHighlightNativePDFDiagnostics.run()
        report("native PDF", checks: native.checkCount, failures: native.failures)
        let safety = await AIHighlightPublicationSafetyDiagnostics.run()
        report("publication safety", checks: safety.checkCount, failures: safety.failures)
        let fallback = await AILocalOutlineFallbackDiagnostics.run()
        report("local fallback", checks: fallback.checks, failures: fallback.failures)
        let presentation = AIPresentationDiagnostics.run()
        report("consent and localization", checks: presentation.checkCount, failures: presentation.failures)
        let credentials = await AIConfigurationAccessDiagnostics.run()
        report("credential access", checks: credentials.checks, failures: credentials.failures)
        let annotation = AIHighlightNativeAnnotationDiagnostics.run()
        report("native annotation", checks: annotation.checkCount, failures: annotation.failures)
        let application = AIHighlightApplicationDiagnostics.run()
        report("atomic application", checks: application.checkCount, failures: application.failures)
        let persistence = await AIHighlightPersistenceDiagnostics.run()
        report("isolated persistence", checks: persistence.checkCount, failures: persistence.failures)
        print("AI DIAGNOSTICS: \(total) checks, \(failures.count) failures")
        return failures.isEmpty
    }
}
