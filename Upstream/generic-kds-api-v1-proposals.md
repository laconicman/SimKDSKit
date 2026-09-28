# Generic KDS API v1: gaps against shipping KDS products, and three precision fixes

**Upstream:** `docs/api.md` + `docs/openapi.yaml` in the SimKDS Android repo (vendored here
verbatim as `Sources/SimKDSKit/openapi.yaml`, see [SpecOwnership](../Sources/SimKDSKit/SimKDSKit.docc/SpecOwnership.md)).
**Channel:** same owner — Forgejo issue or direct edit. Contract changes follow the
document's own rule (`docs/api.md` → "Breaking и non-breaking changes"): optional fields and
new optional actions are non-breaking; everything else is a new namespace.
**Kind:** proposals. Nothing here is a defect in the client; the iOS client implements v1 as
written.
**Research:** 2026-09-28 — Fresh / Square / Toast / Lightspeed KDS feature matrices
(Forcked buying guide, restaurantpeers.com, menusifu.com), Square Orders API fulfilment
documentation, Toast Orders API developer guide, Oracle Simphony KDS configuration API, and a
DeepWiki deep read of an open-source KDS with the same shape as ours —
<https://deepwiki.com/search/describe-the-kitchen-display-s_e16a5110-2ef3-4141-a0ba-c0c9bc84d5ba?mode=deep>
(`openshiporg/openfront-restaurant`, index pinned at `ecc528a1`).

## Is there a standard to adopt instead?

No. OMG/ARTS (formerly NRF ARTS) publishes POSLog, the *Self Service Order Interface*
(ordering channel → POS — the opposite direction), the NAFEM data protocol (kitchen equipment
telemetry) and the Digital Receipt API. None describes the POS → kitchen-display ticket
lifecycle. Every KDS on the market speaks its vendor's private API. The closest thing to a
shared vocabulary is Square's fulfilment state machine, so that is the column to align new
vocabulary with:

| v1 `kitchenState` | Square `Fulfillment.state` | Toast `fulfillmentStatus` | Square timestamp |
| --- | --- | --- | --- |
| `new` | `PROPOSED` | `NEW` / `SENT` | — |
| `in_progress` | `RESERVED` | `SENT` | `accepted_at` |
| `ready` | `PREPARED` | `READY` | `ready_at` |
| `completed` | `COMPLETED` | — | `pick_up_at` |
| `cancelled` | `CANCELED` | — | `canceled_at` |
| `blocked` | `FAILED` (nearest) / `HOLD` (Toast) | `HOLD` | `failed_at` |

v1 is *stricter* than any of these in one respect: `expectedVersion` + `409 stale_version`.
Square and Toast are last-write-wins; the open-source KDS read above has no concurrency
control at all and polls every 10 s. Keep that.

## Gaps — what every shipping KDS has and v1 does not

| Behaviour | Prevalence | v1 today | Proposal | Breaking? |
| --- | --- | --- | --- | --- |
| **Recall / undo bump** — `ready → in_progress` (or `completed → ready`) after a mis-tap | Universal (Square, Toast, Fresh, Lightspeed; the open-source KDS has a `Recall` button) | Actions are forward-only: `start`, `mark_ready`, `complete` (`openapi.yaml:578-581`) | New optional action `recall` with `expectedVersion`; backend clears `readyAt`-equivalent. Client-side the reducer needs one backward transition | **Enum rollout** — `recall` extends closed `TicketAction`, echoed back as `acceptedAction`; see the note below |
| **Item-level fulfilment** — tick off lines; ticket auto-`ready` when all lines are | Common (Fresh, Toast Prep, Square) | Ticket-level only; `items[].availabilityState` is the only per-line state | Optional `items[].fulfillmentState: pending \| fulfilled` in the feed, plus optional action `fulfill_line { lineId }`. Backend may auto-promote to `ready` | Field: no. Action: **enum rollout**, as for `recall` |
| **Expediter / expo gate** — an expo ticket cannot be bumped while prep stations are still working | Common in multi-station kitchens | Nothing; upstream roadmap 3 (multi-station) is adjacent | Server-side rejection: `409` with a new `error.code = blocked_by_prep` listing the stations. Fits the existing error envelope | **Not until `ErrorCode` is open.** See the rollout note below the table |
| **Hold / release** for scheduled pickup or future orders | Common (Fresh "Order Hold and Release", Toast `HOLD`) | `blocked` is the nearest state but means "backend intervention", not "not yet" | Optional `metadata.onHold: bool` + `metadata.releaseAt: datetime`; the client renders a held lane and does not start SLA timers | No |
| **Backend priority / urgent flag** | Common (`priority`, `isUrgent`) | Sorting is by `visibleAt` only | Optional `priority: integer` on the ticket; higher first, ties by `visibleAt` | No |
| **Push channel** | Common | Polling (SK-3) | Upstream roadmap 1 already | — |

