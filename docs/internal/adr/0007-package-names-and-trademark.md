# 0007. Package names and the Ghostty trademark

**Status:** Accepted (2026-11-09). Supersedes the package names in ADR 0002 and ADR 0004.

## Context
"Ghostty" and its marks belong to Hack Club, the non-profit fiscal sponsor that took them over in Dec 2025 (https://mitchellh.com/writing/ghostty-non-profit). Ghostty publishes no trademark policy (checked 2026-11-09). The MIT licence covers the code, not the name. Ecosystem bindings name themselves after the language: `go-libghostty` (by Mitchell), `libghostty-rs`, `ts-libghostty`. The earlier names (`ghostty_vt`, `ghostty_vt_flutter`, `ghostty_xterm`) could read as official packages. pub.dev names are permanent.

## Decision
- The package names are `ghostty_dart` (bindings and idiomatic API), `ghostty_dart_flutter` (widget) and `ghostty_dart_xterm` (xterm-compatible adapter). They are descriptive ("Ghostty for Dart") and follow the ecosystem pattern.
- Every README states that the project is unofficial and not affiliated with or endorsed by the Ghostty project or Hack Club. We do not use the Ghostty logo or imitate its visual identity.
- Before the first pub.dev release, we ask the Ghostty maintainers whether they are fine with the names, and rename if they object.

## Consequences
- The names are longer, but nobody will mistake the packages for official ones.
- An objection from the maintainers before 0.1.0 costs only a rename.
