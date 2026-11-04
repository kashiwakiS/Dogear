import Foundation

/// Device wording is presentation policy; credential storage and authorization
/// keep the same shared implementation on both platforms.
enum AIKeychainPlatformText {
    private struct Wording {
        let name: String
        let saved: String
        let newKeys: String
        let moved: String
        let preparing: String
        let privacy: String
    }

    #if os(macOS)
    private static let wording = Wording(
        name: "macOS Keychain",
        saved: "API key saved in macOS Keychain.",
        newKeys: "New keys will be stored in macOS Keychain.",
        moved: "API key moved from the local configuration file to macOS Keychain.",
        preparing: "Preparing credentials; check for a macOS Keychain prompt…",
        privacy: "The API key is stored in macOS Keychain and cannot be displayed or exported by Dogear."
    )
    #else
    private static let wording = Wording(
        name: "iPad Keychain",
        saved: "API key saved in iPad Keychain.",
        newKeys: "New keys will be stored in iPad Keychain.",
        moved: "API key moved from the local configuration file to iPad Keychain.",
        preparing: "Preparing credentials; check for an iPad Keychain prompt…",
        privacy: "The API key is stored in iPad Keychain and cannot be displayed or exported by Dogear."
    )
    #endif

    // Preserve the existing stored-status strings and Mac display name. The
    // presentation callers that already localize continue to localize here.
    static var name: String { wording.name }
    static var saved: String { wording.saved }
    static var newKeys: String { wording.newKeys }
    static var moved: String { wording.moved }
    static var preparing: String { L10n.string(String.LocalizationValue(wording.preparing)) }
    static var privacy: String { L10n.string(String.LocalizationValue(wording.privacy)) }
}
