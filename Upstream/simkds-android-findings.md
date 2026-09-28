# SimKDS (Android): defects surfaced by the iOS port

**Upstream:** `ru.etosimsim.simkds` — `../SimKDS-main`, Forgejo export, `versionName = "0.1.0"`
(`app/build.gradle.kts:15`; the export carries no git SHA, so revision = `CHANGELOG.md` head
"0.1.0 - Initial standalone SimKDS").
**Channel:** same owner as this package — Forgejo issue, or a direct edit.
**Kind:** behaviour defects unless a row says otherwise.
**Verified:** 2026-09-28, each row read in the Kotlin file cited. Paths below are relative to
`app/src/main/java/ru/etosimsim/simkds/`.

## How these were found

Devin Review examined the Swift port PR by PR (`laconicman/SimKDSKit` #2 domain, #3 API,
#4 feed engine — ~40 findings over 2026-09-24…28). Each finding was fixed in Swift with a
regression test. This note is the pass that went back to the Kotlin to ask, for each one,
*was it ported faithfully?* — nineteen classes were. Two review findings that sounded upstream
were porting errors instead and are listed in `README.md` under *Closed without filing*.

Severity is the reviewer's, kept where the Kotlin matched. "Fixed in" is the SimKDSKit commit
whose test names the case; the same test is the acceptance test for an upstream fix. Those
commits sit on the stacked branches until PRs #2–#4 merge (merge commits — SHAs preserved);
file this note after that, per `README.md` → *Filing order*.

## Findings

| # | Sev | Defect | Kotlin evidence | Fixed in |
| --- | --- | --- | --- | --- |
| 1 | 🔴 | **Optimistic version rolls back on merge.** After a `start` at v3 the local ticket is `InProgress` v4; a stale poll still reporting v3 keeps the advanced status but copies the remote *version* — the next action sends `expectedVersion: 3` and 409s | `domain/KdsReducer.kt:78-81` — `remoteTicket.copy(status = mergedStatus, statusUpdatedAt = …)`; `version` comes from the remote unconditionally | `6e1adf6` — keep `max(local, remote)` when the local status survives |
| 2 | 🔴 | **Stale `blocked` resurrects a completed ticket.** `mergeStatus` returns the remote status whenever either side is `Blocked`, before terminal states are considered; `completed → blocked → ready` puts a served ticket back on the board | `domain/KdsReducer.kt:130-132` runs before `mostAdvancedStatus` | `53772ce` — local `Completed` is terminal ahead of the blocked rule |
| 3 | 🔴 | **Valid station ids fail filtering.** The contract requires only a non-empty `stationId` (`docs/api.md` Stations table); the matcher requires `^station_[a-z0-9]+(?:_[a-z0-9]+)*$`, so a backend using `bar-hot` gets an empty board and label `UNKNOWN` | `domain/KdsTicket.kt:6` (regex), `:87` (`fromBackendStationId` → `Unknown`), `:96-100` (`matchesStationId` via `toCanonicalStationIdOrNull`) | `53772ce` — trimmed, case-folded equality; aliases only on the display-token path |
| 4 | 🔴 | **Fractional quantities lost.** `quantity` is declared `number` in the contract (`docs/api.md` Item fields); the DTO and domain use `Int`, so 0.5 kg becomes 0 or fails to parse | `data/KdsBackendTicketDto.kt:49`, `domain/KdsTicket.kt:105` | `6e1adf6` — `Double` end to end |
| 5 | 🔴 | **A ticket with one unavailable line disappears entirely.** `isAllowedForKds` requires *every* item available, but the backend already decided the ticket is kitchen-visible (`docs/api.md`: "Backend сам решает, какие заказы уже можно показывать"); a stop-listed garnish hides the whole order | `domain/KdsTicket.kt:137-140` — `items.all { … Available }` | `6e1adf6` — gate on status + ticket-level availability; line availability is display metadata |
| 6 | 🔴 | **A station-only provisioning link flips a demo tablet to Real mode.** `hasConnectionParams` counts `station`, `stationId`, `deviceId`, `actorId`, `deviceName` as *connection* parameters, so `simkds://provision?stationId=station_bar_cold` on a mock device sets `backendMode = Real` with no URL and no credentials | `domain/KdsProvisioning.kt:36-54` (the list), `:73-74` (`toBackendMode(if (hasConnectionParams) Real …)`) | `6e1adf6` — only backend-target keys (`api*`, `location*`, `cafeId`) or an explicit `mode=` switch modes |
| 7 | 🟥 | **`api_key` / `bearer_token` bypass the auth-in-URL rejection.** Provisioning rightly refuses links carrying credentials, but `AUTH_PARAM_KEYS` is a camelCase list compared case-insensitively only — `api_key`, `api-key`, `bearer_token`, `Authorization` are not recognised and the secret lands in settings | `domain/KdsProvisioning.kt:222-231` (list), `:113-116` (`hasAnyIgnoringCase` — case only, separators kept) | `6e1adf6` — compare with separators stripped; `Authorization`, `client-secret` added |
| 8 | 🟨 | **`https://` with no host passes preflight.** `URI("https://")` parses; the scheme check returns `null` (valid) before anyone looks at the host, so the operator sees the backend as *offline* rather than *misconfigured* | `domain/KdsRuntimeContextValidation.kt:60-66` | `6e1adf6` — https requires a non-empty host |
| 9 | 🔍 | **`locationId` not required by request preflight.** `X-SimKDS-Location-Id` is a required header and `GET /stations` requires the query parameter, yet `contextError` checks station, device and actor only — a blank location is discovered by a 422 from the backend | `domain/KdsRuntimeContextValidation.kt:48-58` | `6e1adf6` |
| 10 | 🟡 | **Ready-wait includes preparation time.** "Pickup wait" should start when the ticket became ready; `readyWaitDuration` measures from `createdAt`, and `statusUpdatedAt` is whatever the wire sent (often `null`) | `domain/KdsTicket.kt:134-135` | `6e1adf6` — `readyAt` stamped at the ready transition (optimistic `occurredAt`, or first poll that reads ready) |
| 11 | 🔴 | **A failed action rolls the whole board back, clobbering concurrent polls.** `dispatch` is under `dispatchLock` but `refreshActiveSnapshot` is not; a poll that lands between `previousState = feed.value` and the rollback `_feed.update { tickets = previousState.tickets }` is erased — other tickets' progress included | `data/FakeKdsRepository.kt:93-94` (capture), `:251-258` (wholesale restore), `:268` (poll path, unsynchronised) | `dcda801`, `734086a`, `d7f86cc` — roll back only the action's own transition, against the newest remote truth |
| 12 | 🔴 | **Conflict refresh runs under the settings the action was dispatched with.** After a 409, `refreshActiveSnapshot(settings = previousState.deviceSettings)` — if the operator switched station or backend while the call was out, the old station's tickets are merged onto the new board | `data/FakeKdsRepository.kt:260-265` | `8466615` — an action captures a configuration generation and drops its outcome if it changed |
| 13 | 🔴 | **A backend/location change keeps the previous backend's tickets.** `updateSettings` filters by station only; changing `apiBaseUrl`, `locationId` or `backendMode` with the same station carries the old backend's `ready`/`completed` rows into the new feed as "history" | `data/FakeKdsRepository.kt:196-214` | `dcda801` — backend-identity change clears the board and pending-action bookkeeping |
| 14 | 🔴 | **A refresh that completes after a settings change publishes anyway.** No generation guard: `refreshActiveSnapshot` reads settings, blocks on the network, then `_feed.update`s whatever came back. The sequential poll loop makes this rare; `retryReconnect` + a settings edit makes it reachable | `data/FakeKdsRepository.kt:268-316` | `dcda801` — config + fetch generations checked before publishing |
| 15 | 🟡 | **Demo tickets never accumulate wait time.** The fake's `refresh` re-creates A-44 / M-13 / M-12 with `createdAt = now` on *every* poll and upserts over the existing row, so their timers reset every 2 s in the demo | `data/KdsApiClient.kt:72-80`, `:94-101`, `:173-222` | `582d2cb` — upsert preserves the existing `visibleAt` |
| 16 | 🟢 | **The fake feed is not station-scoped.** `fetchActiveTickets` returns every station's tickets; the repository filters afterwards, so the board is right, but the fake does not behave like the live endpoint it stands in for (`/stations/{stationId}/tickets/active`) | `data/KdsApiClient.kt:53-57` | `582d2cb` |
| 17 | 🟢 | **Duplicate `ticketId`s in the initial fetch become duplicate rows.** `replaceWithActiveSnapshot` dedupes (`distinctBy { it.id }`); `createInitialFeedState` does not | `data/FakeKdsRepository.kt:59-60` vs `:352-353` | `8466615` — same id policy on both paths |
| 18 | 🟡 | **`lastSyncedAt` is sampled before the fetch.** `val now = clock()` precedes the network call, so "synced 30 s ago" can be true the moment a slow poll returns | `data/FakeKdsRepository.kt:272` | `8466615` — clock sampled after the round trip |
| 19 | 🟡 | **Only `stale_version` triggers the conflict refresh.** `docs/api.md` → Error model names two refresh-conflicts, `stale_version` *and* `station_mismatch` ("после них приложение должно заново запросить active tickets"); the client refreshes on the first only, so a ticket re-routed to another station stays on the wrong board until the next poll happens to drop it | `data/RealKdsHttpApiClient.kt:82` — `shouldRefresh = statusCode == 409 && backendErrorCode() == "stale_version"` | Swift follows the document: `KdsConflictCode.requiresRefresh` covers both (`KdsAPIError.swift:13-16`) |

Kept, as a recorded divergence rather than a defect:

| # | Behaviour | Kotlin | iOS |
| --- | --- | --- | --- |
| 19 | Station directory refetched on every 2 s poll — a directory GET per poll, doubling traffic for data that changes rarely | `data/FakeKdsRepository.kt:300-303` inside `refreshActiveSnapshot` | Ported faithfully; registered as SK-4 with a slower-cadence discharge (issue #6) |
| 20 | A persisted `lastActionError` survives a *successful* initial fetch — the stale banner shows over a healthy board until the next action | `data/FakeKdsRepository.kt:66` | Cleared on successful `start()` (`dcda801`). A suggestion for upstream, not a bug report |

## Pasteable tracking issue (Russian, for the Forgejo tracker)

> **iOS-порт нашёл 19 дефектов, воспроизводимых в Android-оригинале**
>
> При портировании SimKDS на iPad (Swift, `laconicman/SimKDSKit`) ревью каждого слоя выявило
> дефекты, которые при проверке оказались унаследованными из Kotlin-кода. Ниже — по одному
> пункту на класс, со ссылкой на строку в `0.1.0` и на Swift-коммит с регрессионным тестом
> (тест описывает ожидаемое поведение и годится как acceptance test для исправления здесь).
>
> **Домен / reducer**
> - [ ] `KdsReducer.mergeRemoteTicket` откатывает `version` до значения из stale-снапшота, хотя статус сохраняет продвинутый → следующий action уходит с устаревшим `expectedVersion` и получает 409 (`KdsReducer.kt:78-81`; Swift `6e1adf6`)
> - [ ] `mergeStatus` возвращает remote-статус при `Blocked` до проверки терминальных статусов → `completed → blocked → ready` возвращает выданный заказ на доску (`KdsReducer.kt:130-132`; `53772ce`)
> - [ ] `matchesStationId` / `fromBackendStationId` требуют `^station_[a-z0-9_]+$`, хотя контракт требует лишь непустой `stationId` → backend с id `bar-hot` получает пустую доску и label `UNKNOWN` (`KdsTicket.kt:6, 87, 96-100`; `53772ce`)
> - [ ] `quantity: Int`, контракт — `number` → дробные количества теряются (`KdsBackendTicketDto.kt:49`, `KdsTicket.kt:105`; `6e1adf6`)
> - [ ] `isAllowedForKds` требует доступности *всех* позиций → одна стоп-листовая позиция скрывает весь тикет, хотя backend уже решил его показать (`KdsTicket.kt:137-140`; `6e1adf6`)
> - [ ] `readyWaitDuration` считает от `createdAt`, а не от момента готовности (`KdsTicket.kt:134-135`; `6e1adf6`)
>
> **Provisioning / валидация**
> - [ ] Ссылка только со `stationId` переводит demo-планшет в `Real` без URL и без токена — `station*`, `device*`, `actorId` числятся connection-параметрами (`KdsProvisioning.kt:36-54, 73-74`; `6e1adf6`)
> - [ ] `api_key`, `api-key`, `bearer_token`, `Authorization` не распознаются как auth-параметры (сравнение только без учёта регистра) → секрет из ссылки попадает в настройки (`KdsProvisioning.kt:113-116, 222-231`; `6e1adf6`)
> - [ ] `https://` без хоста проходит preflight (`KdsRuntimeContextValidation.kt:60-66`; `6e1adf6`)
> - [ ] `locationId` не проверяется в preflight, хотя header и query обязательны (`KdsRuntimeContextValidation.kt:48-58`; `6e1adf6`)
>
> **Repository / конкурентность**
> - [ ] Откат неудачного action восстанавливает *весь* `previousState.tickets` — параллельный poll (не под `dispatchLock`) стирается вместе с прогрессом других тикетов (`FakeKdsRepository.kt:93-94, 251-258, 268`; `dcda801`, `734086a`, `d7f86cc`)
> - [ ] После 409 refresh выполняется со *старыми* settings → при смене станции/бэкенда во время action на новую доску попадают тикеты старой (`FakeKdsRepository.kt:260-265`; `8466615`)
> - [ ] `updateSettings` фильтрует только по станции → смена `apiBaseUrl`/`locationId`/`backendMode` оставляет историю прежнего бэкенда (`FakeKdsRepository.kt:196-214`; `dcda801`)
> - [ ] Нет generation guard: refresh, завершившийся после смены settings, всё равно публикуется (`FakeKdsRepository.kt:268-316`; `dcda801`)
> - [ ] `lastSyncedAt = now` берётся *до* сетевого вызова (`FakeKdsRepository.kt:272`; `8466615`)
> - [ ] Начальная загрузка не делает `distinctBy { it.id }`, в отличие от refresh (`FakeKdsRepository.kt:59-60` vs `352-353`; `8466615`)
> - [ ] Refresh после 409 только для `stale_version`; `docs/api.md` называет refresh-конфликтом и `station_mismatch` (`RealKdsHttpApiClient.kt:82`)
>
> **Fake client (demo)**
> - [ ] `refresh` пересоздаёт A-44/M-13/M-12 с `createdAt = now` на каждом poll → таймеры ожидания в демо сбрасываются каждые 2 с (`KdsApiClient.kt:72-80, 94-101`; `582d2cb`)
> - [ ] `fetchActiveTickets` отдаёт тикеты всех станций, в отличие от live-endpoint (`KdsApiClient.kt:53-57`; `582d2cb`)
>
> **Предложения (не дефекты)**
> - Справочник станций запрашивается на каждом poll (`FakeKdsRepository.kt:300-303`) — достаточно при старте, при смене настроек и раз в минуту.
> - Сохранённый `lastActionError` переживает успешный первый fetch (`FakeKdsRepository.kt:66`) — баннер об ошибке висит над здоровой доской.
