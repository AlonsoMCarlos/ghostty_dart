# Release checklist: first publish of `ghostty_dart` and the automation after it

Implements ADR 0010. Written 2026-11-09. Repository `AlonsoMCarlos/ghostty_dart`, maintainer `AlonsoMCarlos` (user id 42724534).

pub.dev automates publishing only for packages that already exist, so **0.1.0 is published by hand**. After that, every version goes through release-please and `publish.yml`.

Do the steps in this order. Steps 1 to 6 are one-time repository settings; steps 1 and 2 must come **before** any `ghostty_dart-v*` tag is pushed: a tag push starts `publish.yml`, and its `publish` job must find a protected environment waiting for approval (an unknown environment would be auto-created without protection).

## 1. Create the `pub.dev` GitHub environment

The environment needs a required reviewer (you) and may deploy only from tags `ghostty_dart-v*`. Leave "Prevent self-review" off, or a solo maintainer can never approve.

```sh
gh api -X PUT repos/AlonsoMCarlos/ghostty_dart/environments/pub.dev --input - <<'EOF'
{
  "wait_timer": 0,
  "prevent_self_review": false,
  "reviewers": [{ "type": "User", "id": 42724534 }],
  "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true }
}
EOF
gh api -X POST repos/AlonsoMCarlos/ghostty_dart/environments/pub.dev/deployment-branch-policies \
  -f name='ghostty_dart-v*' -f type=tag
```

Check it:

```sh
gh api repos/AlonsoMCarlos/ghostty_dart/environments/pub.dev --jq '{protection_rules, deployment_branch_policy}'
gh api repos/AlonsoMCarlos/ghostty_dart/environments/pub.dev/deployment-branch-policies
```

## 2. Protect the `ghostty_dart-v*` tags

Make a published tag immutable: no update, no deletion, no force move. Admins (you) can bypass the rule: `"actor_id": 5` with `"actor_type": "RepositoryRole"` is GitHub's built-in **Repository admin** role (the same bypass as the existing `native release tags` ruleset).

The rule deliberately leaves out **creation**, unlike the `native-v*` ruleset:
- release-please creates `ghostty_dart-v*` tags with `GITHUB_TOKEN`, and a creation rule would block it.
- What gates a publish is the `pub.dev` environment, not tag creation: it needs your approval and only accepts these tags.

```sh
gh api -X POST repos/AlonsoMCarlos/ghostty_dart/rulesets --input - <<'EOF'
{
  "name": "ghostty_dart release tags",
  "target": "tag",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/tags/ghostty_dart-v*"], "exclude": [] } },
  "rules": [{ "type": "update" }, { "type": "deletion" }, { "type": "non_fast_forward" }],
  "bypass_actors": [{ "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" }]
}
EOF
```

Check it:

```sh
gh api repos/AlonsoMCarlos/ghostty_dart/rulesets --jq '.[].name'   # includes "ghostty_dart release tags"
```

## 3. Protect `main`: pull requests and required checks

Every change reaches `main` through a PR whose checks are green: the three CI `check` jobs, `pana and publish dry run`, `secrets (gitleaks)` and `dco`. Without this, DCO and CI are advisory. Admins bypass it, because you occasionally merge locally (to keep the noreply address as the author); a bypass is logged.

- `integration_id` 15368 is the GitHub Actions app (`gh api /apps/github-actions --jq .id`), so only runs of our workflows satisfy the checks. The release PR's checks come from runs that release-please.yml dispatches on its branch; they attach to the PR's head commit and count the same.
- `required_approving_review_count` is 0: a solo maintainer cannot approve their own PR. Raise it when there is a second maintainer.

```sh
gh api -X POST repos/AlonsoMCarlos/ghostty_dart/rulesets --input - <<'EOF'
{
  "name": "main",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false } },
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [
          { "context": "check (ubuntu-latest)", "integration_id": 15368 },
          { "context": "check (macos-latest)", "integration_id": 15368 },
          { "context": "check (windows-latest)", "integration_id": 15368 },
          { "context": "pana and publish dry run", "integration_id": 15368 },
          { "context": "secrets (gitleaks)", "integration_id": 15368 },
          { "context": "dco", "integration_id": 15368 } ] } }
  ],
  "bypass_actors": [{ "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" }]
}
EOF
gh api repos/AlonsoMCarlos/ghostty_dart/rulesets --jq '.[].name'   # includes "main"
```

