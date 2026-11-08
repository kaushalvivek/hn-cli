# AGENTS.md

Guidance for coding agents and automation using `hn`, the Hacker News terminal client.

## What `hn` is

`hn` is a single Rust binary with three surfaces:

1. An interactive `ratatui` browser (`hn`, `hn browse`).
2. A line-oriented CLI for terminals and shell scripts.
3. A JSON interface for agents (`--json` on every command).

It talks to `news.ycombinator.com` (HTML and session), the Firebase API (items, users, feeds), and Algolia (search). Public reads work without an account. Writes require a logged-in Hacker News session.

Repository: <https://github.com/kaushalvivek/hn-cli>
Machine-readable command map: `hn capabilities`

## Golden rules

- **Default to reads.** Never vote, submit, comment, edit, delete, favorite, hide, flag, log in, or log out unless the user explicitly asked for that action.
- **Use `--json`.** Parse stdout; treat stderr as diagnostics. Add `--no-color` when capturing human output.
- **Check the exit code.** `0` means success; `1` means error.
- **Do not read or transmit credentials.** Never print session cookies or the contents of `~/.config/hn/session.json`.
- **Be idempotent and polite.** Cache results when possible; do not hammer feeds in a loop. Public endpoints have no documented rate limit but can throttle.
- **Respect the user's drafts.** Drafts live in `~/.config/hn/drafts.json` and may contain private text.

## Install

```bash
brew install kaushalvivek/tap/hn
# or
curl -fsSL https://raw.githubusercontent.com/kaushalvivek/hn-cli/main/install.sh | sh
# or
cargo install --locked --git https://github.com/kaushalvivek/hn-cli
```

Check availability: `hn --version` and `hn capabilities`.

## Discovery

```bash
hn capabilities | jq
```

The capabilities document lists every agent-facing command, its arguments, whether it needs auth, its output type, JSON error codes, environment variables, and the session path. Prefer it over hard-coding assumptions.

## Reading

```bash
hn front --limit 10 --json
hn new --page 2 --json
hn ask --json
hn show --json
hn jobs --json
hn active --json
hn comments --json
hn past 2026-11-07 --json
hn from github.com --json
```

Pagination: `--limit N --page N` (1-based). Limits are 1–1000.

Items, threads, and users:

```bash
hn item 8863 --json
hn thread 8863 --json
hn context 2921983 --json
hn user pg --json
hn user pg --activity comments --limit 20 --json
```

`hn item` returns one `Item`. `hn thread` returns `{root, replies, loaded_item_count, missing_item_count, is_complete}` where `replies` is a recursive tree. `hn context` returns the ancestor chain from oldest to newest, ending with the requested comment.

Search:

```bash
hn search "sqlite wal" --json
hn search "rust" --type comment --sort date --limit 20 --json
hn search --by pg --type story --json
```

`--type` is `story`, `comment`, `all`, `job`, `poll`, or `pollopt`. `--sort` is `relevance` or `date`.

Other reads:

```bash
hn leaders --json
hn updates --json
```

## Output shapes

These are the stable top-level shapes. Fields can be added; do not depend on field order.

`SiteFeedPage` (feeds, comments, past, from):

```json
{
  "entries": [
    {
      "id": 50411961,
      "kind": "story",
      "title": "...",
      "url": "https://...",
      "text": null,
      "author": "joshcsimmons",
      "created_at": "2026-11-08T10:22:04Z",
      "score": 228,
      "comment_count": 67,
      "story_id": 50411961,
      "story_title": null,
      "parent_id": null,
      "is_dead": false,
      "is_deleted": false
    }
  ],
  "offset": 0,
  "has_more": true,
  "total_count": null
}
```

`Item.content` is tagged by `kind` with a `data` object: `story`, `comment`, `job`, `poll`, `pollopt`, or `deleted`.

`SearchResults`:

