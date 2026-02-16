# Cloudflare R2 Cache for BuildStream

> **Status: SUPERSEDED** -- This plan was implemented but the R2 cache infrastructure was subsequently replaced by Blacksmith sticky disks in `2026-02-15-blacksmith-sticky-disk-migration.md`. The R2 preseed and sync steps were removed in commit `17bb7a1` because the R2 archive was corrupt (93 bytes despite claiming 12.9 GB) and sticky disks provide superior performance (~3 sec mount vs minutes of download/extract). Retained for historical reference showing the evolution from bazel-remote → rclone → sticky disks.

> **For agents:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a Cloudflare R2-backed artifact cache to the existing BuildStream CI pipeline so builds can push/pull artifacts globally, dramatically reducing rebuild times.

**Architecture:** Run `bazel-remote` as a sidecar process inside the GitHub Actions workflow. It exposes a local gRPC endpoint (localhost:9092) that bridges BuildStream's CAS protocol to Cloudflare R2 via S3-compatible API. The existing GNOME upstream caches remain as read-only artifact sources. R2 becomes the project's own read-write cache.

**Tech Stack:** GitHub Actions, `bazel-remote` v2.6.1, Cloudflare R2 (S3-compatible), BuildStream 2.5 CAS protocol

### Corrections from Investigation (2026-02-14)

The following corrections were discovered by testing against actual tools:

1. **`bazel-remote` v2.6.1** (not v2.4.3). Binary name is `bazel-remote-2.6.1-linux-amd64` (not `linux-x86_64`).
2. **`--s3.auth_method=access_key`** is a **required** flag when using S3 access keys. The original plan omitted it.
3. **Health check must target HTTP port** (default 8080), not the gRPC port (9092). The `/status` endpoint is HTTP-only. Both `--http_address` and `--grpc_address` must be configured explicitly.
4. **BuildStream has no `--artifact-push` flag on `bst build`**. Pushing is a separate command: `bst artifact push --artifact-remote=... --deps all oci/bluefin.bst`. The build step uses `--artifact-remote` for pulling only.
5. **R2 bucket name is `bst-cache`** (not `egg-buildstream-cache` as originally planned).

---

## Current State

The repository already has a working CI pipeline (`.github/workflows/build-egg.yml`) that:
- Runs on `ubuntu-24.04` with `ublue-os/remove-unwanted-software` for disk space
- Builds inside the `freedesktop-sdk` bst2 container via podman
- Pulls artifacts from GNOME's upstream CAS at `gbm.gnome.org:11003` (read-only)
- Caches BuildStream *sources* with `actions/cache@v4`
- Exports OCI image, validates with `bootc container lint`, publishes to GHCR

**What's missing:** There is no project-owned artifact cache. Every CI run that can't find an artifact upstream must rebuild it from source. R2 solves this by providing persistent, global, shared artifact storage that the project controls.

## Key Design Decisions

1. **`bazel-remote` runs on the host, not inside the bst2 container.** BuildStream runs inside a podman container. The sidecar runs on the host. The bst2 container connects to the host via podman's host networking (`--add-host=host.containers.internal:host-gateway` or `--network=host`).

2. **R2 is additive, not replacing.** The existing GNOME upstream caches stay in `project.conf`. R2 is added as an additional artifact server with `push: true`.

3. **`bazel-remote` listens on port 9092** (not 9090) to avoid any conflict with other services. The port is arbitrary -- we just need consistency between the sidecar startup and the BuildStream config that references it.

4. **Cache is keyed by CAS hash.** BuildStream uses CAS (Content Addressable Storage). `bazel-remote` is CAS-native. No key management needed -- the content hash IS the key.

5. **Local disk cache (`--dir`) is set small** (5 GB). The real storage is R2. The local dir is just a hot cache to avoid redundant S3 round-trips within a single build.

---

## Task 1: Create Cloudflare R2 Bucket and API Credentials

**This is a manual step (not code).**

**Step 1: Create the R2 bucket**
- Log into Cloudflare Dashboard > R2 Object Storage
- Create bucket named `egg-buildstream-cache`
- Region: Auto (or nearest to GitHub Actions runners, typically US)
- No custom domain needed

