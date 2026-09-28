# Security

## Scope

This package is the data layer of a kitchen-display tablet. It holds no secrets
of its own: the API token lives in the app's Keychain (CLAUDE.md rule 8), and
`KdsDeviceSettings` carries plain fields only. Two surfaces are
security-relevant and tested:

- **Provisioning links** (`simkds://provision?…`) — credentials in a URL are
  rejected (`KdsProvisioning`, `authParamKeys`), because a link can be
  photographed, logged, or forwarded.
- **Transport** — a remote `http://` base URL is refused at client
  construction; cleartext is allowed only to loopback hosts for the local mock
  server, matching the upstream contract (`docs/api.md`).

Guest data never reaches the board unsanitized (`GuestTextSanitizer`).

## Reporting

Use GitHub's private vulnerability reporting on this repository (Security →
Report a vulnerability). Please do not open a public issue for something that
could expose a deployment. Defects in the Generic KDS API v1 *contract* itself
belong to the upstream Android repository; `Upstream/README.md` says how those
are filed.
