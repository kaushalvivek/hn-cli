# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.3.1] - 2026-11-09

### Fixed

- `hn capabilities` and `hn drafts` now work without constructing a network client, so they succeed offline and in minimal containers without CA certificates.
- The HTTP user agent now tracks the crate version instead of a hard-coded release.

## [0.3.0] - 2026-11-08

### Changed

- Rewrote `hn` in Rust. The Swift implementation remains available at `v0.2.1`.
- macOS and Linux are both first-class: Apple Silicon, Intel, Linux x86_64, and Linux aarch64 release assets.
- Linux binaries are static musl builds that run on any distribution, not just recent glibc systems.
- Replaced the Swift Package build with Cargo, `rustfmt`, `clippy`, and native CI on all three platforms.
- Homebrew now installs the Rust binary on macOS and Linux from the consolidated `kaushalvivek/tap`.

### Added

- `hn capabilities`: a machine-readable command map, JSON error contract, environment variables, and auth requirements for agents.
- `--json` on every command, plus `HN_JSON=1`.
- `AGENTS.md` and `llms.txt` guides for coding agents.
- `hn drafts` to list drafts, `--clear` to remove them, and `--use-draft` to resume comment/edit drafts.
- Context-aware CLI commenting: prints the parent author and excerpt before opening `$VISUAL`/`$EDITOR`, and saves a draft when posting fails.
- Shared draft storage between the CLI and TUI.
- Cross-platform release workflow producing macOS universal, Linux x86_64, and Linux aarch64 archives with checksums.
- Linux support in `install.sh` with platform detection and checksum verification.
- Unit tests for the domain model, HN HTML parsing, drafts, CLI pagination, and capabilities.

### Fixed

- JSON errors now use a consistent `{"ok":false,"error":{...}}` shape on stderr.
- Feed page labels respect `--limit` instead of assuming 30 items.
- TUI `q` and `Ctrl-C` always preserve drafts and restore the terminal.

## [0.2.1] - 2026-11-08

### Fixed

- Replaced the external-editor-only commenting flow with an inline, context-aware composer.
- Added drafts, draft restore, external-editor handoff, and retry-safe error handling.
- Posted replies are inserted under their parent immediately instead of reloading the whole thread.
- Fixed stale comment-form values overriding the requested parent item.

### Added

- Multi-line composer with cursor movement, wrapping, scrolling, paste, and page navigation.
- Context header and quoted parent excerpt while replying.
- `Ctrl-S` to post, `Esc` to save a draft, `Ctrl-E` for an external editor.
- Persistent drafts at `~/.config/hn/drafts.json` with `0600` permissions.

## [0.2.0] - 2026-11-08

### Added

- Interactive full-screen terminal browser with feed sidebar, story list, preview pane, and threaded comments.
- Keyboard and mouse navigation, command palette, help overlay, search, login modal, confirmations, and toasts.
- Authenticated actions: vote, unvote, downvote, submit, comment/reply, edit, delete, favorite, hide, flag, and unflag.
- Public reads for feeds, latest comments, past front pages, submissions from a domain, leaders, updates, users, and search.
- Lazy comment expansion with a full Algolia item-tree fast path and Firebase fallback.
- One-request HTML feed loading for the interactive browser.
- Scriptable line-oriented commands for feeds, items, threads, users, search, and authentication.
- Session storage with `0600` permissions and no password persistence.
- Homebrew tap, install script, universal macOS release assets, and CI.

[0.3.1]: https://github.com/kaushalvivek/hn-cli/releases/tag/v0.3.1
[0.3.0]: https://github.com/kaushalvivek/hn-cli/releases/tag/v0.3.0
[0.2.1]: https://github.com/kaushalvivek/hn-cli/releases/tag/v0.2.1
[0.2.0]: https://github.com/kaushalvivek/hn-cli/releases/tag/v0.2.0
