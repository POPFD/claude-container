# Step 7 notes: devbox language toolchains

## Decisions
- **rustup installed with `--profile minimal`** + explicit `clippy` +
  `rustfmt` components. Skips docs, standalone rustup-init (~200 MB
  savings). Image is 1327 MB total.
- **Node LTS via NodeSource** rather than nvm or a tarball. Keeps
  upgrade story via apt later if needed. `corepack enable` provides
  pnpm at invocation time (first `pnpm --version` triggers a
  one-time download — acceptable at image-use, registry.npmjs.org is
  in the runtime allowlist).
- **uv via astral.sh official installer** into `/home/dev/.local/bin`.
  Explicitly NOT pinning a version — upstream installer pulls the
  latest. Pin at image-tag time if reproducibility matters.
- **PATH is exported via `ENV` at image level** AND written into
  `.bashrc` + `.profile`. Some shells bypass `.bashrc` (non-interactive
  non-login) so the `ENV` is the reliable path; the dotfiles cover
  interactive sessions started via `docker exec -it ... bash -l`.
- **No self-update**: `UV_NO_UPDATE_CHECK=1` in ENV; rustup has no
  self-update at runtime because the rootfs is read-only. Toolchain
  installs happen at image build time only.
- **Python baseline is apt python3 + pip + venv**, *not* uv-managed
  python. Rationale: apt python3 is already there and `uv` can manage
  project-local venvs on top. For users who want uv-managed Python
  runtimes, `uv python install` works at runtime (downloads go
  through the allowlist to the uv index).

## Constraints surfaced
- `corepack enable` must be run as root BEFORE the USER switch,
  because it writes to /usr/local/bin. Done in the Node layer.
- First `pnpm --version` after build downloads pnpm itself from
  registry.npmjs.org. This is a ONE-TIME network fetch — operators
  who cold-start in a sandboxed first-run will see it fail until
  the registry is reached once. Consider pre-downloading with
  `corepack prepare pnpm@latest --activate` as an image optimization
  (deferred for v1).
- `rustc --version` at build-time requires `.cargo/bin` on PATH;
  the ENV directive handles this but note the install script also
  modifies `.profile` (we use `--no-modify-path` to prevent that so
  our authoritative ENV is the source of truth).

## For later steps
- **Step 8**: Claude CLI install may be trivial (uses npm or a
  release tarball). If npm-based: it will use the pnpm/npm that's
  already on PATH. If curl|sh from anthropic: the allowlist already
  includes `api.anthropic.com` / `claude.ai` — confirm the installer
  host at step 8 time.
- **Step 9 compose** must mount `tool-caches` at `/home/dev/.cargo`
  so `cargo build` in a bind-mounted project caches crates
  persistently. `.rustup` does NOT need a volume — toolchain is
  baked into the image and shouldn't change at runtime.
- **Project-local caches (`target/`, `node_modules/`, `.venv/`)**
  live under the workspace bind mount and persist naturally with the
  host filesystem.

## Review resolutions
- _filled in after review pass_
