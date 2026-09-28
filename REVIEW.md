# Review Guidelines

Review-specific guidance. `CLAUDE.md` carries this repository's standing rules
and is ingested alongside this file — nothing here restates it. These are the
diff-level cues and the noise filters.

## Critical Areas

- Flag any change to `Sources/SimKDSKit/openapi.yaml` that is not accompanied by
  a `SpecOwnership` note naming the upstream commit/file it was vendored from —
  or by an explicit divergence entry. The document is owned upstream.
- Flag any change under `Persistence/CredentialStore.swift` that logs, prints, or
  interpolates a token into an error, or that moves credential storage off the
  Keychain.
- Flag a status flip of an `SK-n` entry in `SimKDSKit.docc/TechDebt.md` that does
  not name what discharged it.

## Conventions

- Generated code must not appear in a diff (`Sources/GeneratedSources/` or
  edited `Client.swift`/`Types.swift` under the target) — the plugin owns it.
- Flag a `// TODO` in Swift code that carries no `SK-n` register number.
- Require public API to be hand-written domain/facade types; a `public` on a
  declaration that re-exports a generated symbol is a boundary violation.
- Do **not** require `nonisolated` on value types or extensions: this package is
  nonisolated by default (`.defaultIsolation(nil)` in the manifest), so the
  marker is a no-op annotation here — `Design → Concurrency` records why.
  Conversely, flag a `defaultIsolation(MainActor)` swiftSetting (or a
  `SWIFT_DEFAULT_ACTOR_ISOLATION` build setting) added to any target that
  contains generated code as a regression: it breaks generated conformances —
  upstream apple/swift-openapi-generator#796 and #823.

## Anti-patterns to Flag

- Flag `ObservableObject`, `@Published`, `@StateObject` in new code — the floor
  is iOS 17 and the project is Observation-only.
- Flag `UserDefaults` holding anything secret-shaped — the token belongs to
  `CredentialStore` (Keychain).
- Flag `DispatchQueue.main.async` in a file already using Swift Concurrency.
- Flag a blanket `@MainActor` (or removal of `nonisolated`) applied to make a
  diagnostic disappear without a stated reason.
- Flag tolerant-parsing fallbacks added to satisfy a non-conforming payload —
  strict decoding is a recorded decision (TechDebt SK-1); a tolerance shim is a
  documented escalation, not a drive-by.

## Security

- `CredentialStore` items keep `kSecAttrSynchronizable` absent (no iCloud sync)
  and `kSecAttrAccessibleAfterFirstUnlock` unless a stated background need
  changes it.
- Reject any committed fixture or source literal carrying a real token.

## Ignore

- Skip `Package.resolved` churn when a dependency bump is the PR's stated
  purpose.
