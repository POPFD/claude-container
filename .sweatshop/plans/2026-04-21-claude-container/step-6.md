# Step 6 notes: devbox base image

## Decisions
- **Ubuntu 24.04 ships a default `ubuntu` user at uid 1000.**
  `useradd --uid 1000 dev` fails with exit code 4 unless we
  `userdel -r ubuntu` first. Order matters.
- Shipped `gosu` here (originally listed in step 8) — step 8's
  two-stage entrypoint (root → dev for the chown) needs it and
  pulling it in now saves a Dockerfile rebuild.
- Kept `sudo` in the image baseline for the operator's convenience
  if they `docker exec -u root ... bash`. `dev` is NOT in sudoers
  and will not be granted sudo in later steps — the container's
  security boundary is the container itself, not the user inside.
- `DEBIAN_FRONTEND=noninteractive` is an `ENV`, which means it
  persists to runtime. Benign but worth noting — any later
  `apt-get install` the operator runs interactively inside the
  container will also skip prompts.
- `libcap2-bin` pulls in `capsh` for step-11 verification of the
  empty-capability invariant.

## Constraints surfaced
- The `userdel -r ubuntu` wipes `/home/ubuntu` but `useradd --create-home`
  creates `/home/dev` fresh. Good — the old home dir's files are gone.
- `USER dev` at the Dockerfile level means `docker run` starts as dev
  by default. Step 8's entrypoint will switch to ROOT for startup
  (for chown) and then back to dev via gosu.

## For later steps
- **Step 7 toolchain install must run as `dev`** so files land under
  `/home/dev/.rustup`, `/home/dev/.cargo`, `/home/dev/.local/bin`.
  Dockerfile will need to stay on `USER dev` or use `gosu dev`.
- **Step 8 entrypoint** expects gosu already installed (done here).
- **Step 9 compose** sets USER back to root at the image level via
  the entrypoint chmod/chown logic (then drops to dev via gosu).

## Review resolutions
- _filled in after review pass_
