# Dogear

[![Build](https://github.com/kashiwakiS/Dogear/actions/workflows/build.yml/badge.svg)](https://github.com/kashiwakiS/Dogear/actions/workflows/build.yml)
[![GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](#requirements)

I built Dogear for long-form PDF reading on the Mac. It keeps the reading
surface quiet, makes annotations portable, and keeps page operations reversible.

![Dogear AI Highlights, Margin Canvas, and unified Ask sidebar](assets/screenshots/dogear-ai-highlights-hd.png)

![Dogear reader with Library, outline rail, PDF canvas, and annotation tools](assets/screenshots/dogear-reader.png)

## What you can do

- Read with single-page, continuous, and two-up layouts, page jump, zoom, fit
  controls, and a non-destructive night display.
- Keep a local Library with Groups, ordering, native tabs, and per-window file
  sessions.
- Create standard PDF highlights from the keyboard, toolbar, or Annotation menu.
- Add FreeText notes, navigate annotations, and export them as Markdown. Search
  highlighted text and comments by manual/AI source and annotation type while
  retaining the current visible AI Highlight Group scope.
- Use bookmarks, detected headings, and Dog-ear page markers to move through a
  document.
- Continue persistent research conversations across selected PDFs, text excerpts
  and explicitly added images, with clickable references to saved evidence.
- Ask uses deterministic local BM25 retrieval by default and groups up to three
  adjacent sentences from the same page and text block into an evidence window.
- Save research as independent editable notes and export Markdown with image
  attachments. Read PDF, AI and annotations in adjacent panes.
- Create optional source-linked AI Highlights, organize them by named request
  group, show any subset, and navigate to supporting passages.
- Read annotation explanations in the page-side Margin Canvas, select their
  text for follow-up questions, and export a PDF containing exactly the AI
  groups you choose.
- Organize, rotate, duplicate, delete, and export pages from an app-managed
  working copy. The original PDF stays untouched until you explicitly confirm
  an overwrite.
- Use the optional OpenAI-compatible reader assistant. It is off by default;
  Dogear remains fully usable without an AI provider.

## Install

Download the latest universal macOS package from
[GitHub Releases](https://github.com/kashiwakiS/Dogear/releases). The current
distribution package is signed with the developer account.

## Build from source

Requirements: macOS 14 or later and Xcode 16.0 or later.

```bash
git clone https://github.com/kashiwakiS/Dogear.git
cd Dogear
scripts/check-sensitive-info.sh
scripts/build.sh --debug
```

The Debug app is written to `build/Debug/Dogear.app`; a Release build is
written to `build/Release/Dogear.app`. Xcode intermediates live in
`build/DerivedData/`. Use `--output-dir PATH` to choose a different final app
directory. For a clean universal Release build:

```bash
scripts/build.sh --release --clean --universal
```

GitHub Actions runs the same source scan, Debug build, universal Release build,
and app metadata checks for every push and pull request.

### Local evidence retrieval

Ask uses deterministic local BM25 retrieval by default and needs no model
download. Results expand to an evidence window of up to three adjacent
sentences within the same page and text block, providing fuller context while
keeping citations and highlight locations traceable.

When PDF text and segmentation rules have not changed, Dogear reuses derived
retrieval caches in its private app storage to avoid repeating extraction,
segmentation and vector calculation. These caches can be safely deleted and
rebuilt as needed, and they never modify the original PDF.

For English papers, Settings also offers the experimental “Semantic — Small
EN” mode with a manually imported local BGE Small EN package. Dogear never
downloads this model automatically. Advanced users can install the pinned
dependencies listed at the top of `scripts/prepare-bge-small-en.py` in an
isolated Python environment, then run:

```bash
python3 scripts/prepare-bge-small-en.py --output /path/to/output
```

The script downloads the pinned upstream model, verifies its weights, and
creates a `SmallEN` folder. Import that folder with “Import Local Model…” in
Dogear's AI settings. The default BM25 retrieval remains available without this
setup.

## Shortcuts

| Action | Shortcut |
| --- | --- |
| Highlight selection | `H` |
| Add FreeText note | `T` |
| Toggle Dog-ear on the current page | `D` |
| Previous / next page | `W` / `S` (also `K` / `J`) |
| Open PDF | `⌘O` |
| Save to Original… | `⌘S` |
| Previous / next page | `⌘↑` / `⌘↓` |
| First / last page | `⌘⌥↑` / `⌘⌥↓` |
| Zoom in / out | `⌘+` / `⌘−` |
| Actual size / fit page / fit width | `⌘0` / `⌘1` / `⌘2` |
| Focus the active document or annotation search | `⌘F` |
| Next / previous search result | `⌘G` / `⌘⇧G` |
| Library navigator | `⌘⌥L` |
| Annotations sidebar | `⌘⌥R` |
| New Group… | `⌘⇧N` |

When the native tab Group preview is open, press an unmodified number from `1`
to `9` to open that file. With text selected, you can also add a highlight from
the title toolbar or Annotation menu. The Pages menu contains page organization
and current-page deletion; deletion is disabled for a one-page document.

## Privacy and file safety

Dogear has no telemetry and no account requirement. Library data stays on the
Mac. Cloud AI is optional and off by default. Research conversations, drafts,
evidence, notes and rebuildable retrieval caches are stored locally. When
enabled, AI sends the configured provider the current question, bounded
conversation background, passages from selected sources and images you
explicitly add; it does not attach entire PDF files. See
[PRIVACY.md](PRIVACY.md).

Dogear never overwrites the original PDF during normal editing. Page changes
and annotations are saved to an app-managed working copy. The explicit Save to
Original command requires confirmation and uses an atomic write.

## Contributing

Bug reports and feature requests belong in
[Issues](https://github.com/kashiwakiS/Dogear/issues). Small, focused changes
are welcome through [pull requests](https://github.com/kashiwakiS/Dogear/pulls);
please read [CONTRIBUTING.md](CONTRIBUTING.md) first. Security reports follow
[SECURITY.md](SECURITY.md).

Dogear is licensed under the [GNU General Public License v3.0](LICENSE).
