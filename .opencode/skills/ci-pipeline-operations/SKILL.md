---
name: ci-pipeline-operations
description: Use when debugging CI failures, understanding the build pipeline, modifying the GitHub Actions workflow, working with artifact caching, or troubleshooting why a build succeeded locally but fails in CI
---

# CI Pipeline Operations

## Overview

The CI pipeline (`.github/workflows/build-egg.yml`) builds the Bluefin OCI image inside the bst2 container on GitHub Actions, validates it with `bootc container lint`, and pushes to GHCR on main. Caching uses a two-tier architecture: GNOME upstream CAS (read-only, configured in `project.conf`) + project R2 cache (read-write via rclone direct to Cloudflare R2).

## Quick Reference

| What | Value |
|---|---|
| Workflow file | `.github/workflows/build-egg.yml` |
| Runner | `Testing` (self-hosted) |
| Build target | `oci/bluefin.bst` |
| Build timeout | 120 minutes |
| bst2 container | `registry.gitlab.com/.../bst2:<sha>` (pinned in workflow `env.BST2_IMAGE`) |
| GNOME CAS endpoint | `gbm.gnome.org:11003` (gRPC, read-only) |
| Cache strategy | rclone direct to Cloudflare R2 (no proxy) |
| CAS archive format | `cas.tar.zst` (single zstd-compressed tar) |
| Metadata sync | `artifacts/` and `source_protos/` (per-file rclone copy) |
| Background sync interval | Every 5 minutes during build |
| Background sync coordination | PID file (`/tmp/r2-sync-loop.pid`); killed before final sync |
| R2 bucket | `bst-cache` |
| Published image | `ghcr.io/projectbluefin/egg:latest` and `:$SHA` |
| Build logs artifact | `buildstream-logs` (7-day retention) |

## Workflow Steps

| # | Step | What it does | Notes |
|---|---|---|---|
| 1 | Checkout | Clones the repo | Standard |
| 2 | Pull bst2 image | `podman pull` of the pinned bst2 container | Same image as GNOME upstream CI |
| 3 | Cache BST sources | `actions/cache` for `~/.cache/buildstream/sources` | Key: hash of `elements/**/*.bst` + `project.conf` |
| 4 | Prepare cache dir | `mkdir -p` for `sources`, `cas`, `artifacts`, `source_protos` | Ensures cache restore has targets |
| 5 | Install rclone | `curl -fsSL https://rclone.org/install.sh \| sudo bash` | Used for all R2 interactions |
| 6 | Install just | `apt-get install -y just` | Used by build and export steps |
| 7 | Restore BuildStream cache from R2 | Downloads `cas.tar.zst`, validates with `zstd -t`, extracts; syncs artifact refs and source protos | Skips if R2 secrets missing; prints CACHE RESTORE REPORT |
| 8 | Generate BST config | Writes `buildstream-ci.conf` with CI-tuned settings | No remote artifact server — only local cache + upstream GNOME |
| 9 | Start background R2 sync | Launches `/tmp/r2-sync-loop.sh` as background process | Uploads CAS snapshot + metadata every 5 min; atomic upload (temp name + rename) |
| 10 | Build | `just bst --log-file /src/logs/build.log build oci/bluefin.bst` | `--privileged --device /dev/fuse`; no `--network=host` needed |
| 11 | Disk and cache usage | `df -h /` + `du -sh` of cache components | Diagnostic; always runs |
| 12 | Final sync to R2 | Kills background sync, uploads definitive CAS archive + metadata | Atomic upload (temp name + rename); always runs; `continue-on-error: true` |
| 13 | Export OCI image | `just export` (checkout + skopeo load + bootc fixup) | Uses Justfile recipe |
| 14 | Verify image loaded | `podman images` | Diagnostic |
| 15 | bootc lint | `bootc container lint` on exported image | Validates ostree structure, no `/usr/etc`, valid bootc metadata |
| 16 | Upload build logs | `actions/upload-artifact` | Always runs, even on failure |
| 17 | Login to GHCR | `podman login` with `GITHUB_TOKEN` | **Main only** |
| 18 | Tag for GHCR | Tags as `:latest` and `:$SHA` | **Main only** |
| 19 | Push to GHCR | `podman push --retry 3` both tags | **Main only** |

## CI BuildStream Config

Generated as `buildstream-ci.conf` at step 8. Values and rationale:

| Setting | Value | Why |
|---|---|---|
| `on-error` | `continue` | Find ALL failures in one run, not just the first |
| `fetchers` | `12` | Parallel downloads from artifact caches |
| `builders` | `1` | GHA has 4 vCPUs; conservative to avoid OOM |
| `network-retries` | `3` | Retry transient network failures |
| `retry-failed` | `True` | Auto-retry flaky builds |
| `error-lines` | `80` | Generous error context in logs |
| `cache-buildtrees` | `never` | Save disk; only final artifacts matter |
| `max-jobs` | `0` | Let BuildStream auto-detect (uses nproc) |

