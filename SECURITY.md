# Security

## Supported versions

The latest release receives security fixes. Older releases may not.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting on this repository:

<https://github.com/kaushalvivek/hn-cli/security/advisories/new>

Do not open a public issue for a vulnerability.

For non-security questions, use [vivekkaushal.com/talk](https://vivekkaushal.com/talk).

## Session handling

- `hn login` stores only Hacker News' `user` session cookie.
- The session file is written to `~/.config/hn/session.json` with mode `0600`.
- Passwords are never written to disk.
- The cookie is a credential. Do not share it, commit it, or paste it into issues.
- `hn logout` removes the local session and attempts to invalidate it on Hacker News.

## Write actions

Hacker News has no official write API. Voting, submitting, commenting, editing, deleting, favoriting, hiding, and flagging use HN's HTML forms and session tokens. These are unofficial interfaces and may change without notice. Only perform actions you intend to perform on your real account.
