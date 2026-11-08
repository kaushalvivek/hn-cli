PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
CARGO ?= cargo

.PHONY: build release test fmt lint install

build:
	$(CARGO) build

release:
	$(CARGO) build --release

test:
	$(CARGO) test

fmt:
	$(CARGO) fmt

lint:
	$(CARGO) clippy --all-targets -- -D warnings

install: release
	install -d "$(BINDIR)"
	install -m 755 target/release/hn "$(BINDIR)/hn"
