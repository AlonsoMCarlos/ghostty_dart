**English** | [Español](CONTRIBUTING.es.md)

# Contributing

Thanks for your interest in ghostty_dart. This is an independent,
unofficial project; it is not part of Ghostty. Bug reports, fixes, tests
and documentation are all welcome. For a large change, open an issue first
so we can agree on the approach before you invest time in it.

This page is the short version. [`AGENTS.md`](AGENTS.md) is the full guide
(for humans and AI agents alike), and the decisions behind the project are
recorded as ADRs in [`docs/internal/adr/`](docs/internal/adr).

## Setup

Every tool is managed by [mise](https://mise.jdx.dev), at the exact versions
in `mise.toml` (Flutter and its Dart SDK, Zig, minisign, jq and others):

```sh
mise install            # the pinned tools
mise run deps           # flutter pub get --enforce-lockfile
mise run native:host    # build libghostty-vt for this machine (tests need it)
mise run check          # everything CI runs
```

`mise tasks` lists every task. Do not install project tools globally or by
hand; add them to `mise.toml`. Only a few things come from your system:
`libclang-dev`, needed only to regenerate the bindings (`mise run ffigen`),
and the Android SDK or Xcode, needed only for mobile builds.

## Code

- Code, comments, dartdoc and commit messages are in English.
- Run `mise run format`; `mise run analyze` must report zero infos.
- If you change `pubspec.yaml`, a README or dartdoc, also run
  `mise run pana` and `mise run publish:dry-run`.
- Every behaviour change ships with tests.
- Never edit the generated `lib/src/ffi/bindings.g.dart`; regenerate it.
- Changes to `ghostty_dart` follow the conventions of ADR 0006
  ([`docs/internal/architecture/ghostty_dart-conventions.md`](docs/internal/architecture/ghostty_dart-conventions.md)).
- If a change contradicts an ADR, propose a new ADR that supersedes it.

## Commits and pull requests

- Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/),
  for example `fix(ghostty_dart): …` or `docs: …`. Releases and changelogs
  are generated from them.
- **The pull request title must be a Conventional Commit too**: squash
  merges use it as the commit message.
- Sign off every commit with `git commit -s`. The `Signed-off-by` line
  certifies the [Developer Certificate of Origin](https://developercertificate.org),
  and it must match the commit author.
- Fill in the pull request template's checklist.

## Supply chain

Build-time code (build hooks, scripts) runs with your permissions, and our
build hook runs on users' machines, so these rules are strict:

- `pubspec.lock` is committed. Never run `dart pub upgrade` blindly, and
  review every lockfile diff.
- No dependency version published less than 3 days ago
  (`mise run cooldown` checks the lockfile).
- No new dependency in `ghostty_dart` without a justification in the pull
  request.
- GitHub Actions are pinned by commit SHA.
- Read a library's source in `~/.pub-cache` before relying on its API,
  rather than compiling throwaway projects with unpinned code.

## Documentation in two languages

User-facing docs are bilingual: `X.md` is in English and is the source of
truth, and `X.es.md` is its Spanish translation. If you change an English
file, update the Spanish one in the same pull request, or ask for help with
the translation in the pull request.

Each Spanish file starts with a header that records which English text it
translates:

```markdown
<!-- source: X.md@<blob sha> -->
[English](X.md) | **Español**
```

The sha is `git hash-object X.md` of the final English file.
`mise run docs:translations` (part of `mise run check`) reports
translations that are behind (a warning) and missing or malformed headers
(an error).

## AI-assisted contributions

AI tools are welcome; this repository itself is developed with them. Two
rules apply:

- **Disclose it.** Say in the pull request which tool you used and for
  what.
- **Own it.** You must understand, and be able to explain, every line you
  submit. Do not post unreviewed AI-generated text in issues or reviews.

## Conduct and security

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).
Do not report vulnerabilities in issues: follow the
[security policy](SECURITY.md).
