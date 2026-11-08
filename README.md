<div align="center">
  <img src="docs/assets/logo.svg" width="96" height="96" alt="hn logo">
  <h1>hn</h1>
  <p><strong>Hacker News, beautifully in your terminal.</strong></p>
  <p>An interactive full-screen browser and a scriptable CLI for <a href="https://news.ycombinator.com">news.ycombinator.com</a>.</p>

  <p>
    <a href="https://github.com/kaushalvivek/hn-cli/actions/workflows/ci.yml"><img src="https://github.com/kaushalvivek/hn-cli/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
    <a href="https://github.com/kaushalvivek/hn-cli/releases/latest"><img src="https://img.shields.io/github/v/release/kaushalvivek/hn-cli?style=flat-square&color=ff6600" alt="Latest release"></a>
    <a href="https://github.com/kaushalvivek/hn-cli/blob/main/LICENSE"><img src="https://img.shields.io/github/license/kaushalvivek/hn-cli?style=flat-square" alt="License"></a>
    <img src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey?style=flat-square" alt="macOS 14+">
    <a href="https://github.com/kaushalvivek/homebrew-tap"><img src="https://img.shields.io/badge/homebrew-kaushalvivek%2Ftap%2Fhn-orange?style=flat-square" alt="Homebrew"></a>
  </p>
</div>

<img src="docs/assets/tui.svg" alt="hn interactive terminal browser" width="100%">

## Install

### Homebrew

```bash
brew install kaushalvivek/tap/hn
```

> Homebrew 7 may ask you to trust a third-party tap on first use. If prompted, run `brew trust kaushalvivek/tap`.

### Install script

```bash
curl -fsSL https://raw.githubusercontent.com/kaushalvivek/hn-cli/main/install.sh | sh
```

Installs a universal macOS binary to `~/.local/bin`. Override the destination with `HN_INSTALL_DIR`.

### Direct download

```bash
VERSION=0.2.0
curl -LO "https://github.com/kaushalvivek/hn-cli/releases/download/v${VERSION}/hn-v${VERSION}-macos-universal.tar.gz"
curl -LO "https://github.com/kaushalvivek/hn-cli/releases/download/v${VERSION}/checksums.txt"
shasum -a 256 -c checksums.txt --ignore-missing
tar -xzf "hn-v${VERSION}-macos-universal.tar.gz"
mkdir -p ~/.local/bin
install -m 755 hn ~/.local/bin/hn
```

The release is a universal binary for Apple Silicon and Intel Macs.

### Mint

```bash
mint install kaushalvivek/hn-cli
```

### From source

```bash
git clone https://github.com/kaushalvivek/hn-cli.git
cd hn-cli
make install
```

Requires macOS 14+ and Swift 6 / Xcode 16+.

### Updating

```bash
brew upgrade hn
```

### Uninstalling

```bash
brew uninstall hn
```

## Quick start

```bash
hn                          # open the interactive browser
hn browse --feed new        # start on a specific feed
hn front --limit 10         # line-oriented output
hn thread 8863              # story + comment tree
hn search "swift concurrency" --sort date
hn login                    # authenticated actions
hn whoami
```

Run `hn --help` or `hn <command> --help` for the full surface.

## The interactive browser

`hn` opens a full-screen terminal app with a feed sidebar, story list, detail pane, and threaded comments.

- Keyboard-first, with mouse support for clicking and scrolling
- Lazy comment trees with instant collapse/expand
- Search, command palette, help overlay, login modal, and toasts
- Vote, favorite, hide, flag, comment, edit, delete, and submit without leaving the terminal
- Fast feed loading from HN's HTML, with structured Firebase/Algolia adapters underneath

