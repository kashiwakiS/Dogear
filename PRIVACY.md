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
- A document summary review states that the complete PDF will be uploaded; the
  request is sent only after confirmation.
- A selected-text question sends the displayed selection, question, and
  retained conversation when the user chooses Send.
- An AI Highlights request sends the user question when present and only the
  native-text passages returned by targeted read tools. The PDF file is not
  attached to this workflow.
- Summaries and conversations remain in memory for the current document/window
  session. Applied AI Highlights and their group metadata persist locally.
- Dogear asks compatible Responses APIs not to store results, but the selected
  provider's own terms and retention policy still apply.

Provider keys can be stored in macOS Keychain or, by explicit choice, as
plaintext in a current-user-only local configuration file. Dogear does not
display or export Keychain secrets.

Disabling cloud AI leaves local reading, annotations, Library features, and
deterministic outline export available.