**Important:** No remote artifact server is configured in `buildstream-ci.conf`. BuildStream uses only local disk cache (restored from R2 before the build) and upstream GNOME caches defined in `project.conf` (read-only). After the build, rclone syncs everything back to R2.

## Caching Architecture

Two layers of remote caching, plus local disk:

```
1. Local CAS (~/.cache/buildstream/)
   Restored from R2 at build start, uploaded back at build end
   |-- miss -->
2. GNOME upstream CAS (https://gbm.gnome.org:11003)
   Read-only, configured in project.conf
   |-- miss -->
3. Build from source
```

### How R2 Cache Works

The R2 cache stores three components:

| Component | R2 path | Format | Sync method |
|---|---|---|---|
| CAS objects | `cas.tar.zst` | Single zstd-compressed tar archive | Download at start, upload at end + every 5 min |
| Artifact refs | `artifacts/` | Individual files | `rclone copy` (per-file) |
| Source protos | `source_protos/` | Individual files | `rclone copy` (per-file) |

**Key design decisions:**
- **No proxy process** — rclone talks directly to R2's S3-compatible API. BuildStream never knows R2 exists; it just sees a warm local cache.
- **CAS as single archive** — ~20,000 CAS objects are packed into one `cas.tar.zst` file. This replaces ~20,000 individual PUT/GET requests with a single multipart upload/download.
- **Atomic uploads** — CAS is uploaded to a temp name (`cas.tar.zst.uploading.<PID>`) then renamed via `rclone moveto`. This prevents partial uploads from corrupting the cache.
- **Archive validation** — On restore, `zstd -t` validates the archive before extraction. Corrupted archives are deleted from R2 automatically.
- **Background sync** — A background process uploads CAS snapshots every 5 minutes during the build, so partial progress is saved even if the runner is lost or the build times out.
- **PID-based coordination** — The background sync loop's PID is saved to `/tmp/r2-sync-loop.pid`. The final sync step kills this process before starting its own upload, preventing overlap.

### Cache Restore Flow

1. Configure rclone with R2 credentials
2. Check if `cas.tar.zst` exists in R2
3. Download to `/tmp/cas.tar.zst`
4. Validate with `zstd -t` (delete from R2 if corrupted)
5. Extract to `~/.cache/buildstream/cas/`
6. Sync artifact refs from `r2:bst-cache/artifacts/`
7. Sync source protos from `r2:bst-cache/source_protos/`
8. Print CACHE RESTORE REPORT with sizes and status

### Cache Upload Flow (Final Sync)

1. Kill background sync process (PID file)
2. Print last 30 lines of background sync log
3. Create `cas.tar.zst` via `tar | zstd -T0 -9 | rclone rcat` (streaming, no temp file on disk)
4. Atomic rename from temp name to `cas.tar.zst`
5. `rclone sync` artifact refs and source protos
6. Print CACHE UPLOAD REPORT with sizes, compression ratio, and status

### Layer Details

| Layer | Configured in | Read | Write | Contains |
|---|---|---|---|---|
| Local CAS | Automatic (restored from R2) | Always | Always | Everything built/fetched this run |
| R2 cache | rclone (outside BuildStream) | At build start | At build end + every 5 min | Bluefin-specific artifacts + metadata |
| GNOME upstream | `project.conf` `artifacts:` section | Always | Never | freedesktop-sdk + gnome-build-meta artifacts |
| Source cache | `project.conf` `source-caches:` + `actions/cache` | Always | Always (local) | Upstream tarballs, git repos |

## PR vs Main Differences

| Behavior | PR | Main push |
|---|---|---|
| Build runs? | Yes | Yes |
| bootc lint? | Yes | Yes |
| R2 cache read | Yes (if secrets available) | Yes |
| R2 cache write | Yes (if secrets available) | Yes |
| Fork PR gets R2 secrets? | **No** -- GitHub doesn't expose secrets to forks | N/A |
| Push to GHCR? | **No** | Yes |
| Concurrency | Grouped by branch; new pushes cancel stale runs | Grouped by SHA; every push runs |

## Secrets and Permissions

| Secret | Required? | Purpose |
|---|---|---|
| `R2_ACCESS_KEY` | Optional | Cloudflare R2 access key ID |
| `R2_SECRET_KEY` | Optional | Cloudflare R2 secret access key |
| `R2_ENDPOINT` | Optional | R2 S3-compatible endpoint (`https://<ACCOUNT_ID>.r2.cloudflarestorage.com`) |
| `GITHUB_TOKEN` | Auto-provided | GHCR login (main branch push only) |

**All R2 secrets are optional.** If missing, cache restore and sync are skipped and the build proceeds using only GNOME upstream CAS + local CAS. The build works without R2 -- it just takes longer.

