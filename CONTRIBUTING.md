# Contributing

Thanks for helping make `hn` better.

## Requirements

- macOS or Linux
- Rust 1.88+ (`rustup` recommended)
- A terminal with truecolor support is recommended

## Development

```bash
git clone https://github.com/kaushalvivek/hn-cli.git
cd hn-cli
cargo test
cargo run -- --limit 5
cargo run -- browse
```

Use `cargo run --` while developing so the installed release binary is untouched.

## Quality gate

```bash
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test --all-targets
cargo build --release
```

## Architecture

The project is a single Rust crate with a small domain core and narrow adapters:

| Module | Responsibility |
| --- | --- |
| `src/domain.rs` | Pure domain model and read models. No networking. |
| `src/http.rs` | `HttpTransport` port and the `reqwest` implementation. |
| `src/firebase.rs` | Firebase items, users, feeds, and updates. |
| `src/algolia.rs` | Search and item-tree fast path. |
| `src/site.rs` | news.ycombinator.com HTML, session, login, and write actions. |
| `src/client.rs` | Composed client and thread fallback. |
| `src/cli.rs` | `clap` command surface, human output, JSON output. |
| `src/tui.rs` | `ratatui` interactive browser. |
| `src/drafts.rs` | Shared on-disk drafts. |
| `packaging/nfpm.yaml` | Native Linux package layout (deb, rpm, Arch, Alpine). |
| `docs/hn.1` | Manual page installed by native packages. |
| `docs/index.html` | Landing page source, mirrored into `vivekkaushal.com/public/hn-cli`. |

The domain model is documented in [`docs/DomainModel.md`](docs/DomainModel.md). Keep transport concerns out of `src/domain.rs`; adapters translate between the outside world and the domain.

## Testing

```bash
cargo test --all-targets
```

Unit tests cover the domain model, HN HTML parsing, drafts, and CLI pagination. Authenticated flows must be tested against a local fake HN server using `HN_SITE_URL` and a temporary `HN_CONFIG_DIR`. Do not add tests that require real HN credentials or perform write actions against a real account.

## Style

- Run `cargo fmt` before committing.
- Prefer small, focused types and explicit names.
- Keep terminal rendering deterministic; avoid printing directly from state/actions.
- Preserve the user's terminal state on every exit path.
- Never log credentials, cookies, or full session files.
- Keep JSON output additive and stable; agents depend on it.

## Pull requests

- Explain the problem and the approach.
- Include a screenshot or recording for visible TUI changes.
- Keep unrelated refactors out of the same change.
- Make sure CI is green on macOS and Linux.

## Reporting security issues

Please follow [`SECURITY.md`](SECURITY.md) instead of opening a public issue.

## Contact

Questions or ideas: [vivekkaushal.com/talk](https://vivekkaushal.com/talk)
