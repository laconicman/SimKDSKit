# A second KDS backend behind one seam

The plan for connecting this client to another kitchen-display API — Square's
Orders API, Toast, a second in-house contract — without a second board. Written
before any second backend exists, so it says what is *already* in place, what
Generic KDS API v1 leaked above its layer, and the order in which to fix that
when (not before) a real second case appears.

## What the seam is today

``KdsAPI`` is four `async throws(KdsAPIError)` methods — stations, active
tickets, refresh, apply action — each taking a `KdsContext` snapshot and
returning **hand-written domain types**, never generated ones. Three
implementations already exist: `LiveKdsAPI` (the generated Generic v1 client),
``MockKdsAPI`` (the demo actor), and the tests' `ScriptedKdsAPI`; the engine
holds `any KdsAPI` and is handed a new one by `updateSettings(_:api:)` when
connection settings move. So the protocol is *earned* by the rule of three, not
speculative — and adding a backend means adding a fourth conformer, nothing
architectural. That is the protocol-oriented shape the author asked for, and it
is already here. What is **not** here yet is examined below.

Backend-neutral now: ``KdsFeedEngine`` (it reads two things from an error —
`requiresRefresh` and `isLocalValidationFailure` — and one from settings,
`backendMode`), ``KdsReducer``, ``KdsOpsFilters``, ``KdsWaitClassifier``,
``KdsBoardLayout``, the stores, `GuestTextSanitizer` (a board policy — no
guest PII on a kitchen screen — that applies to any backend), and the test
doubles. `TicketMapping` and `KdsAuthMiddleware` are correctly *inside* the
v1 adapter.

## Where Generic v1 leaked above its layer

