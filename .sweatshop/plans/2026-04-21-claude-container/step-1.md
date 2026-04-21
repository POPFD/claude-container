# Step 1 notes: Scaffold repo layout and .env.example

## Decisions
- Used `.gitkeep` files to preserve empty scaffolding directories in
  git (standard convention; no content needed).
- Added `.claude/` to `.gitignore` when an unexpected
  `.claude/settings.local.json` appeared during execution — it's a
  per-operator Claude Code session artifact, not project-shared state.
- `CARGO_NET_OFFLINE_AFTER` kept as a commented-out documentation
  reminder rather than an active setting; actual cargo offline
  semantics are via `cargo --offline` or config.toml, not env.

## Constraints surfaced
- `workspace/*` gitignore pattern must always accompany
  `!workspace/.gitkeep` — future steps that add files under workspace/
  for tests should either use `git add -f` or put test fixtures
  elsewhere (e.g. `fw-sidecar/tests/fixtures/`).

## For later steps
- `.env` tunables established for the whole stack:
  `DEVBOX_NAME`, `MEM_LIMIT`, `PIDS_LIMIT`, `DNS_UPSTREAM`,
  `DNS_UPSTREAM_TLS` (0/1), `WORKSPACE_PATH`, `UV_NO_UPDATE_CHECK=1`.
  Step 9 (compose.yaml) should surface all of these; step 4/5
  (reconciler + entrypoint) reads `DNS_UPSTREAM` and `DNS_UPSTREAM_TLS`.
- `.claude/` is gitignored — don't be surprised if it appears during
  execution; do not add its contents to commits.
- Env-var lifecycle split: `UV_NO_UPDATE_CHECK` is baked as a
  Dockerfile `ENV` in step 7 (build-time), not read from `.env` at
  runtime. `DEVBOX_NAME`, `MEM_LIMIT`, `PIDS_LIMIT`, `WORKSPACE_PATH`,
  `DNS_UPSTREAM`, `DNS_UPSTREAM_TLS` are runtime vars surfaced via
  compose.yaml in step 9.

## Review resolutions
- Reviewer noted `UV_NO_UPDATE_CHECK` is build-time, not runtime.
  Added that distinction to the env-var lifecycle note above.
