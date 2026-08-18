# Dogear

[![Build](https://github.com/kashiwakiS/Dogear/actions/workflows/build.yml/badge.svg)](https://github.com/kashiwakiS/Dogear/actions/workflows/build.yml)
[![GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](#requirements)

Dogear is a native macOS PDF workbench for people who read deeply: navigate
long papers, annotate with standard PDF markup, organize a local library, and
perform page-level work without silently changing the original file.

> Dogear 0.1 is preparing for its first public source release. Prebuilt
> downloads will follow after the GitHub build, signing, and notarization flow
> has been proven end to end.

![Dogear reader in Simplified Chinese with Library, outline rail, PDF canvas, and annotation tools](assets/screenshots/dogear-reader.jpeg)

## Why Dogear

- **A reading workspace, not just a viewer.** Use a hierarchical Library,
  Groups, native window tabs, full-text search, bookmarks, and locally detected
  headings to stay oriented in long documents.
- **Portable annotations.** Highlights and FreeText notes are standard PDF
  annotations that remain visible in Preview, Skim, PDF Expert, and other
  compatible readers.
- **Safe page operations.** Editing happens in an app-managed working copy.
  Delete-page and export flows leave the original untouched unless you
  explicitly confirm an atomic overwrite.
- **Keyboard-first reading.** Highlight, add notes, navigate pages, search,
  zoom, switch layouts, and toggle sidebars without leaving the document.
- **Local-first by default.** Library metadata stays on the Mac. Optional
  OpenAI-compatible summaries and selected-text questions are disabled until
  configured, reviewed, and confirmed; Dogear still works without AI.
- **Native and focused.** SwiftUI, AppKit, and PDFKit—no embedded browser or
  third-party PDF engine.

## Highlights in 0.1

- PDFKit reading with single-page, continuous, and two-up layouts; page jump;
  fit/actual-size controls; and non-destructive night display.
- A compact outline rail that prefers PDF bookmarks and can detect headings in
  text PDFs without OCR or network access.
- Quiet, display-only PDF link treatment that preserves stored annotations
  when saving or exporting.
- Local Library Groups, drag ordering, last-page restoration, native tabs, and
  per-window file sessions.
- Highlight and note lists with search, navigation, Markdown export, and a
  deterministic keyword outline.
- English and Simplified Chinese UI, including an app-only language override.

## Build from source

Dogear currently has no public binary download. Clone the repository and run
the same unsigned build entry point used by CI:

```bash
git clone https://github.com/kashiwakiS/Dogear.git
cd Dogear
scripts/check-sensitive-info.sh
scripts/build.sh --debug
```

The app is written to
`${TMPDIR:-/tmp}/DogearDerivedData/Build/Products/Debug/Dogear.app`. The build
does not require an Apple Developer certificate. To work in Xcode instead,
open `PDFWorkBench.xcodeproj` and select the shared `PDFWorkBench` scheme.

Before submitting a release-affecting change, also build both supported CPU
architectures:

```bash
scripts/build.sh --release --clean --universal
```

Every push and pull request repeats the sensitive-information audit, Debug
build, universal Release build, and app metadata checks in GitHub Actions.

## Requirements

- macOS 14 or later.
- Xcode 26.5 or later to build from source.

The public target remains macOS 14 because current sidebar coordination uses
Observation APIs introduced in macOS 14. Supporting macOS 10.15 or 13 would
require implementation and older-toolchain work; the deployment target is not
lowered by weakening or removing current behavior.

## Essential shortcuts

| Action | Shortcut |
| --- | --- |
| Highlight selection | `H` |
| Add FreeText note | `T` |
| Previous / next page | `W` / `S` |
| Open PDF | `⌘O` |
| Library | `⌘⌥L` |
| Annotations | `⌘⌥R` |
| Fit page / width | `⌘1` / `⌘2` |

## Roadmap

- **0.1.x — Public foundation:** reproducible source builds, signed/notarized
  GitHub delivery, file-safety hardening, crash and compatibility fixes.
- **0.2–0.8 — Workbench depth:** page reorder/rotate/duplicate and partial
  export, Dog-ear markers, annotation ergonomics, selective Apple Vision OCR,
  and broader automated tests.
- **0.9 — Release candidate:** migration guarantees, accessibility and
  localization pass, performance validation on large libraries, and a frozen
  1.0 compatibility surface.
- **1.0 — Stable:** documented data compatibility, dependable upgrade and
  rollback guidance, and sustained release/signing operations.

Dogear follows Semantic Versioning. Before 1.0, patch releases (`0.1.1`) are
backward-compatible fixes, minor releases (`0.2.0`) may add features or revise
unfinished interfaces, `0.9.x` is the stabilization line, and `1.0.0` begins
the stable compatibility promise. Commit count is never used as an app version;
an annotated `vX.Y.Z` tag identifies the single audited release commit.

Feature priorities are discussed openly in [GitHub Discussions](https://github.com/kashiwakiS/Dogear/discussions).
Use Ideas for proposals and Polls for roadmap votes; implementation-ready bugs
belong in Issues.

Homebrew distribution is intentionally deferred until the signed GitHub
release process has been exercised and its downloadable artifact is stable.

## Privacy and file safety

Dogear has no telemetry or account requirement. It reads user-selected PDFs
inside the macOS app sandbox. Cloud AI is optional and off by default; a full
document summary uploads the complete reviewed PDF to the configured provider,
while a selection question sends the displayed selection and conversation.
See [PRIVACY.md](PRIVACY.md) for the exact boundary.

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.
Security reports follow [SECURITY.md](SECURITY.md). Dogear is licensed under
the [GNU General Public License v3.0](LICENSE).