Verified 2026-09-28 against `main` after the 0.1.0 merge train (DeepWiki
second opinion:
<https://app.devin.ai/search/api_f53d202f-3455-4ff9-9ba4-a51629d87b35>).

| Leak | Where | Severity for a second backend |
| --- | --- | --- |
| `route`, `activeTicketsPath` on ``KdsStationDirectoryEntry`` — v1's endpoint shape carried as domain fields. Nothing above the API layer reads them | `Domain/KdsStationDirectory.swift` | Cosmetic — a Square adapter would fill them with nothing. Drop from the domain type; the adapter keeps them if it needs them |
| `KdsConflictCode` (`stale_version`, `station_mismatch`, `idempotency_conflict`) — v1's *error codes* as the domain's conflict vocabulary, with `requiresRefresh` keyed to them | `API/KdsAPIError.swift` | Real — another backend has other codes. The domain wants **reasons** (`staleState`, `wrongStation`, `duplicateRequest`, `unknown`); each adapter maps its codes to reasons; `requiresRefresh` stays a domain policy on reasons |
| `KdsAction` is forward-only with `expectedVersion: Int?` | `Domain/KdsAction.swift` | Fine as is — `expectedVersion` is already optional (a versionless backend sends nil and the reducer still works); the action *set* grows through v1's own proposals (`recall`, `fulfill_line`), see `Upstream/` |
| ``KdsTicketStatus`` = v1 `kitchenState`; ``KdsAvailabilityState`` = v1's six values | `Domain/KdsTicket.swift` | Keep as the **canonical** vocabulary — it maps onto Square's fulfilment states one-to-one (table in `Upstream/generic-kds-api-v1-proposals.md`). An adapter translates *into* it |
| `KdsBackendMode` is `mock \| real` — "real" means "Generic v1" | `Domain/KdsDeviceSettings.swift` | Real — the discriminator for *which* backend is missing; today it is implied |
| ``KdsDeviceSettings`` is v1's identity model (`apiBaseUrl`, `locationId`, `stationId`, `deviceId`, `actorId`) | `Domain/KdsDeviceSettings.swift` | Partly real — station/device/actor are KDS concepts any backend has some form of; `locationId` and the URL are v1's |
| `KdsRuntimeContextValidation` — "Generic contract only" by its own comment | `Domain/KdsRuntimeContextValidation.swift` | Real — preflight belongs to the adapter that knows its required fields |
| `KdsProvisioning` parses v1's query keys | `Domain/KdsProvisioning.swift` | Real, but additive — a `backend=` key dispatches; v1 keys stay the default |
| ``KdsCredentials`` is bearer *or* `X-SimKDS-Api-Key` | `API/KdsCredentials.swift` | Real — an OAuth backend needs a refreshable token; the header choice already lives in the adapter's middleware, which is the right place |

## The design: existential adapters over a canonical model

Three shapes were weighed. The first is the plan; the other two are recorded
so they are not re-proposed.

**A — one `any KdsAPI` seam, one adapter per backend, one canonical domain
model (chosen).** The domain types *are* the KDS canonical model; Generic v1 is
its first wire binding, and its vocabulary was already the closest thing to an
industry lingua franca (no standard exists — `Upstream/README.md`). Each backend
is a `KdsAPI` conformer that owns its client, mapping, credential middleware,
preflight, and conflict-code translation. The engine, reducer, filters, stores
and the app never learn which backend is behind the seam. Existential, not
generic, because the engine *swaps* the facade at runtime — mode switch,
provisioning link, settings edit — and a `KdsFeedEngine<Backend>` would fix the
backend at compile time and force the app to know it. This is DIP applied where
it lowers real change-cost, and no further (the principles skill's step 6).

**B — a generic engine `KdsFeedEngine<Backend: KdsBackend>` with associated
`Settings`/`Credentials` types (rejected).** Buys static knowledge nobody needs:
no consumer specializes on the backend, and runtime switching — which exists
today between mock and live — would need type erasure to get back to A. YAGNI;
the associated-type version of a problem the existential already solves.

**C — per-backend domain models behind a `Ticket` protocol or enum
(rejected).** Views would `switch` over backends and the board would stop being
one board. The whole point of the seam is that a ticket is a ticket.

## Phases — each a PR, each triggered by a real need

**Phase 0 — name the model, unleak the cheap ones.** Trigger: now; no
behaviour change.
- <doc:Design> states that the domain types are the canonical KDS model and v1
  its first binding (this article is the plan; Design gets the sentence).
- Drop `route`/`activeTicketsPath` from ``KdsStationDirectoryEntry`` (unused
  above the API layer — verified). Source-breaking → minor bump per CLAUDE.md
  rule 9.
- Replace `KdsConflictCode` with a canonical `KdsConflictReason`
  (`staleState`, `wrongStation`, `duplicateRequest`, `unknown`);
  `LiveKdsAPI` maps v1 codes to reasons; `requiresRefresh` is defined on the
  reason. ``MockKdsAPI`` and the tests follow.

**Phase 1 — capabilities arrive through v1 itself.** Trigger: the
`Upstream/` proposals land (`supportedActions` on the station entry, `recall`,
`fulfill_line`).
- ``KdsStationDirectoryEntry`` gains `supportedActions: Set<KdsActionKind>`;
  the reducer gains its first backward transition. The gate sits where actions
  are *constructed*, not where they are laid out: `KdsTicket.boardActionPresentation`
  is the one public source of a ticket's next action, so it takes the station's
  capabilities and returns nil (or the next *supported* action) for one the
  backend does not accept; ``KdsBoardLayout`` merely renders what it is given.
  A check only in the layout would leave that public source offering
  unsupported actions to any other caller. One field, fed by the backend, one
  gate, no flags in the app.

**Phase 2 — the second backend.** Trigger: a real one is chosen.
- `KdsBackendMode` becomes a backend **descriptor** — `mock`, `genericV1`,
  `<vendor>` — and ``KdsDeviceSettings`` carries a `Codable` enum of
  per-backend configurations (`case genericV1(GenericV1Settings)`,
  `case <vendor>(<Vendor>Settings)`) rather than a flat struct of optionals.
  Station, device and actor stay common; URL/location/tenant move into the
  per-backend case.
- ``KdsCredentials`` grows a case per auth scheme (`bearer`, `apiKey`,
  `oauth(access:refresh:)`); the adapter's middleware picks. A refreshing
  scheme gets its own actor, as <doc:Design> → Concurrency already reserves.
- Preflight becomes a protocol requirement — `settingsProblems(_:) -> [String]`
  on ``KdsAPI`` (static or instance) — so the settings sheet asks the adapter,
  not a Generic-only validator; `KdsRuntimeContextValidation` becomes the v1
  adapter's implementation of it.
- `KdsProvisioning` dispatches on a `backend=` key; absent means v1.
- `KdsAPIs.make` chooses the adapter from the descriptor; `ModeSwitchingKdsAPI`
  stays the mock/real switch in front of whichever live adapter was chosen.
- The vendor adapter: its own OpenAPI document (or hand-written client if the
  vendor publishes none), its own `TicketMapping`, its states translated into
  the canonical vocabulary, its conflicts into reasons. `GuestTextSanitizer`
  runs on every adapter's output — the board policy does not depend on who
  sends the ticket.

## What this plan is not about

**Several stations on one tablet** (upstream roadmap 3, <doc:Roadmap>) is
orthogonal. A multi-station `KdsAPI` conformer alone would change nothing:
``KdsFeedEngine`` filters every snapshot to the one configured station
(`forDeviceStation`), the reducer merges one station's rows, and the layout
buckets one board. Multi-station is an *engine and layout* change — a set of
stations in settings, a per-station or merged board — behind the same seam,
and it neither needs nor is helped by a second backend.

## What the iPad app must do now so Phase 2 stays cheap

- Depend on `any KdsAPI` and the domain types only — the package boundary
  already enforces it (generated types are `package`).
- Build the settings sheet as **sections per backend** driven by the
  descriptor, even while there is one section.
- Branch on `backendMode` for exactly one thing: the demo toggle.
- Offer a ticket's action from `KdsTicket.boardActionPresentation(now:)` —
  the one public source, and the place Phase 1 gates on capabilities — never
  from a hard-coded list in a view. ``KdsBoardLayout`` only buckets tickets
  into columns; it is not an action source.

## Where generics *would* fit, and why they still do not

The author's usual tool for this is protocol-oriented programming with
generics. Protocol-oriented: yes, already. Generics: nowhere in this plan
earns them. The engine holds one facade and swaps it; adapters return domain
types, so no associated types are needed; the stores are already protocols
with two conformers. If a place ever needs a generic, it will be *inside* an
adapter (a client generic over its transport, say) — never on the seam.
