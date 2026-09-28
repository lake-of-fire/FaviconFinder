# Porting work: v3-hotfix networking fixes → main

**Planning-only draft; implementation and tests remain open.**

Destination main: `dba1692ad10917e5501f7da61c5d53290ac10e7e`.
Source: `9fdaeba2c01bd9692d79029b5179205eac7276bc`.
The histories diverge (6 source-only / 3 main-only commits). Select behavior after tip-to-tip review; do not treat that count as six missing patches or replace package manifests wholesale.

## Confirmed source/destination differences

`Sources/FaviconFinder/Toolbox/FaviconURLSession.swift` was inspected on both revisions.

Main's top-level `dataTask` accepts `[String?: String]?` but does not forward `httpHeaders` to either backend. The source uses the backend-compatible `[String: String?]?` and forwards headers, omitting nil-valued Linux headers rather than converting them to empty strings.

Main's Linux collector already caps the body at 2 MiB. The source centralizes that same limit in `maximumResponseBytes` and routes Apple requests through `boundedData(for:)`. Do not describe Linux bounds as a new feature; the useful candidate is cross-platform parity and enforcing the cap during collection, not after allocating an unbounded response.

The source also resolves meta-refresh via a helper and applies `headersForMetaRefreshRedirect` rather than blindly reusing credentials. Treat header forwarding and origin-aware redirect behavior as one security-sensitive port.

## Implementation checklist

- [ ] Port header type/forwarding through the complete caller chain. Check HTML, ICO and web-app manifest finder request entry points and nil-value semantics.
- [ ] Adapt Apple bounded response collection while retaining Linux's existing cap, cancellation, timeout, status/error handling and supported deployment targets.
- [ ] Port/test relative and absolute meta-refresh resolution, an explicit follow budget, and same-origin versus cross-origin/downgrade header handling. Verify ordinary HTTP redirects too; a meta-refresh helper does not by itself establish that boundary.
- [ ] Review `Types/Favicon.swift`, `Types/FaviconURL.swift` and the individual finder URL/decoding changes against main, retaining newer/equivalent destination behavior.
- [ ] Preserve public API compatibility where applicable, current dependencies and Swift-version-specific manifests. Do not downgrade packages or alter example apps merely because they differ in the merge-base comparison.
- [ ] Retain all main tests and adapt the source's network/URL regression cases additively.

## Required behavior tests

Use deterministic local responses or injected transport, not live third-party sites. Cover custom headers reaching each backend; absent/nil headers; same-origin preservation; cross-origin and HTTPS→HTTP sensitive-header stripping; relative/malformed/cyclic meta-refresh; redirect limits; exactly-at-limit and over-limit streamed bodies, missing/false Content-Length, empty body, cancellation and failed decode. Exercise HTML/ICO/manifest callers, not only helper functions.

Run the package's Apple and Linux tests and supported Swift manifest variants. Verify bounded collection does not inadvertently break valid ordinary favicon responses. Document the intentionally rejected oversized case and any compatibility change.

No production source, manifest or test is changed by this document. No network, package or platform test pass is claimed. Keep the PR draft until the selected implementation and these gates are complete; the consumer's gitlink advance is a separate integration step.
