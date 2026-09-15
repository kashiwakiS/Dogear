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
application data. Research sessions, accepted questions and answers, drafts,
saved evidence, notes, note revisions and image attachments are also persisted
locally. Closing a PDF does not delete that research. Routine diagnostics redact document passages and questions;
detailed local capture is available only when explicitly enabled in a Debug
build.

An imported local semantic model and its per-document index caches are also
kept under local application support. The caches contain segment identifiers
and numeric vectors, not AI answers or conversation history.

## Optional cloud AI

Cloud AI is disabled by default. After a provider is configured and enabled:

- Test Connection contacts the configured endpoint without PDF content.
- Research sends the current question, selected text, bounded discussion
  background from up to six accepted rounds / 12,000 characters, and native-text
  passages retrieved from the sources you choose. Entire PDF files are not
  attached.
- Images are sent only when explicitly added to the draft through import,
  paste, drop or PDF-region capture, and require confirmed image capability
  for the selected provider/model. This includes images used for evidence review.
- Research history is saved locally and selected earlier rounds can be reused
  as discussion background in later questions. Provider response cursors stay
  local to each running request and are not saved in research history.
- With a compatible stateful endpoint, Dogear requests provider-side response
  storage while a request runs. With a stateless compatible endpoint, it
  requests no provider-side response storage and resends the current request's
  context as needed until completion, failure or cancellation.
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
