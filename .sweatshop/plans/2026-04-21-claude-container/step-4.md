# Step 4 notes: Allowlist reconciler

## Decisions
- Added `py3-pytest` to the image so test runs don't need network to
  `pip install`. Image grew 69.3 MB (still under budget).
- **Resolver injection pattern**: `build_ipset_members(allowlist, resolve)`
  takes a resolver callable, not a hardcoded implementation. Lets tests
  use stubs without monkeypatching. The real `dig_resolver(upstream)`
  closure is only used in main.
- **Retry is per-RR-type, not per-domain**: a domain that returns A
  records but no AAAA is counted as succeeded. Some domains are v4-only.
  Without this the retry loop would spin uselessly on AAAA for v4-only
  hosts.
- **Partial-success semantics**: `resolve_all` exits 0 if *any* domain
  resolved, 1 only if *all* failed. Matches plan (step 5 uses this to
  decide whether to crash the sidecar at bootstrap).
- **ipset update uses tmp-swap-destroy idiom**: build a `*_tmp` set,
  populate, swap in atomically, destroy old. Prevents a window where
  the active set is empty or stale during reconcile.
- **Wildcard encoding in Allowlist**: `*.foo.com` is stored as
  `wildcard_suffixes=["foo.com"]` (prefix stripped). The reconciler
  never needs the raw `*.` form — unbound forward-zones want the base
  suffix, and ipsets never see wildcards at all.
- **Dry-run stub resolver** gated by `RECONCILE_STUB_RESOLVER=1` env
  var. Lets the dry-run JSON test run without network. Real usage
  (in-container) always uses dig_resolver.

## Constraints surfaced
- `dig +short` prints multiple address lines; the resolver parser
  filters out comment lines and empty strings. If dig output format
  ever changes (unlikely), the filter may need attention.
- `ipset create` with `-exist` is idempotent but `ipset swap` requires
  both sets to exist with matching types. Kept families separate
  (`hash:net family inet` vs `hash:net family inet6`) — mixing would
  swap-fail.
- `hash:net` supports both bare IPs and CIDRs, so cidrs + resolved
  IPs go into the same set without type conversion.
- Tests use a separate fixture (`tests/fixtures/sample-allowlist.yaml`)
  rather than the production `config/allowlist.yaml`. Changes to the
  production allowlist must not affect unit test outcomes.

## For later steps
- **Step 5 (entrypoint)** must:
  - Create the ipsets *before* installing iptables rules that reference
    them, or iptables will fail with "Set allowed_v4 doesn't exist".
    (The reconciler's `apply_ipsets` creates them, but step 5 bootstrap
    must run reconcile before the ipset-matching iptables rules.)
  - Read port set for the OUTPUT chain from `Allowlist.all_ports()` —
    the helper already computes the union. Step 5 can call `parse_allowlist`
    directly or invoke `reconcile.py --dry-run` and read the `ports.union`.
  - Set `RECONCILE_STUB_RESOLVER` is NOT an option at runtime; the real
    dig resolver is always used.
- **Step 9 (compose)**: `/config/allowlist.yaml` is the expected mount
  path (matches `--config` default).
- The reconciler writes `/etc/unbound/unbound.conf.d/allowlist.conf`.
  Step 5's base unbound.conf must `include:` this directory.

## Review resolutions
- **Blocker**: operator-precedence bug in `dig +short` output filter.
  `not startswith(";") and "." in line or ":" in line` parsed as
  `(... and "." in line) or (":" in line)`, leaking comment lines
  with `:` through on AAAA queries. Extracted into
  `parse_dig_output()` with clean AND-chained guards + new tests
  (filters comments, strips CNAME hostnames, handles empty input).
- **Blocker**: `write_unbound_conf` did in-place `path.write_text(...)`
  — crash mid-write could leave unbound reading a truncated config
  and (if restarted) losing the `local-zone: "." refuse` default.
  Switched to temp-and-rename via `os.replace()` (atomic on POSIX).
  Added idempotency test + no-stale-tmp test.
- **Blocker**: partial-failure semantics silently applied degraded
  allowlist under an "ok" log line. Distinct exit codes now:
  0=all succeeded, 2=partial, 1=total. Partial/total paths emit a
  `reconcile DEGRADED` line at WARNING/ERROR with the full failed
  domain list — no more silent degradation.
- Test fix: replaced fragile multi-condition assertion in
  `test_unbound_conf_no_dot_uses_port_53` with the exact string
  `forward-addr: 1.1.1.1@53` per reviewer note.
- Suggestion (deferred): multi-stage build to remove `py3-pytest`
  and `openssl` from the runtime image. Budget isn't pressured;
  revisit if image is ever pushed to a registry (ties to the
  unbound-key baking deferral).
- Suggestion (noted): `_dry_run_payload` doesn't exercise retry
  logic (goes straight through the injected resolver). Documented
  in the function's use site.
