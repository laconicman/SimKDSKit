# Tech Debt

The numbered register. Reference an item from code as `// TODO(SK-n): …` so the
marker and the register stay linked.

## SK-1 — Strict decoding vs Kotlin's tolerant parsing

The Kotlin client accepted field aliases (`ticketId`/`id`,
`displayNumber`/`ticketNumber`/`number`), enum synonyms (`queued`→new,
`cooking`→in_progress), boolean availability signals, and three wire contracts.
The generated client decodes strictly: one out-of-spec value fails the whole
feed (→ offline banner + Reconnect).

**Cost:** a backend that sends tolerated-but-nonconforming payloads works on
Android and fails on iOS.
**Discharge:** either prove no real backend needs it (conformance checker is the
enforcement path), or add a normalization middleware / per-ticket salvage layer
behind `KdsAPI` — escalated on evidence, not speculatively.

## SK-2 — Keychain items use the default access group

`CredentialStore` stores the token in the default team-prefixed keychain group,
not an App Group. An App Group binds the package to an entitlement no current
target needs.

**Cost:** on a developer-account transfer, stored tokens are stranded
(QA1726/TN2311 — the reason YDelivery chose an App Group from day one); a future
extension target cannot read the credential.
**Discharge:** introduce an app group the day an extension target ships or an
account transfer is planned; `inAppGroup(id:)` pattern from YDeliveryKit applies.

## SK-3 — Polling is the only feed

The feed refreshes on a 2 s timer while the scene is active, mirroring Android.

**Cost:** latency and radio use a push channel would not pay.
**Discharge:** SSE/WebSocket per the upstream `open-integration-roadmap.md`;
the engine's snapshot merge already accepts out-of-band arrivals.

## SK-4 — Station directory refetched on every poll

`KdsFeedEngine.refreshSnapshot` calls `fetchStations` alongside every 2 s ticket
poll — a faithful port of Android `refreshActiveSnapshot`
(`FakeKdsRepository.kt:300-303`), kept so the first release matches the
reference behaviour. Tracked as issue #6.

**Cost:** one directory GET per poll, doubling request volume for data that
changes when a station is added or deactivated — rarely.
**Discharge:** fetch on `start()`, on backend-identity change in
`updateSettings`, and on a slow cadence (every Nth poll or ~60 s); the engine
already keeps `state.stationDirectory` as the fallback. Proposed upstream too
(`Upstream/simkds-android-findings.md`, row 19).

## SK-5 — Contract gaps the client cannot close alone

Recall/undo, item-level fulfilment, the expediter gate, hold/release and a
backend `priority` are standard on shipping KDS products and absent from Generic
KDS API v1; three precision fixes to the v1 text (`ticketId` uniqueness,
version bump on server-side merges, `Idempotency-Key` resolution) are owed as
well. All written up with evidence in `Upstream/generic-kds-api-v1-proposals.md`;
issue #9 is the tracking copy.

**Cost:** an operator who mis-taps *Ready* has no way back; multi-station
kitchens cannot be served correctly; a backend that merges content without
bumping `version` produces spurious 409s.
**Discharge:** upstream adopts the proposals (all non-breaking under the
document's own rules) and the vendored `openapi.yaml` is re-vendored; the
reducer then gains its first backward transition. Presentational items
(all-day counts, sound, bump-bar keys) need no contract change and sit in
<doc:Roadmap>.
