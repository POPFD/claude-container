# Step 2 notes: Default allowlist.yaml

## Decisions
- Sentry telemetry is NOT allowlisted by default. The bare `sentry.io`
  entry would not have matched what the SDK actually POSTs to
  (typically `*.ingest.sentry.io`); shipping an incorrect entry is
  worse than shipping none. Operators who hit eligibility errors can
  add the correct wildcard explicitly.
- `static.rust-lang.org` is NOT in the runtime allowlist. It's only
  needed at image build time for rustup self-install. Runtime rootfs
  is read-only so no self-updates happen anyway.
- `ports.overrides` uses a list-of-dicts shape `[{match: ..., ports: [...]}]`
  rather than a map keyed by domain. Rationale: domain strings can
  contain wildcards and characters that are awkward as YAML keys; an
  explicit `match` key also leaves room for future fields (e.g.
  `protocol: tcp|udp`).
- `cidrs: []` kept as an empty list rather than omitting the key. Keeps
  the reconciler's parser simple (no conditional for missing key).

## Constraints surfaced
- Wildcard entries can ONLY be matched at the DNS layer (no IP pinning).
  This must be enforced in the reconciler (step 4) and tested there.
- `ports.overrides[].match` is an exact domain match only, per inline
  comment. Do not add glob/suffix matching in the reconciler without
  updating this schema doc first.

## For later steps
- Reconciler (step 4) reads this file from `/config/allowlist.yaml`
  (bind-mounted read-only into the sidecar per plan step 9).
- Firewall bootstrap (step 5) derives the union of ports from
  `ports.default + flatten(ports.overrides[].ports)` to decide which
  destination ports to wire into the OUTPUT chain's ipset-match rules.
- The e2e verification (step 11) references three domains explicitly:
  `api.anthropic.com` (allowed, port 443), `github.com` (allowed,
  ports 22+443), `raw.githubusercontent.com` (wildcard-allowed, DNS
  only). Do not remove these from the default allowlist without
  updating the e2e step.

## Review resolutions
- Reviewer blocked on `sentry.io` (wrong hostname — Sentry SDK POSTs to
  `*.ingest.sentry.io`, not `sentry.io`). Removed; added a comment
  documenting how to re-enable with the correct host.
- Suggestion: drop `static.rust-lang.org` from runtime allowlist
  (build-time only). Applied; comment explains.
- Suggestion: annotate the `*.githubusercontent.com` wildcard as a
  broad DNS-exfil surface. Applied as inline comment.
