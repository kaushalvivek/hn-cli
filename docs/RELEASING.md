# Releasing

Releases are built by GitHub Actions from a version tag.

## 1. Update the version

Update:

- `Cargo.toml` (`version`)
- `CHANGELOG.md`

Run the full gate locally:

```bash
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test --all-targets
cargo build --release
```

Commit the change:

```bash
git add Cargo.toml Cargo.lock CHANGELOG.md
git commit -m "Release v0.4.0"
git push origin main
```

## 2. Tag and push

```bash
git tag -a v0.4.0 -m "v0.4.0"
git push origin v0.4.0
```

The `Release` workflow builds on native runners:

1. macOS universal (`arm64` + `x86_64`, ad-hoc signed).
2. Linux `x86_64`, statically linked against musl.
3. Linux `aarch64`, statically linked against musl.

Each platform runs the test suite and produces both a versioned archive
(`hn-v0.4.0-<platform>.tar.gz`) and a stable alias (`hn-<platform>.tar.gz`).
The release job publishes every archive plus `checksums.txt`.

Wait for the workflow:

```bash
gh run list --workflow=release.yml --limit 1
gh run watch
```

## 3. Update the Homebrew tap

Download the checksums:

```bash
gh release download v0.4.0 -R kaushalvivek/hn-cli -p checksums.txt -D /tmp/hn-release --clobber
cat /tmp/hn-release/checksums.txt
```

Update `Formula/hn.rb` in
[`kaushalvivek/homebrew-tap`](https://github.com/kaushalvivek/homebrew-tap)
with:

- `version "0.4.0"`
- `on_macos` / `on_linux` and `on_arm` / `on_intel` URLs
- the matching `sha256` for each of the three assets
- the `test` version string

Commit and push:

```bash
git -C ../homebrew-tap add Formula/hn.rb
git -C ../homebrew-tap commit -m "hn 0.4.0"
git -C ../homebrew-tap push
```

## 4. Verify

```bash
brew update
brew upgrade hn
brew test kaushalvivek/tap/hn
hn --version

HN_VERSION=0.4.0 HN_INSTALL_DIR=/tmp/hn-install sh install.sh
/tmp/hn-install/hn --version
```

## 5. Local install

```bash
brew upgrade hn
hn --version
```
