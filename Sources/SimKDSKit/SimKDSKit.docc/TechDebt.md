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