```json
{
  "hits": [
    {
      "id": 123,
      "kind": "story",
      "author": "pg",
      "created_at": "2026-01-01T00:00:00Z",
      "title": "...",
      "url": "...",
      "text": null,
      "score": 42,
      "comment_count": 7,
      "story_id": 123,
      "story_title": null,
      "parent_id": null
    }
  ],
  "total_hits": 1234,
  "page": 0,
  "page_count": 62,
  "query": "sqlite"
}
```

`ItemPage` (user activity, upvoted, hidden):

```json
{"items": [], "offset": 0, "has_more": false, "total_count": 0}
```

`User`:

```json
{
  "id": "pg",
  "created_at": "2007-02-20T00:00:00Z",
  "karma": 155000,
  "about": "<p>...</p>",
  "submitted_item_ids": [1, 2, 3]
}
```

`about`, `title`, and `text` are raw HTML. Strip tags or render them as text before presenting them.

## Authentication

Public reads need no account. Writes and the personal `upvoted` / `hidden` reads require a session.

```bash
# Non-interactive; password comes from stdin, never argv.
printf '%s\n' "$HN_PASSWORD" | hn login --username USER --password-stdin

hn whoami --json         # {"user_id": "..."} or {"authenticated": false}
hn logout
```

Session file: `~/.config/hn/session.json` (mode `0600`). It contains the HN `user` cookie and must be treated as a secret. Passwords are never persisted.

If a write fails with `unauthenticated`, ask the user to run `hn login`; do not try to guess or reuse credentials.

## Writes (only with explicit user intent)

```bash
hn vote 8863
hn vote 8863 --down
hn vote 8863 --undo
hn submit --title "..." --url https://example.com
hn submit --title "..." --text "..."
hn comment 8863 --text "..."
hn edit 8863 --text "..."
hn delete 8863 --yes
hn favorite 8863            # --undo to remove
hn hide 8863                # --undo to unhide
hn flag 8863 --reason spam
hn unflag 8863
```

Success shape: `{"ok": true, "action": "...", "item_id": 8863}` (or `comment_id`). Hacker News writes are unofficial and depend on HTML forms; errors such as `rate_limited`, `unsupported`, or `invalid_input` are expected failure modes.

Interactive `hn comment <id>` without `--text` prints parent context and opens `$VISUAL`/`$EDITOR`; on failure it saves a draft. `hn drafts` lists drafts and `--use-draft` resumes them. Agents should normally pass `--text` or `--text -` (stdin) instead of opening an editor.

## Errors

With `--json`, errors go to stderr:

```json
{"ok": false, "error": {"code": "not_found", "message": "item 1 not found"}}
```

Codes: `invalid_input`, `not_found`, `unauthenticated`, `invalid_credentials`, `unauthorized`, `unsupported`, `rate_limited`, `server_error`, `transport_error`, `decoding_error`, `cancelled`.

Exit codes: `0` success, `1` error.

## Environment

| Variable | Meaning |
| --- | --- |
| `HN_JSON` | Same as `--json` |
| `HN_CONFIG_DIR` | Config directory (default `~/.config/hn`) |
| `HN_PASSWORD` | Password for non-interactive login; prefer `--password-stdin` |
| `HN_SITE_URL` | Override the HN HTML base URL (tests) |
| `HN_FIREBASE_URL` | Override the Firebase base URL (tests) |
| `HN_ALGOLIA_URL` | Override the Algolia base URL (tests) |
| `NO_COLOR` | Disable ANSI color in human output |
| `VISUAL`, `EDITOR` | Editor for interactive text entry |

## Notes for coding agents

- `hn` is also a Rust library (`hn_cli`); adapters and the domain model are public modules.
- Keep transport concerns out of `src/domain.rs`.
- Never test writes against a real account. Use a local fake HN server and `HN_SITE_URL` / `HN_CONFIG_DIR` as the test suite does.
- Build with `cargo check`, test with `cargo test`, and format with `cargo fmt` before proposing changes.
- The interactive browser owns the terminal. Do not run `hn browse` from a non-TTY process; use the line-oriented commands instead.
