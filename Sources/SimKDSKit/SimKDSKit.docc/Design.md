# Design

Every load-bearing decision, with the alternative that was rejected.

## The module boundary is compiler-enforced

Generated `Client`/`Components` are emitted with `package` access
(`openapi-generator-config.yaml`). The app's rule "generated types stop at the
package boundary" is therefore not a convention a review must catch but a fact
the compiler enforces: the module's public surface is entirely hand-written —
domain types, ``KdsAPI``, stores, ``MockKdsAPI``.

*Rejected alternative:* `accessModifier: public` plus a REVIEW.md flag (the
YDelivery pattern). That exists because the API package there *is* the product;
here the product is the domain + facade, and the generated code is plumbing.

## One client, rebuilt on context change

`Client` is created from a `KdsContext` + `KdsCredentials` snapshot in
``Client/init(serverURL:credentials:context:)``. Settings change rarely
(provisioning, manual edit), so the app rebuilds the client rather than
mutating shared reference state. Context headers (`X-SimKDS-*`,
`Idempotency-Key`, `X-Request-Id`) travel as generated operation parameters on
each call; only auth goes through middleware — per-request values belong to the
caller, per-session values to the chain.

## Strict decoding

The generated `Codable` conformances throw on out-of-spec enum values and
missing required fields; the Kotlin client tolerated aliases and synonyms
per-field. Accepted deliberately: Generic KDS API v1 is a closed contract with a
conformance checker (`tools/conformance/` upstream), and a malformed feed
surfaces as a feed error + reconnect affordance — the same path Kotlin takes on
a missing required field. The delta is registered as SK-1 in <doc:TechDebt>.

*Rejected alternative:* a normalization middleware or per-ticket salvage decoder
— machinery whose only current consumer is hypothetical non-conforming backends.

## Settings and credentials are separate stores

`KdsDeviceSettings` carries no secrets — the Android `apiKey`/Basic-Auth fields
do not exist. The token lives in `CredentialStore` (Keychain), consulted at
client-build time and deleted when provisioning flags a target change. The
Android Keystore AES codec is not ported: Keychain is the encrypted store, so
the codec was mechanism without a problem.

## The feed engine is pure

`KdsFeedEngine` holds the transition logic the Kotlin `FakeKdsRepository` mixed
with coroutines: optimistic dispatch, failure rollback, refresh-on-conflict,
snapshot merge, dedupe, persistence intent. It takes `now` as a parameter and
returns new state — the app's controller owns the Tasks, the clock, and the
stores. This is what makes the repository test-suite a package suite instead of
an app suite, and it is what a future widget would reuse.

## What the port deletes

Recorded so the Android file can still be read as reference without mistaking
absence for oversight:

- `KdsHttpContract` / contract picker — GenericKds only (v1 scope decision).
- `KdsStationFilter` enum — filtering keys on `stationId`; the station directory
  supplies labels.
- `requiresPaymentFiscalGate` — the paid+fiscal gate was SimCafeAlpha semantics;
  GenericKds backends decide visibility server-side.
- `orderId`, `statusUpdatedAt` — not in the Generic spec (were legacy
  tolerance); ready-wait uses `readyAt` (stamped by the reducer) plus the
  snapshot map.
- Basic Auth — its only consumer was the SimCafe staging contour.
- `10.0.2.2` from the loopback list — the Android emulator's host alias.

One deliberate mapping fix: `delivery` source → `.online` (the Kotlin table left
it `Unknown`; a delivery order is an online-channel ticket for board purposes).

And two deliberate renames, same authority: the model carries spec field names
(`displayNumber`, `visibleAt`), not the Kotlin ones (`number`, `createdAt`).
`KdsAction` addresses tickets by `ticketId` only — the Generic wire always has
one, so the Kotlin number-or-id fallback addressing went with it;
`displayNumber` still rides on the action for operator-facing error text.

## Review-round repairs (PR #2)

Devin Review's pass on the domain port caught real defects; they were fixed
rather than ported, and the differences from the Android file are deliberate:

- **Optimistic version survives a stale poll.** `mergeRemoteTicket` keeps
  `max(local, remote)` when local status wins — otherwise the next action's
  `expectedVersion` went out stale and 409-looped.
- **Line availability is display metadata.** The backend owns the active set;
  a ticket with an unavailable line stays on the board with the line marked.
  Ticket-level `availabilityState` still gates (it is a whole-ticket verdict).
- **`readyAt` carries the ready transition.** Optimistic mark-ready stamps it
  from `occurredAt`; a remote ticket first seen ready is stamped at poll time.
  Ready-wait measures pickup time, not prep+pickup.
- **`quantity` is `Double`.** The spec says positive number; weighted items
  (0.5 kg) are legal wire values.
- **Station/device params don't flip mock→real.** Only backend-target params
  (`api`, `apiBaseUrl`, `backendBaseUrl`, `locationId`, `location`, `cafeId`)
  or an explicit `mode=` do — a station-only QR can't strand a demo tablet.
- **Auth-key detection strips separators.** `api_key`, `api-key`, `apikey`
  match alike; `bearer_token`, `Authorization`, `client-secret` reject too.
- **Preflight requires `locationId` and an https host.** `https://` with no
  host parses but reaches nothing.
- **Conflicting station params resolve by `stationId`.** The explicit id owns
  routing, so the label derives from it — `station=pastry&stationId=
  station_drinks` shows DRINKS over the drinks post, not PASTRY.

## Build settings are load-bearing

Two non-obvious manifest decisions, both forced by the generated code:

- No `.defaultIsolation(MainActor.self)` — under it the generated `Sendable`
  closures and synthesized `Decodable` conformances become actor-isolated and
  the target does not compile. The app keeps its MainActor dialect; the package
  stays in default isolation and its public types are `Sendable` value types.
- `.enableUpcomingFeature("InternalImportsByDefault")` — the generator emits
  `package import`, which collides with implicit `internal` imports in
  hand-written files (SE-0409 ambiguity). With the feature on, files exposing
  `Date`/`Duration` in public API write `public import Foundation`.

## Sources

- Android reference: `../../SimKDS-main` (Forgejo export).
- House REST pattern: `YandexDeliveryExpressAPI`, `GitLabKit`,
  `YooMoneyAPIClient` — same generator, same middleware shape, same test seams.
