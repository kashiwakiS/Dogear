# Contributing to Dogear

Thank you for helping make serious PDF reading safer and faster on macOS.

## Before you start

- Search Issues and Discussions before proposing duplicate work.
- Use Discussions > Ideas for product proposals and Polls for priority votes.
- Use Issues for reproducible bugs and scoped implementation work.
- Never attach a private PDF, API key, local app data, or personal path.

## Development setup

You need macOS 14 or later and Xcode 26.5 or later. A signing certificate is
not required for contributor builds.

```bash
scripts/check-sensitive-info.sh
scripts/build.sh --debug
```

## Project rules

- Prefer SwiftUI, use AppKit only where native behavior requires it, and use
  PDFKit for rendering and standard annotations.
- Never silently move, rename, delete, overwrite, or rewrite an original PDF.
- Keep destructive page operations copy/export-first and explicitly confirmed.
- Keep standard PDF annotations as the annotation source of truth.
- Keep Dogear useful without an AI provider.
- Do not add networking, telemetry, a web renderer, or a third-party PDF SDK
  without prior project discussion.

## Pull requests

Keep each change focused. Explain the user-visible effect, file-safety impact,
and tests performed. At minimum run:

```bash
git diff --check
scripts/check-sensitive-info.sh
scripts/build.sh --debug
```

Run a Release build for release-affecting changes. Compilation does not verify
drag and drop, native tabs, full screen, multi-window state, PDF interoperability,
or original-file safety; list the manual paths you exercised and anything you
could not test.

Contributions are accepted under GPL-3.0-only, as stated in [LICENSE](LICENSE).