**Rollout note for every closed enum — `ErrorCode`, `TicketAction`, and any new one.**
The document's own breaking list forbids "изменение значения enum без сохранения
backward-compatible alias", and three enums in `openapi.yaml` are closed: `ErrorCode`
(`:584-593`), `TicketAction` (`:576-581`), `KitchenState` (`:558-566`). A strict generated client that
receives an unlisted value fails to decode the *whole body*:

- **`ErrorCode`** — the Swift client recovers the `409` from the status alone but loses the
  message (`KdsAPI.swift:153-158` → `.conflict(code: .unknown, message: nil)`); the Kotlin
  client parses the body as loose JSON and keeps it (`RealKdsHttpApiClient.kt:453-456`). A
  backend emitting `blocked_by_prep` early degrades the iOS operator message to nothing.
- **`TicketAction`** — it is a *request* value, but the success body echoes it as
  `acceptedAction` (`:520`). An old client never *sends* `recall`, yet a newer tablet on the
  same station does; the old client polls, and the ticket row decodes fine — but if a
  backend ever echoes an action in a shared payload the old client cannot decode it. And a
  new client sending `recall` to an old backend gets `422 validation_error`, which the
  operator reads as a mistake.
- **New enums** (`fulfillmentState`) arrive with their field, so they are safe *until* a
  value is added later — the same rule applies from then on.

The order, for any of them: (1) **contract** — declare the enum open (`type: string` with
the known values listed in prose, or `x-known-values`), and state that clients MUST treat
unknown values as opaque (unknown `error.code` = non-refresh conflict; unknown
`acceptedAction` = ignore; unknown `kitchenState` = hide the ticket, fail-closed); for new
*request* actions add **capability discovery** — an optional `supportedActions: [string]`
on the `Station` entry, so a client offers *Recall* only where the backend accepts it;
(2) **clients** ship tolerance and discovery; (3) **backends** emit. Step 1 is the
non-breaking one; step 3 before step 2 is not — which is why the table above stopped
calling the new actions "non-breaking".

Presentational — needs **no** contract change, goes to [Roadmap](../Sources/SimKDSKit/SimKDSKit.docc/Roadmap.md) for the iPad app:
all-day / production counts (aggregate `items` across visible tickets), sound on new ticket,
bump-bar via external keyboard shortcuts, colour-coded wait thresholds (already
`KdsWaitClassifier`).

## Three precision fixes to v1 as written

1. **`ticketId` uniqueness within a feed is not stated.** The `tickets` array
   (`openapi.yaml:402-403`) has no `uniqueItems` and the prose does not require distinct ids.
   Two clients (Kotlin `replaceWithActiveSnapshot`, Swift `KdsFeedEngine`) already dedupe
   defensively; a first-load path in each did not and misbehaved (findings #17 in
   `simkds-android-findings.md`). Say it: *"`ticketId` is unique within a response; a client
   MAY treat repeats as one ticket (last wins)"*. Documentation fix.
