# SimKDSKit

The Swift foundation of [SimKDS](https://github.com/laconicman/SimKDS) — the iPad
kitchen/bar display app, a port of the Android SimKDS (Generic KDS API v1).

What lives here, and the membership test for anything added: *code a KDS surface
(app or future extension target) needs, which cannot import the app.*

- **Wire client:** generated from the vendored `openapi.yaml` (Generic KDS API v1)
  by `swift-openapi-generator`. Generated types are `package`-internal — the module
  boundary exposes only hand-written domain types and the `KdsAPI` facade.
- **Domain:** tickets, board, reducer (optimistic transitions + remote merge),
  filters, provisioning-link parsing, runtime-context validation, wait classifier,
  the pure `KdsFeedEngine` state machine.
- **Stores:** `KdsSettingsStore` (UserDefaults / in-memory) for plain settings and
  `CredentialStore` (Keychain) for the API token.
- **Mock:** `MockKdsAPI` — the demo/seeded ticket source for the app's Mock mode.

Not here: views, controllers with UI affinity, colors, and the app itself.

Direction docs (authoritative): the DocC catalog —
`Sources/SimKDSKit/SimKDSKit.docc/` (`Design`, `SpecOwnership`, `TechDebt`,
`Roadmap`).

Swift 6, iOS 17 floor, `MainActor` default isolation with `nonisolated` value
types. Swift Testing throughout.

## Build & test

```bash
swift build
swift test
```

## The spec

`Sources/SimKDSKit/openapi.yaml` is a vendored copy of `docs/openapi.yaml` from
the SimKDS repository (Generic KDS API v1). Fixes belong upstream first — see the
`SpecOwnership` article before editing it.