**Step 2: Create API token**
- Cloudflare Dashboard > R2 > Manage R2 API Tokens
- Create token with "Object Read & Write" permission scoped to the `egg-buildstream-cache` bucket
- Save the **Access Key ID** and **Secret Access Key**
- Note the **S3 endpoint**: `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`

**Step 3: Add GitHub Secrets**
- Go to the GitHub repo Settings > Secrets and Variables > Actions
- Add these repository secrets:

| Secret Name | Value |
|---|---|
| `R2_ACCESS_KEY` | The Access Key ID from step 2 |
| `R2_SECRET_KEY` | The Secret Access Key from step 2 |
| `R2_ENDPOINT` | `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` |

**Step 4: Verify**
Confirm all three secrets appear in the repository's Actions secrets list.

---

## Task 2: Add `bazel-remote` Sidecar to the Workflow

**Files:**
- Modify: `.github/workflows/build-egg.yml`

This is the core change. We add steps to download, start, and health-check `bazel-remote` before the BuildStream build runs.

**Step 1: Add R2 environment variables to the workflow**

Add these env vars to the top-level `env:` block in `build-egg.yml`:

```yaml
env:
  IMAGE_NAME: egg
  IMAGE_REGISTRY: ghcr.io/${{ github.repository_owner }}
  BST2_IMAGE: registry.gitlab.com/freedesktop-sdk/infrastructure/freedesktop-sdk-docker-images/bst2:f89b4aef847ef040b345acceda15a850219eb8f1
  CACHE_PORT: 9092
  CACHE_DIR: /tmp/bazel-remote-cache
```

**Step 2: Add the sidecar startup step**

Insert this step **after** "Prepare BuildStream cache directory" and **before** "Generate BuildStream CI config":

```yaml
      # ── R2 Cache Proxy ──────────────────────────────────────────────
      # bazel-remote acts as a local CAS server that bridges to Cloudflare R2.
      # BuildStream (inside bst2 container) connects to this on the host.

      - name: Start R2 cache proxy
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        env:
          R2_ACCESS_KEY: ${{ secrets.R2_ACCESS_KEY }}
          R2_SECRET_KEY: ${{ secrets.R2_SECRET_KEY }}
          R2_ENDPOINT: ${{ secrets.R2_ENDPOINT }}
        run: |
          # Download bazel-remote
          wget -q "https://github.com/buchgr/bazel-remote/releases/download/v2.4.3/bazel-remote-2.4.3-linux-x86_64" \
            -O /usr/local/bin/bazel-remote
          chmod +x /usr/local/bin/bazel-remote

          mkdir -p "$CACHE_DIR"

          # Start in background
          bazel-remote \
            --s3.endpoint="${R2_ENDPOINT}" \
            --s3.bucket="egg-buildstream-cache" \
            --s3.access_key_id="${R2_ACCESS_KEY}" \
            --s3.secret_access_key="${R2_SECRET_KEY}" \
            --dir="${CACHE_DIR}" \
            --max_size=5 \
            --grpc_address="0.0.0.0:${CACHE_PORT}" \
            --s3.prefix="cas" \
            > /tmp/bazel-remote.log 2>&1 &

          echo $! > /tmp/bazel-remote.pid

          # Wait for it to be ready
          for i in $(seq 1 30); do
            if curl -sf "http://localhost:${CACHE_PORT}/status" > /dev/null 2>&1; then
              echo "Cache proxy ready on port ${CACHE_PORT}"
              exit 0
            fi
            sleep 1
          done

          echo "ERROR: Cache proxy failed to start"
          cat /tmp/bazel-remote.log
          exit 1
```

Note: The `if:` condition means the R2 proxy only runs on pushes to main. PR builds use only the upstream GNOME cache. This is intentional -- PRs don't need write access to the shared cache, and it avoids exposing secrets to PR builds from forks.

**Step 3: Modify the BuildStream build step to connect to the cache**

Update the "Build OCI image with BuildStream" step to pass the cache proxy endpoint into the bst2 container. The bst2 container needs to reach the host's port 9092.

Change the `podman run` command to include `--network=host` OR add `--add-host=host.containers.internal:host-gateway` and reference the host IP. Using `--network=host` is simpler:

