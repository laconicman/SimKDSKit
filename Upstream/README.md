# Upstream notes

Drafts for fixing root causes upstream so this package's local divergences can be retired —
or, where the divergence is the better behaviour, so upstream can adopt it. Convention shared
with `YooMoneyAPIClient`, `swift-gitlab`, `swift-appstore`: each note carries **evidence**
(file and line in the upstream source, verified on a stated revision) and a **pasteable
report**. Send only after re-verifying against the current upstream and checking whether the
point has already been made.

This package has two upstreams:

| Upstream | What we take from it | Channel |
| --- | --- | --- |
| **SimKDS** (Android) — `../SimKDS-main`, Forgejo export of `ru.etosimsim.simkds` 0.1.0 | The behaviour being ported *and* the contract we implement: `docs/api.md` + `docs/openapi.yaml` (vendored verbatim as `Sources/SimKDSKit/openapi.yaml`, see [SpecOwnership](../Sources/SimKDSKit/SimKDSKit.docc/SpecOwnership.md)) | Same owner as this package — Forgejo issues, or a direct edit. The most reachable upstream this house has |
| [`apple/swift-openapi-generator`](https://github.com/apple/swift-openapi-generator) | The generated client | Public tracker, responsive maintainers |

## Is there a standard we should be tracking instead?

Checked 2026-09-28, because a home-grown contract is only worth owning if no industry
contract exists. **None does for the POS→KDS ticket lifecycle.** OMG/ARTS (ex-NRF) covers
POSLog, the *Self Service Order Interface* (ordering → POS, the other direction), NAFEM
(kitchen-equipment telemetry) and the Digital Receipt API — nothing for kitchen tickets.
What exists is vendor-specific: Square's Orders API fulfilment states
(`PROPOSED → RESERVED → PREPARED → COMPLETED | CANCELED | FAILED`, one timestamp per
transition), Toast's per-selection `fulfillmentStatus` (`NEW / HOLD / SENT / READY`) with a
proprietary KDS, Oracle Simphony's KDS *configuration* API. Generic KDS API v1 stays the
contract; where it grows, the vocabulary to borrow is Square's — the closest thing to a
lingua franca — and the alignment table lives in
[`generic-kds-api-v1-proposals.md`](generic-kds-api-v1-proposals.md).

## Ready to file — SimKDS (Android)

| Note | Problem | Local state | Status |
| --- | --- | --- | --- |
| [simkds-android-findings](simkds-android-findings.md) | Nineteen defect classes that Devin Review found in the Swift port and that trace, line for line, to the Kotlin original: version rollback on merge, terminal-status resurrection, `station_` regex rejecting valid ids, `Int` quantities, ready-wait measured from creation, station-only provisioning link flipping mock→real, `api_key` bypassing auth-param rejection, `https://` with no host accepted, wholesale rollback clobbering concurrent polls, conflict refresh under stale settings, no backend-identity reset, pre-fetch clock stamps, mock feed unscoped by station, refresh only on `stale_version`, directory refetched every 2 s | **All fixed in this package** on `feat/domain` / `feat/api` / `feat/feed` (commits cited per row); SK-4 records the one we kept | **verified 2026-09-28** against `SimKDS-main` 0.1.0 (Forgejo export, no SHA — `CHANGELOG.md` head). Pasteable tracking issue in Russian at the end of the note |
| [generic-kds-api-v1-proposals](generic-kds-api-v1-proposals.md) | Contract gaps against what every shipping KDS offers (recall/undo, item-level fulfilment, expo gate, hold/release, backend priority), plus three precision fixes to v1 itself: `ticketId` uniqueness in the feed schema, a rule that server-side content merges bump `version`, and sub-second or nonce guidance for `Idempotency-Key` | **None** — the iOS client implements v1 as written; presentational rows go to [Roadmap](../Sources/SimKDSKit/SimKDSKit.docc/Roadmap.md) and need no contract change | Research complete (market matrices + DeepWiki deep read of `openshiporg/openfront-restaurant`, link in note). SK-5 is the reminder; issue #9 the tracking copy |

## Closed without filing

| Note | Outcome |
| --- | --- |
| `swift-openapi-generator`: generated code fails under `-default-isolation MainActor` | **Already tracked upstream — nothing to add.** [#796](https://github.com/apple/swift-openapi-generator/issues/796), [#823](https://github.com/apple/swift-openapi-generator/issues/823) (maintainer's recommended workaround: turn default isolation off in the generated module), [#804](https://github.com/apple/swift-openapi-generator/issues/804) (approachable concurrency vs `ClientMiddleware` signatures). This package's answer is `.defaultIsolation(nil)` in `Package.swift`, recorded in [Design](../Sources/SimKDSKit/SimKDSKit.docc/Design.md) → Concurrency. Re-filing would duplicate three open issues |
| SimKDS: `fetchStations` skips runtime-context validation | **Not a defect.** Station discovery must work before a station is selected; the Kotlin skips validation there (`RealKdsHttpApiClient.kt:24-42`) and the Swift port briefly required one (PR #3 round 2) — a porting error, fixed in `489c52c`, nothing to report |
| SimKDS: `Idempotency-Key` collides for same-second actions | **Kotlin is fine; the doc is not.** `Instant.toString()` carries sub-second precision when present (`RealKdsHttpApiClient.kt:402-403`), so collisions need the same millisecond. The port formatted to seconds and did collide (fixed `4b2e0db`). The *documented example* `…_20260709T100000Z` (`docs/api.md:58`) shows seconds, which is what a backend integrator copies — folded into the proposals note as a documentation fix rather than a bug |

## Filing order

The findings note cites SimKDSKit commits and their regression tests as acceptance tests.
Those commits live on the stacked branches `feat/domain` → `feat/api` → `feat/feed` (PRs #2,
#3, #4) until the stack merges — a report filed before that points upstream at tests they
cannot reach from `main`. **File after the stack lands.** The PRs merge with merge commits,
so the cited SHAs are preserved verbatim on `main`; the note needs no rewrite, only the
merge to happen. Until then the folder is a draft — which is what this folder is for.

## Conventions

- **Verify against the source, not the summary.** Every row in the findings note cites the
  Kotlin file and line. Two review findings that *sounded* upstream were not (table above).
- **A report cites only what upstream can reach.** Branch-only commits and tests are not
  evidence to a reader of `main`; wait for the merge (above) or cite the branch explicitly
  as a branch.
- **Distinguish behaviour from documentation issues**, and say which.
- **Where upstream has a stated rationale, engage it** — `YandexDeliveryExpress` TD-23 is
  the house example: an ordering this package inverted, but for a reason written down.
- **Record the local fix commit** so the note stays useful after the upstream lands or
  declines: the row tells a future session whether the local code can be simplified.
