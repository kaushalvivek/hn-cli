PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

.PHONY: build release test install

build:
	swift build

release:
	swift build -c release

test:
	swift test

install: release
	install -d "$(BINDIR)"
	install -m 755 .build/release/hn "$(BINDIR)/hn"