```yaml
      - name: Build OCI image with BuildStream
        run: |
          # Determine cache args
          CACHE_ARGS=""
          if [ -f /tmp/bazel-remote.pid ]; then
            # Host network mode so container can reach the cache proxy
            NETWORK_MODE="--network=host"
            CACHE_ARGS="--artifact-remote=grpc://localhost:${CACHE_PORT} --artifact-push"
          else
            NETWORK_MODE=""
          fi

          podman run --rm \
            --privileged \
            --device /dev/fuse \
            ${NETWORK_MODE} \
            -v "${{ github.workspace }}:/src:rw" \
            -v "$HOME/.cache/buildstream:/root/.cache/buildstream:rw" \
            -w /src \
            "$BST2_IMAGE" \
            bash -c "
              ulimit -n 1048576
              bst --no-interactive \
                  --colors \
                  --config /src/buildstream-ci.conf \
                  --log-file /src/logs/build.log \
                  ${CACHE_ARGS} \
                  build oci/bluefin.bst
            "
        timeout-minutes: 120
```

**Important:** The `--artifact-remote` and `--artifact-push` flags are passed as bst CLI arguments, NOT in `project.conf`. This keeps the project.conf clean and avoids affecting local developer builds.

**Step 4: Add cache proxy log upload and cleanup**

Add this step after the existing "Upload build logs" step:

```yaml
      - name: Upload cache proxy logs
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: cache-proxy-logs
          path: /tmp/bazel-remote.log
          retention-days: 7
          if-no-files-found: ignore

      - name: Stop cache proxy
        if: always()
        run: |
          if [ -f /tmp/bazel-remote.pid ]; then
            kill "$(cat /tmp/bazel-remote.pid)" 2>/dev/null || true
          fi
```

**Step 5: Update the Export step similarly**

The export step also runs inside bst2 and needs the same network/cache config. Update "Export OCI image from BuildStream":

```yaml
      - name: Export OCI image from BuildStream
        id: export
        run: |
          NETWORK_MODE=""
          if [ -f /tmp/bazel-remote.pid ]; then
            NETWORK_MODE="--network=host"
          fi

          LOADED=$(podman run --rm \
            --privileged \
            --device /dev/fuse \
            ${NETWORK_MODE} \
            -v "${{ github.workspace }}:/src:rw" \
            -v "$HOME/.cache/buildstream:/root/.cache/buildstream:rw" \
            -w /src \
            "$BST2_IMAGE" \
            bash -c '
              ulimit -n 1048576
              bst --no-interactive \
                  --config /src/buildstream-ci.conf \
                  artifact checkout --tar - oci/bluefin.bst
            ' | podman load)
          IMAGE_REF=$(echo "$LOADED" | grep -oP '(?<=Loaded image: ).*' || \
                      echo "$LOADED" | grep -oP '(?<=Loaded image\(s\): ).*')
          echo "image_ref=$IMAGE_REF" >> "$GITHUB_OUTPUT"
          echo "Loaded: $IMAGE_REF"
```

**Step 6: Commit**

```bash
git add .github/workflows/build-egg.yml
git commit -m "feat: add Cloudflare R2 cache proxy via bazel-remote sidecar"
```

---

## Task 3: Validate the Integration

**Step 1: Trigger a test build**

Push the workflow change to a branch and create a PR. Since the R2 proxy only runs on `main` pushes (via the `if:` condition), the PR build should still work using only the upstream GNOME cache. This validates we haven't broken the existing pipeline.

```bash
git checkout -b feat/r2-cache
git push -u origin feat/r2-cache
# Open PR via gh cli or GitHub UI
```

**Step 2: Verify PR build succeeds without R2**

Check the GitHub Actions run for the PR. The "Start R2 cache proxy" step should be **skipped** (greyed out). The build should proceed normally using only the GNOME upstream cache.

**Step 3: Merge to main and verify R2 integration**

After the PR build passes, merge to main. The subsequent push-to-main build should:
1. Start the `bazel-remote` proxy (check the step output for "Cache proxy ready on port 9092")
2. Run BuildStream with `--artifact-remote` and `--artifact-push` flags
3. Push built artifacts to R2

