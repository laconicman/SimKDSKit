import Testing

// House convention (YandexDeliveryExpressAPITests/Tags.swift): tags select
// suites from the command line — `swift test --filter` by name is brittle,
// `.tags` are declared once and read like a table of contents.

extension Tag {
    /// Pins a bug that shipped, or one a review round found before it did.
    /// Every test added to close a Devin Review finding carries this; deleting
    /// one needs a reason.
    @Tag static var regression: Self

    /// Exercises actor re-entrancy — a fetch, poll or action suspended at an
    /// `await` while another lands. These use `Gate` and `MutableClock`; a
    /// failure here is an ordering bug, not a mapping bug.
    @Tag static var concurrency: Self

    /// Pins a claim the vendored `openapi.yaml` (Generic KDS API v1) makes —
    /// header names, status codes, enum spellings, error envelopes. A failure
    /// means the document changed or the port drifted; see `SpecOwnership`.
    @Tag static var specContract: Self

    /// Runs against ``MockKdsAPI``. A failure here is about the demo backend's
    /// fidelity to the live contract, not about the engine.
    @Tag static var mock: Self

    /// Talks to a real backend — the Android repo's `tools/mock-server` for
    /// the integration pass, later a staging deployment. Reserved: nothing is
    /// tagged `live` yet; the integration pass adds the first suite and its
    /// environment-variable gate (`SIMKDS_LIVE_BASE_URL`).
    @Tag static var live: Self
}
