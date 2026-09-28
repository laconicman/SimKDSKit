# Owning the Specification

`Sources/SimKDSKit/openapi.yaml` is a **vendored copy** of
`docs/openapi.yaml` in the SimKDS repository (Generic KDS API v1), and that
repository is the document's home — the conformance checker, the mock server,
and the Android client all read it as the contract.

Vendored from: `SimKDS-main/docs/openapi.yaml`
SHA-256 at vendoring: `f7f42b6ddc47ecd24f2da8e71a116d28ce28c2dff69b837bf58356883f529f43`

## What that obligates

- **Fix spec problems upstream, not here.** If codegen exposes a defect, the fix
  lands in the SimKDS repo first (its own change, its own review), then this
  file is re-vendored and the checksum above updated in the same commit.
- **A deliberate divergence is documented in this article**, with the reason —
  e.g. a generator-only tweak that must not flow back to the contract other
  clients implement against. None so far.
- **Verify vendoring mechanically.** `diff` against upstream or compare the
  hash; "looks similar" is not vendoring.

## Upstream fixes already applied

- **`TicketLine.quantity`**: the document declared `openapi: 3.0.3` but used
  `exclusiveMinimum: 0` — the JSON Schema / 3.1 numeric form. Under 3.0.x
  `exclusiveMinimum` is a boolean paired with `minimum`, which is why the
  generator (OpenAPIKit, strict 3.0) rejected it. Fixed upstream to
  `minimum: 0` + `exclusiveMinimum: true` — identical semantics — then
  re-vendored. The upstream conformance checker only guards structure, so it
  never saw the defect; the generator did.

## Upstream notes

Everything we owe upstream — defects found in the Android original while
porting, and proposals for the contract itself — collects in `Upstream/` at the
repository root, one note per upstream with evidence and a pasteable report
(`Upstream/README.md` indexes them). The contract is not an industry standard
and no such standard exists for the POS→KDS lifecycle (checked 2026-09-28;
reasoning in `Upstream/generic-kds-api-v1-proposals.md`), so v1 remains ours to
improve, following its own breaking/non-breaking rules.

## Re-vendoring

```bash
cp ../SimKDS-main/docs/openapi.yaml Sources/SimKDSKit/openapi.yaml
shasum -a 256 Sources/SimKDSKit/openapi.yaml   # update the hash above
```