Job permissions: `contents: read`, `packages: write`.

## bst2 Container Configuration

The bst2 container runs via `podman run` (NOT as a GitHub Actions `container:`), because the disk-space-reclamation step needs host filesystem access.

| Flag | Why |
|---|---|
| `--privileged` | Required for bubblewrap sandboxing inside BuildStream |
| `--device /dev/fuse` | Required for `buildbox-fuse` (ext4 on GHA lacks reflinks) |
| `-v workspace:/src:rw` | Mount repo into container |
| `-v ~/.cache/buildstream:...:rw` | Persist CAS across steps |
| `ulimit -n 1048576` | `buildbox-casd` needs many file descriptors |
| `--no-interactive` | Prevents blocking on prompts in CI |

Note: `--network=host` is no longer needed since there is no local cache proxy. The bst2 container only needs network access for GNOME upstream CAS, which is accessed directly.

## Debugging CI Failures

### Where to Find Logs

| Log | Location | Contents |
|---|---|---|
| Build log | `buildstream-logs` artifact -> `logs/build.log` | Full BuildStream build output |
| Background sync log | `buildstream-logs` artifact (or step output of "Final sync to R2") | `/tmp/r2-sync-loop.log` — background R2 upload cycles |
| Cache restore report | "Restore BuildStream cache from R2" step output | CACHE RESTORE REPORT — sizes, deltas, status |
| Cache upload report | "Final sync to R2" step output | CACHE UPLOAD REPORT — upload status, compression ratio |
| Workflow log | GitHub Actions UI -> step output | Each step's stdout/stderr |
| Disk usage | "Disk and cache usage after build" step | `df -h /` + cache component breakdown |

### Common Failures

| Symptom | Likely cause | Fix |
|---|---|---|
| Build OOM or hangs | Too many parallel builders | `builders` is already 1; check if element's own build is too memory-heavy |
| "No space left on device" | BuildStream CAS fills disk | Verify disk reclamation step ran; check `cache-buildtrees: never` is set |
| `bootc container lint` fails | Image has `/usr/etc`, missing ostree refs, or invalid metadata | Check `oci/bluefin.bst` assembly script; ensure `/usr/etc` merge runs |
| Build succeeds locally, fails in CI | Different element versions cached, or network-dependent sources | Compare `bst show` output locally vs CI; check if GNOME CAS has stale artifacts |
| GHCR push fails | Token permissions or rate limiting | Check `packages: write` permission; `--retry 3` handles transient failures |
| Source fetch timeout | GNOME CAS or upstream source unreachable | `network-retries: 3` handles transient issues; check GNOME infra status |
| Cache restore succeeds but build is cold | Artifact refs may be missing while CAS objects are present | Check CACHE RESTORE REPORT output; look at artifact refs size — if 0 MB, refs weren't synced |
| CAS archive validation fails | Corrupted archive in R2 (partial upload, storage error) | Automatic: corrupted archives are deleted from R2; next build uploads a fresh one |
| Background and final sync overlap | PID-based kill didn't work | Check "Final sync to R2" step — it should log "Stopping background R2 sync"; if not, the PID file was missing |
| rclone download exits 0 but cache is empty | Archive existed but was zero-size or extraction failed | Check CACHE RESTORE REPORT — `CAS_RESTORED` flag and post-restore CAS size in MB |

### Debugging Workflow

1. **Check the CACHE RESTORE REPORT**: In the "Restore BuildStream cache from R2" step output, look for the boxed report. It shows cache sizes before/after restore and whether CAS was successfully validated and extracted. A "COLD BUILD" status means the build ran without any cached CAS objects.

2. **Check the CACHE UPLOAD REPORT**: In the "Final sync to R2" step output, look for the boxed report. It shows whether CAS, artifact refs, and source protos were uploaded successfully, along with compression ratios and timing.

3. **Check background sync log**: In the "Final sync to R2" step, the last 30 lines of `/tmp/r2-sync-loop.log` are printed. Look for upload failures or "CAS too small" messages (normal on cold builds).

4. **Check disk space**: Look at the "Disk and cache usage after build" step — it shows both `df -h /` and a breakdown of each cache component's size.

5. **Search build log**: Download `buildstream-logs` artifact and look for `[FAILURE]` lines in `logs/build.log`. `on-error: continue` means all failures are collected in one run.

6. **Reproduce locally**: `just bst build oci/bluefin.bst` uses the same bst2 container. See `local-e2e-testing` skill for full local workflow.

## Cross-References

| Skill | When |
|---|---|
| `local-e2e-testing` | Reproducing CI issues locally |
| `oci-layer-composition` | Understanding what the build produces |
| `debugging-bst-build-failures` | Diagnosing individual element build failures |
| `buildstream-element-reference` | Writing or modifying `.bst` elements |
