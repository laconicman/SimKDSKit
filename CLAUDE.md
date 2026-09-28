# SimKDSKit — shared KDS foundation package

The generated Generic KDS API client, the domain layer, the feed engine, and the
stores under [SimKDS](https://github.com/laconicman/SimKDS) (iPad) and its future
extension targets. `README.md` states the membership test; `REVIEW.md` carries
the diff-level review cues. Design rationale lives in `SimKDSKit.docc` — cite it,
do not re-derive it. The Android reference implementation being ported lives at
`../SimKDS-main` (not a git repo — an extracted archive of the Forgejo repo).

## Rules specific to this repository

1. **Everything lands via PR** (author's standing rule). `main` is protected;
   Devin Review runs on push and `REVIEW.md` steers it. No AI attribution in
   commit messages or PR descriptions.
2. **Generated types stop at the module boundary — enforced.** The generator
   emits `package` access (`openapi-generator-config.yaml`), so `Client` and
   `Components.*` cannot leak into the app by accident. Do not loosen the access
   level; if a generated shape must surface, re-map it onto a domain type.
3. **Fix spec problems in `openapi.yaml` upstream, not in Swift.** The document
   is vendored verbatim from the SimKDS repo (`docs/openapi.yaml`) — we own it,
   but not here. A divergence is a deliberate, documented act; see
   `SpecOwnership`.
4. **Never edit generated code, and never commit it.** The build plugin
   regenerates `Client.swift`/`Types.swift` into the build directory.
5. **The package is `nonisolated` by default — deliberately** (`.defaultIsolation(nil)`
   in the manifest; see `Design → Concurrency`). Generated code cannot compile
   under `-default-isolation MainActor`, and a data-layer library must not
   impose an executor on callers. `nonisolated` markers on value types are
   no-ops here — do not add them. Mutable state lives behind actors
   (`KdsFeedEngine`, stores, `MockKdsAPI`); `KdsAPI` stays a stateless
   `Sendable` seam. If a target with `MainActor` default is ever added,
   *that* target's pure value types state `nonisolated` every time — that is
   where the YDeliveryKit rule this replaces actually applies.
6. **Errors are two channels.** Documented non-2xx statuses are `KdsAPIError`
   cases you `switch` on; transport and decoding failures are thrown. Do not
   collapse them. Error types conform to `LocalizedError` with a filled
   `errorDescription`.
7. **Swift Testing, not XCTest.** `#expect` by default, `#require` when later
   lines depend on the value, tags for selection (`Tests/SimKDSKitTests/Tags.swift`:
   `.regression`, `.concurrency`, `.specContract`, `.mock`, `.live`). A test that
   closes a review finding carries `.regression`.
8. **Secrets never enter `KdsDeviceSettings`.** The token lives in
   `CredentialStore` (Keychain); settings carry only plain fields.
9. **Source-breaking changes bump the minor while `0.x`, stated in the PR
   description.** Consumers pin `minorVersion`.
10. **Platform floor is iOS 17.** No `@available` annotations belong in this
    package.

## Author's standing preferences

Clarity over brevity. Prefer a vetted SPM over hand-rolling when the dependency is
smaller than the problem — and say so explicitly when it is *not*. Cite sources in
prose and in code comments. DRY, separation of concerns, low coupling / high
cohesion first.

## Related skills

`apple-swift-openapi-generator` · `swift-package-manager` · `swift-testing-expert`
· `swift-file-organization` · `software-development-principles` ·
`swift-concurrency` · `atomic-commits` · `git-branching`
