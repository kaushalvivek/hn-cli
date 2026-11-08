# Contributing

Thanks for helping make `hn` better.

## Requirements

- macOS 14 or newer
- Swift 6.0+ / Xcode 16+
- A terminal with truecolor support is recommended

## Development

```bash
git clone https://github.com/kaushalvivek/hn-cli.git
cd hn-cli
swift test
swift run hn --limit 5
swift run hn browse
```

Use `swift run hn` while developing so the installed release binary is untouched.

## Architecture

The project is a single Swift package with four targets:

| Target | Responsibility |
| --- | --- |
| `HackerNewsCore` | Pure domain model and operations. No networking. |
| `HackerNewsAdapters` | Firebase, Algolia, and HN HTML/session adapters. |
| `HackerNewsTUI` | Terminal renderer, input parser, state, and interactive browser. |
| `hn` | ArgumentParser command line surface. |

The domain model is documented in [`docs/DomainModel.md`](docs/DomainModel.md). Keep transport concerns out of `HackerNewsCore`; adapters translate between the outside world and the domain.

## Testing

```bash
swift test
swift build -c release --arch arm64 --arch x86_64
```

Adapter tests use a local mock HTTP client. Do not add tests that require real HN credentials or perform write actions against a real account.

## Style

- Prefer small, focused types and explicit names.
- Keep terminal rendering deterministic; avoid printing directly from state/actions.
- Preserve the user's terminal state on every exit path.
- Never log credentials, cookies, or full session files.

## Pull requests

- Explain the problem and the approach.
- Include a screenshot or recording for visible TUI changes.
- Keep unrelated refactors out of the same change.
- Make sure CI is green.

## Reporting security issues

Please follow [`SECURITY.md`](SECURITY.md) instead of opening a public issue.

## Contact

Questions or ideas: [vivekkaushal.com/talk](https://vivekkaushal.com/talk)