If a CI job is renamed, update its context here (the names are the jobs' `name:` in `ci.yml` and `dco.yml`).

## 4. Allow GitHub Actions to create pull requests

release-please opens its release PR with `GITHUB_TOKEN`. That needs the repository setting "Allow GitHub Actions to create and approve pull requests", off by default (today: off); without it the action fails with "GitHub Actions is not permitted to create or approve pull requests". The default token stays read-only; each workflow asks for what it needs.

```sh
gh api -X PUT repos/AlonsoMCarlos/ghostty_dart/actions/permissions/workflow \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true
gh api repos/AlonsoMCarlos/ghostty_dart/actions/permissions/workflow
# {"default_workflow_permissions":"read","can_approve_pull_request_reviews":true}
```

An approval by Actions is not a risk here: the `main` ruleset requires no approving review, and the publish gate is the `pub.dev` environment, which only you can approve.

## 5. Require sign-off on web commits

The DCO check (`dco.yml`, `tool/check_dco.sh`) covers PR commits. This setting covers commits made in the GitHub web UI.

```sh
gh api -X PATCH repos/AlonsoMCarlos/ghostty_dart -F web_commit_signoff_required=true
gh api repos/AlonsoMCarlos/ghostty_dart --jq .web_commit_signoff_required   # true
```

Squash commits that GitHub writes on `main` use the account's default commit email. Enable **Settings → Emails → "Keep my email addresses private"** (and "Block command line pushes that expose my email") so they use the noreply address, matching the sign-offs. Never write a personal email into this repo.

## 6. Reported content (code of conduct reports)

GitHub's "Reported content" setting (Settings → Moderation options → Reported content) exists **only for organization-owned public repositories** (docs.github.com, "Managing how contributors report abuse in your organization's repository", read 2026-11-09); there is no REST endpoint for it. `AlonsoMCarlos/ghostty_dart` is under a personal account, so it cannot be enabled. Reports go through the contact in `CODE_OF_CONDUCT.md` and GitHub's own "Report abuse/content" link, which works on every repository. If the repository moves to an organization, enable it there with "Prior contributors and collaborators".

## 7. Merge the first-release PR (`feat/first-release`)

Merge it into `main` once CI and DCO are green, then take the exact commit it created (not `origin/main`, which may have moved):

```sh
sha="$(gh pr view feat/first-release --repo AlonsoMCarlos/ghostty_dart --json mergeCommit --jq .mergeCommit.oid)"
git fetch origin main
git merge-base --is-ancestor "$sha" origin/main && git log -1 "$sha"
```

## 8. Tag `ghostty_dart-v0.1.0` on that commit

```sh
git tag -a ghostty_dart-v0.1.0 -m "ghostty_dart 0.1.0" "$sha"
git push origin ghostty_dart-v0.1.0
```

The push starts `publish.yml`, which then runs:
- `validate`: the tag against `pubspec.yaml`, `CHANGELOG.md` and `main`, then `mise run check` and the dry run;
- `package`: the offline archive.

Its `publish` job then waits in the `pub.dev` environment. Use the green `validate` and `package` jobs as the final check, then **reject** the deployment. The upload could not succeed anyway: the package does not exist on pub.dev yet. (Observed for 0.1.0: an approved run reached pub.dev, which authenticated the OIDC token and answered "Only users are allowed to upload new packages". Nothing was uploaded.)

## 9. Publish 0.1.0 by hand from a clean checkout of the tag

Use a fresh clone, so that no untracked or ignored local file can end up in the archive.

```sh
dir="$(mktemp -d)"
git clone --branch ghostty_dart-v0.1.0 https://github.com/AlonsoMCarlos/ghostty_dart.git "$dir/ghostty_dart"
cd "$dir/ghostty_dart"
git describe --exact-match HEAD          # ghostty_dart-v0.1.0
mise trust && mise install
mise run deps                            # flutter pub get --enforce-lockfile
mise run publish:dry-run                 # what CI runs: 0 warnings, no hints
(cd packages/ghostty_dart && mise x -- dart pub publish)   # Google sign-in in the browser, then confirm with `y`
```

- `dart pub publish` uploads from your Google account.
  - A later transfer to a verified publisher is possible, but it is irreversible.
- A published version is permanent. Within 7 days it can be **retracted** from the package's admin page on pub.dev (dart.dev/tools/pub/publishing, "Retracting a package version").

Then check:
- `https://pub.dev/packages/ghostty_dart` shows 0.1.0;
- after pana has run (minutes), the score is 160/160.

## 10. Enable automated publishing on pub.dev

Open `https://pub.dev/packages/ghostty_dart/admin` and go to **Automated publishing** > **Enable publishing from GitHub Actions**:

| Setting | Value |
|---|---|
| Repository | `AlonsoMCarlos/ghostty_dart` |
| Tag pattern | `ghostty_dart-v{{version}}` |
| Enable publishing from `push` events | on |
| Enable publishing from `workflow_dispatch` events | **on**. release-please.yml dispatches `publish.yml`, because its own tags start no run. |
| Require GitHub Actions environment | on, environment `pub.dev` |

pub.dev accepts only `push` and `workflow_dispatch` runs whose OIDC token has `ref_type=tag`, `environment=pub.dev` and a tag that matches the pattern with the pubspec version.

## 11. Set the release-please `bootstrap-sha`

The value is the commit of the published 0.1.0, the one tagged in step 8. Do this **in your working clone**, not in the temporary clone of step 9:

```sh
cd <your working clone>
git switch main && git pull --ff-only
git fetch origin --tags
sha="$(git rev-parse 'ghostty_dart-v0.1.0^{commit}')"
jq --arg sha "$sha" '. + {"bootstrap-sha": $sha}' release-please-config.json >release-please-config.json.new
mv release-please-config.json.new release-please-config.json
git switch -c chore/release-please-bootstrap
git commit -s -am "chore: set release-please bootstrap-sha to ghostty_dart 0.1.0"
```

Open a PR and merge it.

- release-please reads `bootstrap-sha` only when it cannot find the release of the manifest version (0.1.0).
  - It does find it, through the tag (`backfillReleasesFromTags`, release-please 17.6.0).
  - So this setting is a fallback: if the tag is missing, history before 0.1.0 never counts as unreleased.
- Until any `ghostty_dart-v*` tag exists, `release-please.yml` skips itself (`tool/release/release_ready.sh`), so merging before step 8 is safe.

## 12. Optional: a GitHub release for 0.1.0

release-please creates GitHub releases for later versions. To have one for 0.1.0 as well:

```sh
gh release create ghostty_dart-v0.1.0 --verify-tag --title "ghostty_dart 0.1.0" \
  --notes "First release. See packages/ghostty_dart/CHANGELOG.md and https://pub.dev/packages/ghostty_dart/versions/0.1.0."
```

## Every later release

1. Conventional, signed-off commits land on `main`. release-please (`release-please.yml`) keeps a release PR open: version bump in `pubspec.yaml`, plus the `CHANGELOG.md` entry.
   - While in 0.x, `feat` bumps the patch and a breaking change bumps the minor (`bump-patch-for-minor-pre-major`, `bump-minor-pre-major`).
   - Only commits touching `packages/ghostty_dart/` count.
2. Its CI and DCO runs are dispatched on the PR branch. They show on the PR's head commit.
   - The branch is `release-please--branches--main--components--ghostty_dart` (`separate-pull-requests` in the config).
   - If they are missing, run `mise run release:dispatch pr release-please--branches--main--components--ghostty_dart` with `GH_TOKEN` and `GH_REPO=AlonsoMCarlos/ghostty_dart` set.
3. Merging the PR makes release-please tag `ghostty_dart-v<version>` and create the GitHub release. It then dispatches `publish.yml` on that tag.
4. Before approving the `publish` job in the `pub.dev` environment, **verify yourself that the tag is on `main`**. The green `validate` job is not enough: it is defined by the workflow file at the tag, so a tag on another commit could carry an edited one.

   ```sh
   gh api repos/AlonsoMCarlos/ghostty_dart/compare/ghostty_dart-v<version>...main --jq .status   # must be "ahead" or "identical"
   ```

   Then approve, once `validate` and `package` are green. The job uploads only an archive whose sha256 matches the one `package` produced.
5. If the dispatch did not happen, run `mise run release:dispatch publish ghostty_dart-v<version>` (it refuses a tag that is not on `main`), or `gh workflow run publish.yml --ref ghostty_dart-v<version>`.

Never put a prerelease version (`-dev.N`) in `pubspec.yaml` while release-please owns it. Its Dart updater mangles them (release-please issue #2400), and `publish.yml` refuses them.

## First publish of `ghostty_dart_xterm` (later)

The adapter (ADR 0013) is a workspace member at `0.0.1-dev` and stays unpublished until the maintainer approves it. It cannot pass pana before `ghostty_dart_flutter` is on pub.dev: pana resolves the archive's dependencies from pub.dev, and `ghostty_dart_flutter: ^0.0.1-dev` does not exist there yet. So it is deliberately **not** in the CI `pana and publish dry run` job, `mise run pana`'s default list or `publish:dry-run`. When `ghostty_dart_flutter` is published:

1. Set the dependency to the published `ghostty_dart_flutter` version and choose the first version (`0.1.0`), with a matching `CHANGELOG.md` entry.
2. Add `packages/ghostty_dart_xterm` to the `pana` task's default list, the `publish:dry-run` task and the CI `pana` job, and to release-please's config (`release-please-config.json`, manifest) with its own component.
3. `mise run pana packages/ghostty_dart_xterm` must give 160/160. Consider pubspec `screenshots` (AGENTS.md asks for them on widget packages; pana needs `webp` for them).
4. Extend the `pub.dev` environment's deployment tag policy and the tag ruleset (steps 1 and 2) to `ghostty_dart_xterm-v*`, then publish the first version by hand as in steps 7 to 10, with `ghostty_dart_xterm` in place of `ghostty_dart`.
5. Check `COMPATIBILITY.md` is current (`mise run compat:check`) and that `MIGRATING_FROM_XTERM.md` and the README no longer say "not published".
