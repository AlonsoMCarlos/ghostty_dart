# 0009. Keep the package names without asking the Ghostty maintainers first

**Status:** Accepted (2026-11-09). Supersedes the "Before the first pub.dev release, we ask the Ghostty maintainers" line of ADR 0007. The rest of ADR 0007 stands.

## Context
ADR 0007 chose the names `ghostty_dart`, `ghostty_dart_flutter` and `ghostty_dart_xterm`, and planned to ask the Ghostty maintainers about them before the first pub.dev release.

Three things weighed against waiting for that answer:
- The names follow the existing ecosystem pattern (`go-libghostty`, `libghostty-rs`, `ts-libghostty`).
- They use the mark only to describe what the packages bind to (nominative use).
- Every README carries the "unofficial, not affiliated" notice.

## Decision
The maintainer decided to keep the names and publish without asking first. The unofficial notice and the rule against using the Ghostty logo or visual identity stay mandatory.

## Consequences
- The first release is not blocked on an external reply.
- pub.dev names are permanent. If the Ghostty project or Hack Club ever objects, we would have to publish under new names and discontinue the old packages (pub.dev's "discontinued, replaced by" flag), which is a visible cost for users.
