# Privacy

Dogear is local-first and has no telemetry, advertising, account requirement,
or background upload service.

## Data kept on the Mac

Dogear stores Library metadata, security-scoped bookmarks, reading position,
preferences, and app-managed PDF working copies under its sandbox and
`Application Support/PDFWorkBench`. Original PDFs remain at their user-chosen
locations. Working-copy operations do not overwrite originals unless the user
separately confirms an atomic Save to Original action.

## Optional cloud AI

Cloud AI is disabled by default. After a provider is configured and enabled:

- Test Connection contacts the configured endpoint without PDF content.
- A document summary review states that the complete PDF will be uploaded; the
  request is sent only after confirmation.
- A selected-text question shows the selection, question, and retained
  conversation before sending them.
- Results remain in memory for the current document/window session.
- Dogear asks compatible Responses APIs not to store results, but the selected
  provider's own terms and retention policy still apply.

Provider keys can be stored in macOS Keychain or, by explicit choice, as
plaintext in a current-user-only local configuration file. Dogear does not
display or export Keychain secrets.

Disabling cloud AI leaves local reading, annotations, Library features, and
deterministic outline export available.