| Key | Action |
| --- | --- |
| `j` / `k`, `↑` / `↓` | Move |
| `g` / `G` | Top / bottom |
| `Enter` / `l` | Open |
| `Tab` | Next pane |
| `Esc` / `h` | Back / close |
| `Space` | Expand or collapse replies |
| `/` | Search |
| `:` or `Ctrl-P` | Command palette |
| `r` | Refresh |
| `o` / `y` | Open in browser / copy URL |
| `v` / `V` / `u` | Upvote / downvote / unvote |
| `f` / `F` | Favorite / unfavorite |
| `H` / `U` | Hide / unhide |
| `!` | Flag |
| `c` / `e` / `d` | Comment / edit / delete |
| `s` | Submit a story |
| `L` | Log in |
| `?` | Keyboard help |
| `q` / `Ctrl-C` | Quit |

## Scriptable CLI

The line-oriented commands are designed for pipes, scripts, and quick one-off reads.

| Command | Description |
| --- | --- |
| `hn front`, `hn new`, `hn best` | Core feeds |
| `hn ask`, `hn show`, `hn jobs` | Ask HN, Show HN, and jobs |
| `hn active`, `hn comments` | Active threads and latest comments |
| `hn noob-stories`, `hn noob-comments` | New low-karma submissions and comments |
| `hn past [YYYY-MM-DD]` | Past front page |
| `hn from <domain>` | Submissions from one site |
| `hn item <id>` | One item |
| `hn thread <id>` | Story or comment tree |
| `hn context <comment-id>` | Comment plus its ancestor chain |
| `hn user <username>` | Profile and activity |
| `hn search <query>` | Search stories and comments |
| `hn leaders`, `hn updates` | Leaders and recent changes |
| `hn upvoted`, `hn hidden` | Your upvoted and hidden items |

### Authenticated actions

```bash
hn login
hn vote 8863
hn submit --title "..." --url https://example.com
hn comment 8863 --text "..."
hn edit 8863 --text "..."
hn delete 8863 --yes
hn favorite 8863
hn hide 8863
hn flag 8863 --reason spam
hn unflag 8863
hn logout
```

Hacker News has **no official write API**. Authenticated actions use the site's HTML forms, session cookie, and per-page tokens. The session file is stored at `~/.config/hn/session.json` with `0600` permissions; passwords are never persisted. Because these interfaces are unofficial, write actions can break if HN changes its markup.

## Configuration

| Variable | Purpose |
| --- | --- |
| `HN_CONFIG_DIR` | Directory for the saved session (default `~/.config/hn`) |
| `HN_PASSWORD` | Password for non-interactive `hn login` |
| `NO_COLOR` | Disable color in line-oriented output |
| `COLUMNS` | Output width for line-oriented wrapping |

## Architecture

`hn` is a Swift package with clean separation between the product model and the outside world:

| Target | Responsibility |
| --- | --- |
| `HackerNewsCore` | Domain entities, value objects, ports, and operations. No networking. |
| `HackerNewsAdapters` | Firebase, Algolia, and HN HTML/session adapters. |
| `HackerNewsTUI` | Terminal renderer, input parser, state, and interactive browser. |
| `hn` | ArgumentParser command surface. |

The domain model and capability boundary are documented in [`docs/DomainModel.md`](docs/DomainModel.md). Release instructions live in [`docs/RELEASING.md`](docs/RELEASING.md).

## Development

```bash
swift test
swift build -c release --arch arm64 --arch x86_64
swift run hn
```

The test suite covers the domain model, Firebase and Algolia decoding, HN HTML parsing, session handling, terminal input parsing, screen rendering, and TUI state.

## Contributing

Contributions are welcome. Start with [`CONTRIBUTING.md`](CONTRIBUTING.md). For security issues, use [`SECURITY.md`](SECURITY.md).

Questions, ideas, or feedback: [vivekkaushal.com/talk](https://vivekkaushal.com/talk)

## License

[MIT](LICENSE) © 2026 Kaushal Vivek

`hn` is not affiliated with Y Combinator or Hacker News. Thanks to Hacker News for the API, Algolia for search, and the Swift open-source ecosystem.
