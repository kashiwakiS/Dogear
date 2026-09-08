# Privacy

Dogear is local-first and has no telemetry, advertising, account requirement,
or background upload service.

## Data kept on the Mac

Dogear stores Library metadata, security-scoped bookmarks, reading position,
preferences, and app-managed PDF working copies under its sandbox and
`Application Support/PDFWorkBench`. Original PDFs remain at their user-chosen
locations. Working-copy operations do not overwrite originals unless the user
separately confirms an atomic Save to Original action.

AI Highlights are standard PDF annotations stored in the app-managed working
copy. Their request titles, group visibility, and diagnostic records are local
application data. Routine diagnostics redact document passages and questions;
detailed local capture is available only when explicitly enabled in a Debug
build.

## Optional cloud AI

Cloud AI is disabled by default. After a provider is configured and enabled:

- Test Connection contacts the configured endpoint without PDF content.
- Ask sends the question, any displayed selected text, and only the native-text
  passages returned by targeted read tools. The PDF file is not attached.
- Each Send starts an independent question. Dogear may use a provider response
  cursor while that question runs. With a stateless compatible endpoint, it
  keeps and resends only the current question's context in memory until the
  request completes, fails, or is canceled.
- Dogear does not save AI answers or conversation history to disk or reuse them
  for later questions. Applied AI Highlights and their group metadata persist
  locally as PDF annotations and application metadata.
- Provider-side storage and retention follow the selected provider's policy.

The optional experimental BGE Small EN model is imported explicitly and runs
locally for retrieval. The app does not download it automatically. Retrieved
native-text passages are still sent to the configured cloud provider when Ask
is used.

Provider keys can be stored in macOS Keychain or, by explicit choice, as
plaintext in a current-user-only local configuration file. Dogear does not
display or export Keychain secrets.

Disabling cloud AI leaves local reading, annotations, Library features, and
deterministic outline export available.
