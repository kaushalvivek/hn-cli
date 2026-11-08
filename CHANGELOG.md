# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/).

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

[0.2.1]: https://github.com/kaushalvivek/hn-cli/releases/tag/v0.2.1
[0.2.0]: https://github.com/kaushalvivek/hn-cli/releases/tag/v0.2.0