**Step 4: Verify R2 has data**

After a successful main-branch build, check the Cloudflare R2 dashboard. The `egg-buildstream-cache` bucket should now contain objects under the `cas/` prefix.

**Step 5: Verify cache hits on second build**

Re-run the workflow on main (via `workflow_dispatch`). Check BuildStream's output logs for cache hit messages. Artifacts that were pushed in step 3 should now be pulled from R2 instead of being rebuilt.

---

## Task 4: Add Cache to PR Builds (Read-Only)

**Files:**
- Modify: `.github/workflows/build-egg.yml`

**This task is optional and should only be done after Task 3 is validated.**

Once the cache has data, PR builds can benefit from reading it. The change is to run the proxy on all builds but only push on main.

**Step 1: Modify the sidecar `if:` condition**

Change the "Start R2 cache proxy" step's `if:` to always run (remove the condition), but the secrets will only be available for non-fork PRs. Handle the case where secrets are empty:

```yaml
      - name: Start R2 cache proxy
        env:
          R2_ACCESS_KEY: ${{ secrets.R2_ACCESS_KEY }}
          R2_SECRET_KEY: ${{ secrets.R2_SECRET_KEY }}
          R2_ENDPOINT: ${{ secrets.R2_ENDPOINT }}
        run: |
          # Skip if secrets aren't available (fork PRs)
          if [ -z "$R2_ACCESS_KEY" ] || [ -z "$R2_ENDPOINT" ]; then
            echo "R2 secrets not available, skipping cache proxy"
            exit 0
          fi

          # ... rest of startup script unchanged ...
```

**Step 2: Make push conditional on branch**

In the build step, only add `--artifact-push` on main:

```yaml
          CACHE_ARGS=""
          if [ -f /tmp/bazel-remote.pid ]; then
            NETWORK_MODE="--network=host"
            CACHE_ARGS="--artifact-remote=grpc://localhost:${CACHE_PORT}"
            if [ "${{ github.ref }}" = "refs/heads/main" ]; then
              CACHE_ARGS="${CACHE_ARGS} --artifact-push"
            fi
          fi
```

**Step 3: Commit**

```bash
git add .github/workflows/build-egg.yml
git commit -m "feat: enable R2 cache reads for PR builds"
```

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `bazel-remote` CAS protocol incompatible with BuildStream | Medium | High | BuildStream uses standard CAS v2 API; bazel-remote implements it. Test early. If incompatible, fall back to configuring BuildStream's native S3 artifact server support. |
| `--network=host` breaks podman sandbox | Low | Medium | BuildStream already runs `--privileged`. Host networking is no less secure. If issues arise, use `--add-host` + explicit IP instead. |
| R2 latency slows builds | Low | Low | `bazel-remote` local disk cache (`--dir`) absorbs repeated reads. R2 is globally distributed. 5GB local cache covers most hot artifacts. |
| Secrets unavailable on fork PRs | Expected | None | Handled by the `if [ -z ... ]` guard. Fork PRs build without R2, same as today. |
| `bazel-remote` binary URL changes/breaks | Low | Low | Pin the exact version. Consider vendoring or using a container image instead. |

## Alternative Considered: BuildStream Native Remote Cache

BuildStream can connect directly to CAS servers configured in `project.conf`. However:
- It doesn't speak S3 natively -- it needs a CAS gRPC endpoint
- `bazel-remote` IS that CAS gRPC endpoint, backed by S3/R2
- This is the standard approach used by Bazel, BuildStream, and other CAS-based build systems

Adding the cache directly in `project.conf` was considered but rejected because:
- It would affect local developer builds
- Credentials would need to be managed differently
- CLI flags (`--artifact-remote`) are cleaner for CI-only configuration

---

## Summary of File Changes

| File | Change |
|---|---|
| `.github/workflows/build-egg.yml` | Add R2 env vars, sidecar startup/teardown steps, modify build step for `--network=host` and `--artifact-remote`/`--artifact-push` |
| `project.conf` | **No changes** |
| `Containerfile` | **No changes** |

Total: **1 file modified**, **~50 lines added**.
