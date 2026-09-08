import Foundation
import Security

/// This is deliberately separate from the MainActor settings/write interface.
/// Implementations must support a blocking read outside the main thread.
nonisolated protocol AISecretReading: Sendable {
    func readSecret(profileID: UUID) throws -> String?
}

nonisolated struct KeychainAISecretReader: AISecretReading {
    func readSecret(profileID: UUID) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.KashiwakiS.PDFWorkBench.ai-credentials",
            kSecAttrAccount as String: profileID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status == errSecUserCanceled { throw CancellationError() }
        guard status == errSecSuccess,
              let data = result as? Data,
              let secret = String(data: data, encoding: .utf8)
        else { throw KeychainReadError(status: status) }
        return secret
    }

    private struct KeychainReadError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
        }
    }
}

/// A blocked Security authorization must not occupy MainActor or a cooperative
/// Swift executor thread. Cancellation resumes the caller immediately; it does
/// not claim to close an authorization dialog already owned by macOS.
nonisolated final class AIBackgroundSecretReader: Sendable {
    private let reader: any AISecretReading
    private let queue = DispatchQueue(label: "com.KashiwakiS.PDFWorkBench.ai-secret-read", qos: .userInitiated)

    init(reader: any AISecretReading) { self.reader = reader }

    func readSecret(profileID: UUID) async throws -> String? {
        let operation = ReadOperation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
                guard operation.register(continuation) else { return }
                queue.async { [reader] in
                    guard operation.begin() else { return }
                    operation.complete(Result { try reader.readSecret(profileID: profileID) })
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            operation.cancel()
        }
    }

    /// All state is protected by `lock`; continuation resume always happens
    /// after unlocking. A late secret is never stored once cancellation wins.
    private final class ReadOperation: @unchecked Sendable {
        private enum State {
            case unregistered
            case queued(CheckedContinuation<String?, Error>)
            case reading(CheckedContinuation<String?, Error>)
            case finished
        }
        private let lock = NSLock()
        private var state: State = .unregistered

        func register(_ continuation: CheckedContinuation<String?, Error>) -> Bool {
            lock.lock()
            guard case .unregistered = state else {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return false
            }
            state = .queued(continuation)
            lock.unlock()
            return true
        }

        func begin() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard case .queued(let continuation) = state else { return false }
            state = .reading(continuation)
            return true
        }

        func complete(_ result: Result<String?, Error>) {
            lock.lock()
            guard case .reading(let continuation) = state else {
                lock.unlock()
                return
            }
            state = .finished
            lock.unlock()
            continuation.resume(with: result)
        }

        func cancel() {
            lock.lock()
            let continuation: CheckedContinuation<String?, Error>?
            switch state {
            case .queued(let pending), .reading(let pending): continuation = pending
            case .unregistered, .finished: continuation = nil
            }
            state = .finished
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
    }
}
