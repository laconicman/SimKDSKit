# Roadmap

Planned work, priority order. Upstream context: the Android repo's
`docs/open-integration-roadmap.md`.

## Now

- Generic KDS API v1 coverage complete: stations, active tickets, actions —
  plus the domain layer and stores the iPad app consumes.

## Next

- **SimCafeAlpha adapter** — headers `X-SimCafe-*`, `cafeId` stations query, the
  paid+fiscal visibility gate, Basic Auth. Deliberately out of v1; lands when an
  iOS tablet must talk to the legacy alpha backend.
- **Multi-station board** — several stations on one tablet (upstream roadmap 3).

- **Presentational KDS features that need no contract change** — all-day /
  production counts aggregated from visible tickets, sound on a new ticket,
  bump-bar via external-keyboard shortcuts. Everything market KDS products
  offer that v1 *does* need (recall, item-level fulfilment, expo gate, hold,
  priority) is proposed upstream in `Upstream/generic-kds-api-v1-proposals.md`
  and tracked as SK-5.

## Later

- **Push channel** — SSE/WebSocket over polling (SK-3), with polling as
  fallback.
- **Provisioning generator** — QR/profile tooling (upstream roadmap 2).
- **Widget / Live Activity** — ready-count surface; the Kit's membership test
  was written for this day.
- **iPhone layout** — single-column board, if a use case appears.
