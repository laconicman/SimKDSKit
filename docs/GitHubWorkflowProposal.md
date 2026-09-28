# GitHub Workflow Proposal — SimKDSKit

*Survey 2026-09-28, the day 0.1.0 was tagged.* Written to the same brief as
`DiceLab/docs/GitHubWorkflowProposal.md` so the two consolidate: survey first,
proposals cheapest-first, each with the command or file that implements it,
**repo-agnostic** vs **repo-specific** marked, decisions presented not taken.
Where DiceLab's second survey already settled a question the same way, this
one says so rather than re-deriving it.

## What exists today (verified live)

| Capability | State | Evidence |
|---|---|---|
| Tags | **1 annotated tag** `0.1.0` (no `v` prefix — the SwiftPM convention, same as `YandexDeliveryExpress` `0.2.0`) on the merge commit of PR #4 | `git tag -l`, `git show 0.1.0` |
| Releases | **None at survey time** → `0.1.0` created during this pass from the tag annotation | `gh release list` |
| `.github/` | **Absent** — no workflows, templates, release notes config, Dependabot | `ls .github` |
| CI | **None.** Tests (161 as of PR #11) run only on the author's machine; the paid reviewer reads diffs, it does not run tests | `gh api …/actions/workflows` → 0 |
| Review | Devin Review (GitHub App) on every push, steered by `REVIEW.md`; obligations tracked locally with `contrib in laconicman/SimKDSKit --pr N`. Ten PRs, ~45 findings, ledger at 0 on all merged PRs | PR threads |
| Milestones | **None** | `gh api …/milestones` → `[]` |
| Labels | GitHub defaults + `accessibility` (a house default); **no PR or issue carried a label** | `gh label list`, issues #6–#9, #13 |
| Issues | 6 open, all filed by the maintainer's own sessions as follow-ups; used as the tracker (unlike DiceLab, where planning rides in Roadmap.md alone) | `gh issue list` |
| Merge convention | PR #1 **squash**; PRs #2–#5, #10 **merge commits** (decided 2026-09-28 for the stacked stack: reviewed SHAs land verbatim, no re-review from rebasing). All three methods enabled | `git log --merges` |
| `delete_branch_on_merge` | **false** — five branches deleted by hand during the merge train | repo API |
| `allow_auto_merge` / `allow_update_branch` | **false / false** | repo API |
| Branch protection / rulesets | **None** — yet `CLAUDE.md` rule 1 says "`main` is protected". Two direct pushes to `main` in history (initial commit, `docs: README.md`) | `GET …/branches/main/protection` → 404 |
| Visibility, license, topics | **Public**, Apache-2.0, **no topics** | repo API |
| `SECURITY.md` / `CONTRIBUTING.md` / `CODEOWNERS` | Absent (the Android upstream ships a `SECURITY.md`) | `ls` |
| Discussions / Projects / Wiki | Off / **on, unused** / off | repo API |
| Versioning contract | SwiftPM: the **tag is the version**; there is no `MARKETING_VERSION` to assert against. Consumers pin `minorVersion`; source-breaking bumps the minor while 0.x (CLAUDE.md rule 9) | `Package.swift`, CLAUDE.md |
| Stacked-PR lesson | Retargeting a PR to `main` after its base merged **triggers a full re-review** — PR #4's retarget produced 6 findings against code already reviewed twice. Merge commits avoided the rebase re-reviews; the retarget one is unavoidable | PR #4 rounds 5–8 |

Facts that shape the proposals:

- **Solo maintainer with an AI reviewer.** The review gate is the `contrib`
  ledger, not GitHub's review-approval model — you cannot approve your own PR.
- **Tests are the missing check.** Every merge so far relied on the author
  running `swift test` locally; the reviewer never sees a test result.
- **Public repo** → GitHub-hosted macOS runners are free; a badged public repo
  gets DeepWiki's weekly auto-refresh.
- **Issues are already the tracker** (six follow-ups filed from sessions), so
  milestones and labels have something to organise — the reverse of
  DiceLab's situation.
- **Two consumers coming** (`SimKDS` app, later extension targets) pin by
  `minorVersion`, so the tag↔breaking-change discipline matters more here
  than in an app repo.

---

## Proposals — cheapest first

### 1. Repo switches — 1 API call, done (repo-agnostic)

```bash
gh api repos/laconicman/SimKDSKit -X PATCH \
  -F delete_branch_on_merge=true -F allow_auto_merge=true \
  -F allow_update_branch=true -F has_projects=false
```

`delete_branch_on_merge` removes the five-times-repeated manual step;
`allow_update_branch` gives the "Update branch" button that stacked PRs want
after a retarget; `allow_auto_merge` is the precondition for §6; Projects off
because Roadmap.md + issues + milestones are the board (DiceLab reached the
same conclusion). **Applied 2026-09-28.**

### 2. Topics + private vulnerability reporting — 2 calls, done (repo-agnostic)

```bash
gh api repos/laconicman/SimKDSKit/topics -X PUT -f 'names[]=swift' -f 'names[]=swift-package' \
  -f 'names[]=ios' -f 'names[]=kitchen-display-system' -f 'names[]=kds' -f 'names[]=openapi' \
  -f 'names[]=swift-openapi-generator'
gh api -X PUT repos/laconicman/SimKDSKit/private-vulnerability-reporting
```

Topics are discoverability for a public package; private vulnerability
reporting gives `SECURITY.md` (§4) somewhere real to point. **Applied.**

### 3. Labels that map to release-notes sections — 5 labels + one file, done (repo-agnostic pattern, repo-specific set)

The set mirrors the Conventional Commit types already in every PR title plus
the two house concerns, and reuses GitHub's defaults where they fit
(`enhancement`, `bug`, `documentation`):

| Label | Means | Release-notes section |
|---|---|---|
| `breaking` | source-breaking for consumers — minor bump while 0.x | Breaking changes |
| `enhancement` / `bug` | feat / fix | Features / Fixes |
| `upstream` | `Upstream/` notes, proposals to the Android repo or the generator | Upstream |
| `tech-debt` | registers or discharges an `SK-n` | Tech debt |
| `documentation` / `hygiene` | docs / chores | Docs and hygiene |
| `tests` | `Tags.swift`, doubles, suites | Tests and tooling |

`.github/release.yml` maps them; `gh release create --generate-notes` then
groups PRs by section for free. `hygiene` is DiceLab's name for the same
thing — kept identical so the consolidated report has one vocabulary.
**Applied**: labels created, existing issues and open PRs labelled.

*Travels:* the pattern and `hygiene`/`tests`/`breaking`. *Repo-specific:*
`upstream` and `tech-debt` presuppose an `Upstream/` folder and a numbered
debt register — both house conventions, so they travel to the sibling
packages but not to an arbitrary repo.

### 4. Hygiene files — minutes, done (repo-agnostic)

- `SECURITY.md` — scope (no secrets in the package; the two tested surfaces:
  credentials-in-URL rejection, cleartext-only-to-loopback) and the private
  reporting channel. The Android upstream has one; a public package should.
- `.github/pull_request_template.md` — the checklist that has been implicit
  in every PR body so far: tests, doc sync, no generated code, spec changes
  upstream, `breaking` label, release-notes label, **ledger at 0 before
  merge**. The last line is the repo-specific one: it encodes the review
  discipline GitHub cannot (§8).
- `.github/dependabot.yml` — `swift` + `github-actions` ecosystems, monthly.
  Dependabot supports SwiftPM manifests; a generator bump regenerates the
  client on the next build, so CI (§5) is what makes a bump PR safe to merge.
- `CONTRIBUTING.md` — **skipped**, as in DiceLab: the human-facing "how to
  build" is three lines already in README; the agent-facing conventions are
  `CLAUDE.md`/`REVIEW.md`. A pointer file would help nobody the README does not.

### 5. CI: `swift build` + `swift test` on PRs and `main` — one 25-line file, done (repo-agnostic mechanism, repo-specific runner)

```yaml
# .github/workflows/ci.yml — runs-on: macos-26, actions/checkout@v5,
# swift build, swift test; concurrency group cancels superseded runs.
```

Why it is the highest-value item despite being "infrastructure": the paid
reviewer never runs the tests, 161 tests exist, and every merge to date
trusted a local run. Repo-specific parts: `macos-26` because the manifest is
`swift-tools-version: 6.2` (`.defaultIsolation(nil)`) — an older image's
toolchain cannot parse it; the OpenAPI generator is a *build plugin*, so no
extra step regenerates the client. Cost: ~5–8 min per run on a free public
runner. **Watch:** the first run is the proof; if the plugin needs a sandbox
exception on the runner it will say so.

Not in CI, deliberately: `swift package generate-documentation
--warnings-as-errors` — two DocC warnings are known (`CredentialStore`, #13;
`ModeSwitchingKdsAPI` is internal) and would fail it. Add it after #13.

### 6. Auto-merge — 0 setup once §5 is green (repo-agnostic mechanism, repo-specific caveat)

```bash
gh pr merge N --merge --auto
```

Merges itself when the checks reported on the PR are green. **The caveat is
specific to this repo's review model:** Devin Review reports `SUCCESS` *even
when it posted findings* — the check means "the review ran", not "nothing was
found". So `--auto` is a CI gate, never a review gate: queue it only after
`contrib in … --pr N` reads `owed 0 / to re-read 0`. Worth checking in the
Devin Review settings whether the check can be made to fail on open findings;
if it can, `--auto` becomes the complete gate. DiceLab's §3 has the general
version of this caveat.

### 7. Milestones as the 0.x release plan — 1 milestone, done (repo-agnostic habit)

```bash
gh api repos/laconicman/SimKDSKit/milestones -X POST -f title=0.2.0 -f description="…"
gh issue edit 13 --milestone 0.2.0
```

Here milestones earn their keep because issues exist: `0.2.0` now holds #13
(`CredentialStore`) and #15 (Multi-backend Phase 0), both `breaking`, so
consumers take **one** minor bump rather than two — that is the decision the
milestone records. Habit: close the milestone in the same step as the tag
(DiceLab §1 found two milestones left open forever).

### 8. Encode the review discipline — a habit, not a feature (repo-specific)

GitHub's model assumes a human approver; this repo's gate is a bot's findings
plus a local ledger. Three habits make that visible on the platform:

- PR template line: "ledger at 0 before merge" (§4).
- Reply on every thread; `contrib ack` against the fix commit — already the
  practice, now written down.
- **Retarget cost:** merging a base branch and retargeting its dependent
  triggers a full re-review of the dependent. Prefer *opening* dependents only
  after the base merges when the stack is shallow; when it is not (as with
  #2→#3→#4), budget one extra round per retarget and treat its findings as a
  fresh-eyes pass — PR #4's retarget round found real holes.

### 9. Branch protection — decision needed (repo-agnostic options, repo-specific fact)

`CLAUDE.md` rule 1 claims `main` is protected; it was not. Options:

- **(a) Narrow ruleset: block force-push and deletion on `main`** — closes
  the two unrecoverable cases, changes no habit, allows the maintainer's
  direct `docs:` pushes to continue. **Applied 2026-09-28** (ruleset
  `protect main`: `non_fast_forward`, `deletion`), matching DiceLab §5(b).
- **(b) Add "require a pull request before merging"** — makes rule 1 literally
  true; blocks the two-line README pushes the author has made; no review
  count required (self-approval is impossible). Add `required_status_checks:
  CI` once §5 has a green run so the rule waits on tests.
- **(c) Leave at (a)** and reword rule 1 to "everything *of substance* lands
  via PR".

Recommendation: **(b) after CI's first green run** — the cost is one habit
(`docs:` edits go through a PR too, which also gets them reviewed), and it
turns §6 into a real gate. Ruleset addition:

```json
{ "type": "pull_request", "parameters": { "required_approving_review_count": 0,
  "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false,
  "require_last_push_approval": false, "required_review_thread_resolution": true } },
{ "type": "required_status_checks", "parameters": { "strict_required_status_checks_policy": false,
  "required_status_checks": [ { "context": "test" } ] } }
```

`required_review_thread_resolution: true` is the one GitHub-native piece of
the ledger discipline: unresolved review threads block the merge button. Devin
resolves its own threads when it accepts a reply, so this aligns with
`contrib`'s `answered-confirmed` state.

### 10. Release automation on tag push — decision needed (repo-agnostic mechanism, repo-specific assert)

Today: tag by hand → `gh release create`. **The two note sources do not
combine the way one hopes:** `--notes-from-tag` and `--generate-notes` together
created nothing on this repo (silent failure), and `--notes-from-tag` alone
publishes the tag annotation *without* the label-grouped sections from
`release.yml` (§3) — which is what happened to `0.1.0`. The recipe that gives
both, per `gh release create --help` ("additional release notes can be
prepended … with `--notes`"):

```bash
gh release create 0.2.0 --generate-notes \
  --notes "$(git tag -l --format='%(contents:body)' 0.2.0)"
```

The tag body leads, the grouped PR list follows. **`release.yml` is read at
the tagged commit, not from the default branch** — verified: with the file on
`main`, `POST …/releases/generate-notes` for `0.1.0` (whose commit predates it)
returns a flat "What's Changed" list, and passing `configuration_file_path`
answers `400 Could not find a configuration file`. So sections appear from the
first tag that *contains* the file (`0.2.0`); `0.1.0` was retrofitted with the
flat generated list appended to its tag body, and stays that way. Corollary
that travels: commit `release.yml` *before* the tag whose notes should use it.

A workflow can run the same recipe on tag push; the interesting part is what
to *assert*, since SwiftPM has no version file:

```yaml
# .github/workflows/release.yml
on: { push: { tags: ["[0-9]*"] } }
jobs:
  release:
    runs-on: macos-26
    permissions: { contents: write }
    steps:
      - uses: actions/checkout@v5
        with: { fetch-depth: 0 }
      - name: Tag is on main
        run: git merge-base --is-ancestor "$GITHUB_SHA" origin/main
      - name: Package resolves at this tag
        run: swift build
      - run: |
          gh release create "$GITHUB_REF_NAME" --generate-notes \
            --notes "$(git tag -l --format='%(contents:body)' "$GITHUB_REF_NAME")"
        env: { GH_TOKEN: ${{ secrets.GITHUB_TOKEN }} }
```

The two asserts replace DiceLab's `MARKETING_VERSION` check with the SwiftPM
equivalents: the tag points into `main`'s history, and the package builds at
the tag (a consumer resolving `minorVersion` gets exactly this).

Tradeoff: tags become published artifacts (a typo'd tag publishes a release).
Mitigation: the build assert, and `gh release delete`.

### 11. Merge-method surface — optional (repo-agnostic, cosmetic)

Merge commits are the convention (5 of 6); squash was used once, on the
single-commit scaffold. Disabling squash and rebase removes two dropdown
options that would silently change history shape:

```bash
gh api repos/laconicman/SimKDSKit -X PATCH -F allow_squash_merge=false -F allow_rebase_merge=false
```

Keep squash if single-commit PRs should stay single commits on `main`; the
author's atomic-commits preference argues for merge commits everywhere. Not
applied — a preference to state, not to guess.

### 12. DeepWiki badge + steering — optional (repo-specific: public + DeepWiki-indexed)

A badged public repo is on DeepWiki's weekly auto-refresh list; without it the
index sits at whatever commit the maintainer last requested. One README line:
`[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/laconicman/SimKDSKit)`.
A `.devin/wiki.json` steering file is **not** warranted yet: the tree is small
and its byte-mass *is* its knowledge-mass (`deepwiki-steering` skill §1) —
revisit if the wiki starts documenting the generated client instead of the
domain.

---

## Deferred — team-scale or inapplicable here

| Feature | Why not now |
|---|---|
| Required reviewers / CODEOWNERS | One maintainer; the reviewer is a bot whose gate is the ledger, not an approval |
| Issue templates / forms | No external reporters; blank issues work for follow-ups from sessions |
| GitHub Projects | Turned off — Roadmap.md + milestones + issues are the board |
| Discussions | Off; no community |
| Signed-commit requirement | Contributor-authenticity payoff, solo repo |
| SwiftLint / swift-format in CI | Conventions are comment-driven and reviewer-enforced; add if drift appears |
| `CHANGELOG.md` | Release notes (§3, §10) + the DocC `Migration.md` convention cover it |
| Device/integration CI | The integration pass runs against the Android `tools/mock-server` — a Python process; possible in CI later, not before the pass exists |

---

## Rollout

**Done 2026-09-28 (this pass):** §1 switches · §2 topics + PVR · §3 labels +
`release.yml`, issues/PRs labelled · §4 `SECURITY.md`, PR template,
Dependabot · §5 `ci.yml` · §7 milestone `0.2.0` with #13, #15 · §9(a)
ruleset · release `0.1.0` from the tag.

**On CI's first green run:** §9(b) — add the PR-required + CI-status rules to
the ruleset; then §6 becomes usable: `gh pr merge N --merge --auto` after the
ledger reads 0.

**Done when #16 merged:** `0.1.0`'s notes retrofitted with the generated PR
list (flat — see §10 on why the sections cannot apply to a tag that predates
`release.yml`).

**On the next tag (0.2.0):** run the §10 `--generate-notes --notes "$(tag
body)"` recipe by hand once, close the milestone in the same step, then commit
the workflow so 0.3.0 is automatic.

**Decisions owed:** §9 (b vs c) · §10 (automate or keep manual) · §11 (prune
merge methods) · §12 (badge).

---

## Consolidation notes — what travels

| | Travels to any repo | Travels to the sibling Swift packages | Stays here |
|---|---|---|---|
| Switches (§1), topics/PVR (§2), `SECURITY.md`/template/Dependabot (§4), narrow ruleset (§9a), auto-merge with the "not a review gate" caveat (§6), milestone-close habit (§7) | ✓ | ✓ | |
| Label set with `release.yml` | pattern ✓; `hygiene`/`tests`/`breaking` ✓ | `upstream`, `tech-debt` ✓ | |
| CI shape (`swift build && swift test` on `macos-26`) | | ✓ (`YandexDeliveryExpress`, `YooMoneyAPIClient` have neither CI nor `.github/` — same gap, same fix) | runner choice follows each manifest's tools version |
| Tag-only versioning: no version-file assert; assert "tag on main" + "builds at tag" | | ✓ | |
| `release.yml` is read at the tagged commit — commit it before the tag that should use it | ✓ | ✓ | |
| Retarget re-review cost; ledger as the gate; Devin check ≠ findings-free | | ✓ (any repo reviewed by Devin) | |
| DeepWiki badge | public repos ✓ | | |