2. **Server-side content merges must bump `version`.** The DeepWiki read of a re-syncing
   backend surfaced this: when the backend merges new lines into an existing ticket
   *without* bumping `version`, the client's `expectedVersion` still equals the backend's,
   so the next action is **accepted** — against content the operator has not seen. The
   optimistic-concurrency guard exists precisely to turn "you acted on stale content" into
   a `409`; a merge that leaves `version` alone silently disables it for that ticket. (The
   client does pick up the new lines on the next poll — `mergeRemoteTicket` starts from the
   remote row — but between merge and poll a *Ready* tap can close a ticket that just grew
   a line.) Add to the integrator checklist: *"any change to a ticket's content or status
   increments `version`"*. Documentation fix; the mock server should follow it.
3. **`Idempotency-Key` example shows second resolution.** `docs/api.md:58` gives
   `…_start_3_20260709T100000Z`. An integrator who copies that pattern for their own tooling
   produces colliding keys for two attempts in one second (the Swift port did exactly this,
   fixed in `4b2e0db`; the Kotlin is safe only because `Instant.toString()` happens to carry
   milliseconds). State the rule instead of the example: *"unique per distinct action attempt;
   a retry of the same attempt reuses the key; include sub-second precision or a nonce"*.
   Documentation fix.

## Pasteable issue (Russian, for the Forgejo tracker)

> **Generic KDS API v1: предложения по расширению и три уточнения текста**
>
> Проверено 2026-09-28: отраслевого стандарта для POS → KDS нет (OMG/ARTS покрывает POSLog,
> Self-Service Order Interface, NAFEM и Digital Receipt — не кухонные тикеты). Контракт v1
> остаётся нашим; словарь для расширений имеет смысл сверять со Square Orders API
> (`PROPOSED / RESERVED / PREPARED / COMPLETED / CANCELED / FAILED`) — таблица соответствия
> в `Upstream/generic-kds-api-v1-proposals.md` в `laconicman/SimKDSKit`.
>
> **Уточнения текста v1 (не ломают совместимость)**
> - [ ] Явно указать уникальность `ticketId` внутри ответа `tickets` (`openapi.yaml` — массив без `uniqueItems`; клиенты уже дедуплицируют, но на первой загрузке оба забыли).
> - [ ] В чеклист интегратора: любое изменение содержимого или статуса тикета на стороне backend увеличивает `version` — иначе `expectedVersion` клиента совпадёт с серверной, и action будет *принят* против содержимого, которого оператор ещё не видел (защита optimistic concurrency для этого тикета молча отключается).
> - [ ] Пример `Idempotency-Key` в `docs/api.md:58` показывает секундное разрешение; заменить примером с правилом: уникален для каждой попытки, retry той же попытки использует тот же ключ, включать миллисекунды или nonce.
>
> **Расширения (все — optional, non-breaking по правилам самого документа)**
> - [ ] Action `recall` (`ready → in_progress`) с `expectedVersion` — есть у всех KDS на рынке, у нас actions только вперёд. `TicketAction` — закрытый enum и возвращается как `acceptedAction`; тот же порядок внедрения, что для `ErrorCode`, плюс `supportedActions` в `Station`, чтобы клиент предлагал *Recall* только там, где backend его принимает.
> - [ ] `items[].fulfillmentState` + action `fulfill_line { lineId }` — построчная готовность с авто-переводом тикета в `ready`. Поле — non-breaking; action — тот же порядок внедрения, что для `recall`.
> - [ ] `409 error.code = blocked_by_prep` — expo-станция не может закрыть тикет, пока prep-станции работают (связано с roadmap 3, multi-station). **Порядок внедрения обязателен:** `ErrorCode` сейчас закрытый enum; сначала объявить `error.code` открытой строкой (или зафиксировать «неизвестный код = непрозрачный конфликт без refresh»), затем клиенты, затем backend. Kotlin-клиент уже терпим к неизвестным кодам (`RealKdsHttpApiClient.kt:453-456`); Swift теряет текст сообщения.
> - [ ] `metadata.onHold` / `metadata.releaseAt` — hold/release для отложенных заказов; `blocked` для этого не подходит семантически.
> - [ ] `priority: integer` — приоритет от backend; сейчас сортировка только по `visibleAt`.
>
> Клиентская часть (all-day counts, звук нового тикета, bump-bar через клавиатуру) контракта не
> касается и идёт в roadmap iOS-клиента.
