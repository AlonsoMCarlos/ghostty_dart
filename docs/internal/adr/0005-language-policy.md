# 0005. Language policy: English code, bilingual docs

**Status:** Accepted (2026-11-09)

## Context
Global audience; pub.dev renders only `README.md`. The maintainer and an important share of the target community are Spanish speakers.

## Decision
- **English only:** code, identifiers, comments, dartdoc, commit messages, PR/issue templates, CHANGELOGs, ADRs and `docs/internal/`.
- **English + Spanish:** user-facing docs — every `README.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md` (official Contributor Covenant 3.0 translation), `SECURITY.md`, `MIGRATING_FROM_XTERM.md`, `COMPATIBILITY.md` intro, and the docs site.
- Spanish files live next to the English ones as `<name>.es.md`; both start with a language switcher.
- Each Spanish file carries `<!-- source: <english-file>@<commit-sha> -->`; a CI check warns when the English file changed after that sha.
- The English file is the source of truth. A PR changing an English user-facing doc updates the Spanish one, or the CI warning stays visible.

## Consequences
- Twice the doc surface; keep READMEs short and link to the docs site to limit it.
