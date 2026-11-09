@AGENTS.md

## Claude Code specifics

- `AGENTS.md` (imported above) is the single source of project guidance. Edit it there, not here, so every agent tool sees the same rules.
- The maintainer reads replies in Spanish. Write code, comments, commits and English docs in English.
- Use the `project-memory` skill conventions, adapted to this repo: decisions go to `docs/internal/adr/`, research with sources and dates goes to `docs/internal/research/`.
- For multi-module work, use the `plan-orchestrator` skill. Tasks map to the package boundaries (`ghostty_dart`, `ghostty_dart_flutter`, `ghostty_dart_xterm`).
