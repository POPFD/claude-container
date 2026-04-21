# Step 3 notes: fw-sidecar base image

## Decisions
- Added `openssl` to the apk install list — `unbound-control-setup`
  shells out to `openssl` to generate the control-socket keypair and
  the Alpine `unbound` package does not pull it in as a hard dep.
  Discovered during the first build attempt (exit code 127).
- Kept `.dockerignore` minimal: excludes `.gitkeep` and `tests/` so
  the unit-test fixtures added in step 4 don't bloat the image.
- Entrypoint is `/sbin/tini -- /entrypoint.sh` so step 5's real
  entrypoint inherits correct signal propagation without changes to
  the Dockerfile ENTRYPOINT directive.
- The placeholder entrypoint uses `tail -f /dev/null` rather than
  `sleep infinity` so signals still work under tini (either works;
  chose tail for the conventional idiom).

## Constraints surfaced
- **ipset requires NET_ADMIN at runtime**, confirmed during verify:
  `ipset -v` without the cap returned "Operation not permitted" on
  the kernel-error line but still printed version. Step 5 must run
  with `--cap-add NET_ADMIN` for any actual ipset manipulation.
- `unbound-control-setup` bakes the control socket key/cert PAIR
  INTO THE IMAGE. Any container started from the same image has the
  same keys. Already documented as a known deferral in plan.md; low
  risk because the socket is loopback and the sidecar runs root-only.
- Image size is 62.8 MB — well under the 110 MB budget. No pressure
  to go multi-stage.

## For later steps
- Step 4 reconciler tests (`fw-sidecar/tests/`) must NOT be COPYed
  into the image (they're in `.dockerignore`). The test runner runs
  against the source tree on the host.
- Step 5 entrypoint must start `unbound` in daemon mode BEFORE
  calling reconcile, and poll `unbound-control status` until ready.
  Remote-control socket config must be set in `unbound-base.conf`.
- Step 5 MUST assert at boot that iptables is backed by `nf_tables`
  (`iptables --version | grep -q nf_tables`). On a host kernel
  without `nf_tables`, rule install will silently fail.
- When running fw-sidecar standalone (without NET_ADMIN) some
  commands print kernel-error lines on stderr; that's expected and
  only the real deployment (step 9 compose) runs with the cap.
- Debug tools available in-sidecar: `ip` (iproute2) for
  interface/routing, `conntrack` for connection-table inspection.

## Review resolutions
- Reviewer blocked: alpine:3.19 is EOL (November 2024). Bumped to
  `alpine:3.21`. Rebuilt and re-verified; image still under budget
  at 64.6 MB.
- Reviewer suggestion: add `conntrack-tools` and `iproute2` for
  debugging. Applied — small size hit, real operational value.
- Reviewer suggestion: note image-must-not-be-pushed-to-registry for
  the baked unbound keys. Updated plan.md's known-deferrals entry.
- Reviewer noted nf_tables backend requirement for step 5 — captured
  in "For later steps" above.
- Reviewer noted multi-stage build could remove openssl from runtime
  image. Deferred — not blocking, 64.6 MB is well under budget, and
  multi-stage complicates cache hits for iteration. Revisit if
  image ever ships to a registry.
