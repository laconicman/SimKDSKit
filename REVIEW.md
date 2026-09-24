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
- Require `nonisolated` on pure value types and their extensions (extensions do
  not inherit it under MainActor default isolation — YDeliveryKit rule 4, same
  hazard).

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
