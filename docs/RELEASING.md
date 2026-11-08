# Releasing

Releases are built by GitHub Actions from a version tag.

## 1. Update the version

Update:

- `Sources/hn/Version.swift`
- `CHANGELOG.md`

Commit the change:

```bash
git add Sources/hn/Version.swift CHANGELOG.md
git commit -m "Release v0.3.0"
git push origin main
```

## 2. Tag and push

```bash
git tag -a v0.3.0 -m "v0.3.0"
git push origin v0.3.0
```

The `Release` workflow will:

1. Run the test suite.
2. Build a universal `arm64`/`x86_64` binary.
3. Ad-hoc sign it.
4. Package `hn-v0.3.0-macos-universal.tar.gz` and a stable `hn-macos-universal.tar.gz` alias.
5. Publish a GitHub release with `checksums.txt`.

Wait for the workflow:

```bash
gh run list --workflow=release.yml --limit 1
gh run watch
```

## 3. Update the Homebrew tap

Download the checksum:

```bash
gh release download v0.3.0 -R kaushalvivek/hn-cli -p checksums.txt -D /tmp/hn-release --clobber
cat /tmp/hn-release/checksums.txt
```

Update `Formula/hn.rb` in
[`kaushalvivek/homebrew-tap`](https://github.com/kaushalvivek/homebrew-tap):

- `url` → the versioned release asset
- `sha256` → the matching checksum
- `version`, if present
- the `test` version string

Commit and push:

```bash
git -C ../homebrew-tap add Formula/hn.rb
git -C ../homebrew-tap commit -m "hn 0.3.0"
git -C ../homebrew-tap push
```

## 4. Verify

```bash
brew update
brew reinstall kaushalvivek/tap/hn
brew test kaushalvivek/tap/hn
hn --version

HN_INSTALL_DIR=/tmp/hn-install sh install.sh
/tmp/hn-install/hn --version
```
