# ``SimKDSKit``

The KDS foundation shared by the SimKDS iPad app and future extension targets:
the generated Generic KDS API client, the domain layer, the feed engine, and the
stores.

## Overview

SimKDSKit is a port of the Android SimKDS app's non-UI layers onto the house
pattern for REST clients: an owned OpenAPI document compiled by
`swift-openapi-generator`, behind a hand-written facade.

Three layers:

- **Domain** — tickets, board bucketing, optimistic transitions, remote-snapshot
  merge, filters, provisioning-link parsing, runtime-context validation, the
  wait classifier, and `KdsFeedEngine` — the actor that owns the feed:
  optimistic dispatch, poll merge, persistence, and the `observe()` stream.
- **API** — the generated client (package-internal) behind the ``KdsAPI``
  facade, `KdsCredentials`/`KdsContext` plumbing, the guest-text sanitizer, and
  ``MockKdsAPI`` for Mock mode.
- **Persistence** — ``KdsSettingsStore`` (plain settings, UserDefaults or
  in-memory) and ``CredentialStore`` (the API token, Keychain-held).

## Topics

### Direction

- <doc:Design>
- <doc:SpecOwnership>
- <doc:TechDebt>
- <doc:Roadmap>
