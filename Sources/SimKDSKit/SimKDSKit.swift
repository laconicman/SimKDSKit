/// SimKDSKit — the KDS foundation shared by the SimKDS iPad app and future
/// extension targets.
///
/// Three layers, one module:
/// - `Domain/` — tickets, board, reducer, filters, provisioning, validation,
///   the pure `KdsFeedEngine` state machine.
/// - `API/` — the generated Generic KDS API client (package-internal) behind the
///   hand-written ``KdsAPI`` facade, credentials/context plumbing, the
///   guest-text sanitizer, and ``MockKdsAPI``.
/// - `Persistence/` — ``KdsSettingsStore`` (plain settings) and
///   ``CredentialStore`` (Keychain-held token).
///
/// Direction lives in the DocC catalog: `Design`, `SpecOwnership`, `TechDebt`,
/// `Roadmap`.
public enum SimKDSKit {}
