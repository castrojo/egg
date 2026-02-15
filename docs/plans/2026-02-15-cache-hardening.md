# R2 Cache Hardening Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Eliminate all silent cache failures in the CI pipeline so that R2 cache restore/upload works reliably on every run, preventing unnecessary 2-hour cold builds.

**Architecture:** Harden the existing rclone-based cache approach in `.github/workflows/build-egg.yml`. Fix the critical download bug that silently downloads 0 bytes, remove destructive error handling that deletes valid R2 data, add coordination between background and final sync, and replace dangerous `rclone sync` with additive `rclone copy`.

**Tech Stack:** GitHub Actions, rclone, Cloudflare R2 (S3-compatible), zstd, BuildStream 2

---

## Background

### Root Cause

In CI run 22039406010, `rclone copy "r2:${R2_BUCKET}/cas.tar.zst" /tmp/` downloaded **0 bytes** but exited code 0. The subsequent `zstd -t /tmp/cas.tar.zst` failed with "No such file or directory", which the code misinterpreted as a corrupted archive and **deleted the valid 9.1 GB archive from R2**. This creates a self-reinforcing cache destruction cycle.

**Why the download failed:**
1. `rclone copy` copies to a **directory** — `/tmp/` on GHA runners contains special files (dotnet diagnostic pipes, sockets) that confuse rclone's directory listing
2. `--s3-no-head-object` skips the HEAD request needed to determine the file should be downloaded
3. rclone reports "Transferred: 0 B" but returns exit code 0
4. No file-exists check between download and validation

### All 9 Issues

| # | Issue | Severity | Fix |
|---|---|---|---|
| 1 | `rclone copy` downloads 0 bytes, code deletes valid R2 archive | **Critical** | Use `rclone copyto`, dedicated temp dir, drop `--s3-no-head-object` on download |
| 2 | `rclone lsf` returns exit 0 even when file doesn't exist | Medium | Use `rclone size --json` with jq check instead |
| 3 | Background sync has no coordination with final sync | Medium | Add lock file mechanism |
| 4 | `rclone sync` for artifacts/source_protos deletes valid R2 data | Medium | Replace with `rclone copy` (additive only) |
| 5 | No file-exists check after download before validation | High | Add explicit `[ -f "$TEMP_CAS" ]` check |
| 6 | rclone installed via `curl | bash` every run | Low | Use GitHub release binary with checksum verification |
| 7 | Stale bazel-remote renovate regex config | Low | Remove dead regex manager block |
| 8 | No post-restore health check before 2-hour build | Medium | Add quick BuildStream artifact list check |
| 9 | Self-hosted runner doesn't persist cache | Info | No code change — architecture assumption documented |

### Key Principles

- **Never delete from R2 on restore failure** — just warn and proceed with cold build
- **Additive-only uploads** — `rclone copy`, never `rclone sync`
- **Explicit file-exists checks** — never assume a command succeeded based on exit code alone
- **Atomic uploads** — temp file + rename (already implemented, keep it)
- **Lock coordination** — background and final sync must not run simultaneously
- **Process group kill** — killing the shell is not enough; child pipelines must be killed too
- **Orphaned temp cleanup** — final sync must clean stale `cas.tar.zst.uploading.*` from R2

### Verification Corrections (2026-02-15)

The following issues were discovered by subagent verification of the original plan:

1. **Orphaned pipeline children (Task 3 gap):** `kill "$PID"` only kills the bash shell, NOT the `tar | zstd | rclone` child pipeline. With `nohup`, these children survive and can complete their upload + `rclone moveto`, potentially **overwriting the final sync's definitive archive** with a stale zstd-3 version. Fix: use process group kill or signal trapping.

2. **Orphaned R2 temp files (Task 3 gap):** If background sync is killed mid-upload, `cas.tar.zst.uploading.<bg-pid>` is never cleaned up on R2. Final sync doesn't know the background's PID, so it can't clean it either. Fix: final sync should clean up any stale `cas.tar.zst.uploading.*` files before starting its own upload.

3. **`unzip` availability (Task 5 gap):** The runner is self-hosted (label `Testing`, NOT `ubuntu-24.04`). `unzip` may not be pre-installed. The current `curl | bash` install script calls `unzip` internally, so it's probably available — but this is fragile. Fix: install `unzip` explicitly before use, or note the dependency.

4. **Renovate regex too loose (Task 5 minor):** The proposed `\n\s+.*RCLONE_SHA256` uses `.*` which is greedy across newlines in Renovate's dotAll mode. Fix: use `\n\s+#[^\n]*\n\s+RCLONE_SHA256` to match the intervening comment line precisely, or drop `.*` entirely if env vars are adjacent.

---

## Task 1: Fix Critical Download Bug and Remove Destructive Error Handling

**Files:**
- Modify: `.github/workflows/build-egg.yml:67-185` (Restore BuildStream cache from R2 step)

This is the highest-priority fix. It addresses issues #1, #2, and #5 (the critical download bug, the `rclone lsf` false positive, and the missing file-exists check).

**Step 1: Replace the CAS existence check**

Replace the `rclone lsf` check (line 105) with `rclone size --json` which returns actual file metadata:

```bash
# OLD (broken: rclone lsf returns exit 0 even if file doesn't exist)
if rclone lsf "r2:${R2_BUCKET}/cas.tar.zst" 2>&1; then

# NEW (reliable: check actual byte count from JSON response)
CAS_REMOTE_SIZE=$(rclone size --json "r2:${R2_BUCKET}/cas.tar.zst" 2>/dev/null | jq -r '.bytes // 0')
if [ "${CAS_REMOTE_SIZE:-0}" -gt 0 ]; then
```

**Step 2: Fix the download command**

Replace `rclone copy` (dir-to-dir) with `rclone copyto` (file-to-file), use a dedicated temp directory instead of `/tmp/`, and drop `--s3-no-head-object`:

```bash
# OLD (broken: copies to directory, /tmp/ has junk files, no-head-object skips needed check)
TEMP_CAS="/tmp/cas.tar.zst"
echo "Downloading cas.tar.zst..."
if rclone copy "r2:${R2_BUCKET}/cas.tar.zst" /tmp/ --s3-no-head-object --progress 2>&1; then

# NEW (reliable: file-to-file copy, clean directory, HEAD request enabled)
TEMP_DIR=$(mktemp -d /tmp/r2-restore.XXXXXX)
TEMP_CAS="${TEMP_DIR}/cas.tar.zst"
echo "Downloading cas.tar.zst (${CAS_REMOTE_SIZE} bytes = $((CAS_REMOTE_SIZE / 1048576)) MB)..."
if rclone copyto "r2:${R2_BUCKET}/cas.tar.zst" "${TEMP_CAS}" --progress 2>&1; then
```

**Step 3: Add explicit file-exists check after download**

Insert between the download and validation:

```bash
  if rclone copyto "r2:${R2_BUCKET}/cas.tar.zst" "${TEMP_CAS}" --progress 2>&1; then
    # Verify the file actually landed on disk (rclone can exit 0 with 0 bytes)
    ACTUAL_SIZE=$(stat --format=%s "${TEMP_CAS}" 2>/dev/null || echo 0)
    if [ ! -f "${TEMP_CAS}" ]; then
      echo "::warning::rclone reported success but no file was written"
    elif [ "$ACTUAL_SIZE" -lt 1000 ]; then
      echo "::warning::Downloaded file is suspiciously small (${ACTUAL_SIZE} bytes vs expected ${CAS_REMOTE_SIZE})"
    else
      echo "Downloaded ${ACTUAL_SIZE} bytes (expected ${CAS_REMOTE_SIZE})"
      echo "Validating archive integrity..."
      # ... validation continues ...
    fi
  fi
```

**Step 4: Remove the destructive R2 deletion on validation failure**

```bash
# OLD (destructive: deletes valid R2 data when local download is corrupt)
else
  echo "::warning::CAS archive validation failed (corrupted zstd)"
  echo "Deleting corrupted cache file from R2..."
  rclone delete "r2:${R2_BUCKET}/cas.tar.zst" 2>&1 || true
fi

# NEW (safe: warn and move on, never delete from R2 on restore path)
else
  echo "::warning::CAS archive validation failed — skipping (will not delete from R2)"
  echo "::warning::Archive may need investigation; next successful build will overwrite it"
fi
```

**Step 5: Also remove `--s3-no-head-object` and `--s3-no-system-metadata` from artifact/proto restore**

These flags are unnecessary for the restore path and can mask issues:

```bash
# OLD
rclone copy "r2:${R2_BUCKET}/artifacts/" "${BST_CACHE}/artifacts/" \
  --size-only --transfers=16 --fast-list \
  --s3-no-head-object --s3-no-system-metadata \
  -v || echo "::warning::Artifact refs restore failed (non-fatal)"

# NEW
rclone copy "r2:${R2_BUCKET}/artifacts/" "${BST_CACHE}/artifacts/" \
  --size-only --transfers=16 --fast-list \
  -v || echo "::warning::Artifact refs restore failed (non-fatal)"
```

Same for `source_protos/`.

**Step 6: Clean up temp directory in all exit paths**

```bash
# Replace: rm -f "$TEMP_CAS"
# With:    rm -rf "${TEMP_DIR}"
```

**Step 7: Write the complete replacement**

Apply all changes above to produce the complete replacement for the "Restore BuildStream cache from R2" step's `run:` block (lines 72-185). The full replacement should incorporate all fixes from steps 1-6.

**Step 8: Verify by reading the modified file**

After making the edit, read back lines 67-185 and verify:
- No `rclone delete` on the restore path
- `rclone copyto` instead of `rclone copy` for CAS download
- No `--s3-no-head-object` on download
- `mktemp -d` instead of bare `/tmp/`
- File-exists check between download and validation
- No `--s3-no-head-object` or `--s3-no-system-metadata` on artifact/proto restore

**Step 9: Commit**

```bash
git add .github/workflows/build-egg.yml
git commit -m "fix: prevent silent 0-byte cache downloads and destructive R2 deletes

Root cause: rclone copy to /tmp/ downloaded 0 bytes (exit 0) due to
directory listing confusion, then validation failure triggered deletion
of the valid 9.1 GB R2 archive, creating a self-reinforcing cache
destruction cycle.

Fixes:
- Use rclone copyto (file-to-file) instead of rclone copy (dir-to-dir)
- Download to dedicated temp directory, not /tmp/
- Drop --s3-no-head-object on download path
- Add explicit file-exists and size checks after download
- NEVER delete from R2 on restore failure
- Use rclone size --json instead of rclone lsf for existence check"
```

---

## Task 2: Replace `rclone sync` with `rclone copy` in Final Upload

**Files:**
- Modify: `.github/workflows/build-egg.yml:410-444` (artifact refs and source protos upload sections in "Final sync to R2" step)

This addresses issue #4. `rclone sync` deletes files in the destination that don't exist locally. If the local cache is partial (e.g., build failed partway), this deletes valid data from R2.

**Step 1: Replace `rclone sync` with `rclone copy` for artifact refs (line 414)**

```bash
# OLD (destructive: sync deletes R2 files not present locally)
if rclone sync "${BST_CACHE}/artifacts/" "r2:${R2_BUCKET}/artifacts/" \

# NEW (additive: copy only adds/updates, never deletes)
if rclone copy "${BST_CACHE}/artifacts/" "r2:${R2_BUCKET}/artifacts/" \
```

**Step 2: Replace `rclone sync` with `rclone copy` for source protos (line 432)**

```bash
# OLD
if rclone sync "${BST_CACHE}/source_protos/" "r2:${R2_BUCKET}/source_protos/" \

# NEW
if rclone copy "${BST_CACHE}/source_protos/" "r2:${R2_BUCKET}/source_protos/" \
```

**Step 3: Verify by reading the modified lines**

Confirm both `rclone sync` calls are now `rclone copy`. The other flags (`--size-only`, `--transfers`, etc.) remain unchanged.

**Step 4: Commit**

```bash
git add .github/workflows/build-egg.yml
git commit -m "fix: use rclone copy instead of sync for metadata uploads

rclone sync deletes destination files not present locally. If the local
cache is partial (build failed partway), this destroys valid R2 data.
rclone copy is additive-only: it adds and updates but never deletes."
```

---

## Task 3: Add Lock File Coordination Between Background and Final Sync

**Files:**
- Modify: `.github/workflows/build-egg.yml:244-298` (background sync loop SYNCSCRIPT heredoc)
- Modify: `.github/workflows/build-egg.yml:335-503` (Final sync to R2 step)

This addresses issue #3. The background sync loop and final sync can run simultaneously, creating write conflicts on R2 (two concurrent multipart uploads to the same key, orphaned temp files).

**Step 1: Add lock checking to the background sync loop**

In the `SYNCSCRIPT` heredoc (starts at line 244), modify the while loop body to check for a lock file before uploading and create a sentinel file during upload:

```bash
    # Check lock — final sync may have started
    LOCK_FILE="/tmp/r2-sync.lock"
    if [ -f "$LOCK_FILE" ]; then
      echo "[r2-sync] Lock held by final sync, skipping this cycle"
      continue
    fi
    touch "${LOCK_FILE}.bg"
    # ... upload logic ...
    rm -f "${LOCK_FILE}.bg"
```

**Step 2: Also remove `--s3-no-head` from background sync metadata uploads**

In the background sync loop, the metadata `rclone copy` calls at lines 291-294 use `--s3-no-head`. Remove this flag:

```bash
# OLD
rclone copy "${BST_CACHE}/artifacts/" "r2:${R2_BUCKET}/artifacts/" \
  --no-traverse --size-only --transfers=8 --s3-no-head -q 2>&1 || true

# NEW
rclone copy "${BST_CACHE}/artifacts/" "r2:${R2_BUCKET}/artifacts/" \
  --no-traverse --size-only --transfers=8 -q 2>&1 || true
```

Same for `source_protos/`.

**Step 3: Add lock acquisition to the final sync step**

In the "Final sync to R2" step, after stopping the background sync process (lines 343-352), add lock acquisition and wait for any in-progress background upload:

```bash
          # Acquire sync lock (prevent background sync from starting new uploads)
          LOCK_FILE="/tmp/r2-sync.lock"
          touch "$LOCK_FILE"

          # Wait for any in-progress background upload to finish (max 60s)
          echo "Waiting for background sync to release..."
          for i in $(seq 1 60); do
            [ ! -f "${LOCK_FILE}.bg" ] && break
            sleep 1
          done
          if [ -f "${LOCK_FILE}.bg" ]; then
            echo "::warning::Background sync did not release lock after 60s, proceeding anyway"
            rm -f "${LOCK_FILE}.bg"
          fi
```

Insert this block after the background sync stop logic (after line 352), before the `if [ -z "${R2_ACCESS_KEY}" ]` check.

**Step 4: Remove `--s3-no-head` and `--s3-no-system-metadata` from final sync metadata uploads**

In the final sync step, the metadata upload calls at lines 414-421 and 432-439 have `--s3-no-head` and `--s3-no-system-metadata`. Remove both flags:

```bash
# OLD
if rclone copy "${BST_CACHE}/artifacts/" "r2:${R2_BUCKET}/artifacts/" \
  --size-only \
  --transfers=16 \
  --checkers=8 \
  --fast-list \
  --s3-no-head \
  --s3-no-system-metadata \
  -v; then

# NEW
if rclone copy "${BST_CACHE}/artifacts/" "r2:${R2_BUCKET}/artifacts/" \
  --size-only \
  --transfers=16 \
  --checkers=8 \
  --fast-list \
  -v; then
```

Same pattern for `source_protos/`.

**Step 5: Verify by reading the modified file**

Check:
- Background loop checks for lock file at start of each cycle
- Background loop creates `.bg` sentinel during its upload and removes it after
- Final sync kills background process, then acquires lock, then waits for `.bg` sentinel
- No `--s3-no-head` or `--s3-no-system-metadata` flags remain anywhere in the file

**Step 6: Commit**

```bash
git add .github/workflows/build-egg.yml
git commit -m "fix: add lock coordination between background and final R2 sync

Without coordination, background sync and final sync can run
simultaneously, creating concurrent multipart uploads to the same R2
key and orphaned temp files. Lock file mechanism prevents overlap:
- Final sync acquires lock, waits for in-progress background upload
- Background sync checks lock, skips cycle if final sync is running

Also removes --s3-no-head and --s3-no-system-metadata flags which are
unnecessary and can mask issues."
```

---

## Task 4: Add Post-Restore Health Check

**Files:**
- Modify: `.github/workflows/build-egg.yml` (insert new step after "Restore BuildStream cache from R2", before "Generate BuildStream CI config")

This addresses issue #8. After restoring the cache, verify BuildStream can actually use it before committing to a 2-hour build. This is a quick filesystem check, not a full BuildStream invocation.

**Step 1: Add a new step between cache restore and BST config generation**

Insert after line 185 (end of "Restore BuildStream cache from R2") and before line 201 (start of "Generate BuildStream CI config"):

```yaml
      - name: Post-restore cache health check
        run: |
          BST_CACHE="$HOME/.cache/buildstream"
          echo "=== Post-restore cache health check ==="

          # Check CAS directory has content
          CAS_OBJECTS=$(find "${BST_CACHE}/cas" -type f 2>/dev/null | head -100 | wc -l)
          ARTIFACT_REFS=$(find "${BST_CACHE}/artifacts" -type f 2>/dev/null | wc -l)

          echo "CAS objects (sampled): ${CAS_OBJECTS}+"
          echo "Artifact refs: ${ARTIFACT_REFS}"
          echo "CAS size: $(du -sh "${BST_CACHE}/cas" 2>/dev/null | cut -f1 || echo 'empty')"

          if [ "$CAS_OBJECTS" -gt 0 ] && [ "$ARTIFACT_REFS" -gt 0 ]; then
            echo "Health check: PASSED (cache looks populated)"
          elif [ "$CAS_OBJECTS" -gt 0 ]; then
            echo "Health check: PARTIAL (CAS objects present but no artifact refs)"
            echo "::warning::Cache has CAS objects but no artifact refs — BuildStream may not recognize cached artifacts"
          else
            echo "Health check: COLD (no cached objects, full build expected)"
            echo "Expected build time: ~120 minutes"
          fi
```

**Step 2: Verify step ordering by reading the file**

Confirm the new step appears between cache restore and BST config generation.

**Step 3: Commit**

```bash
git add .github/workflows/build-egg.yml
git commit -m "feat: add post-restore cache health check

Quick validation after R2 cache restore to detect cold builds early.
Reports CAS object count, artifact ref count, and overall health
status before committing to the 2-hour build."
```

---

## Task 5: Harden rclone Installation

**Files:**
- Modify: `.github/workflows/build-egg.yml:56-59` (Install rclone step)
- Modify: `.github/renovate.json5` (add rclone version tracking)

This addresses issue #6. The current `curl | bash` installation is fragile and un-auditable.

**Step 1: Look up the current stable rclone version and checksum**

Run:
```bash
curl -fsSL "https://github.com/rclone/rclone/releases/latest" 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' | head -1
```

Then get the checksum:
```bash
curl -fsSL "https://github.com/rclone/rclone/releases/download/v${VERSION}/SHA256SUMS" | grep linux-amd64.zip
```

**Important:** The implementer MUST look up the actual SHA256 checksum. Do NOT use a placeholder.

**Step 2: Replace the Install rclone step**

Replace lines 56-59 with:

```yaml
      - name: Install rclone
        env:
          RCLONE_VERSION: "<actual-version>"
          # SHA256 of rclone-v<version>-linux-amd64.zip from GitHub releases
          RCLONE_SHA256: "<actual-checksum>"
        run: |
          RCLONE_URL="https://github.com/rclone/rclone/releases/download/v${RCLONE_VERSION}/rclone-v${RCLONE_VERSION}-linux-amd64.zip"
          echo "Downloading rclone v${RCLONE_VERSION}..."
          curl -fsSL "$RCLONE_URL" -o /tmp/rclone.zip

          echo "Verifying checksum..."
          echo "${RCLONE_SHA256}  /tmp/rclone.zip" | sha256sum -c -

          unzip -j /tmp/rclone.zip "rclone-v${RCLONE_VERSION}-linux-amd64/rclone" -d /tmp/
          sudo install -m 755 /tmp/rclone /usr/local/bin/rclone
          rm -f /tmp/rclone.zip /tmp/rclone

          rclone version
```

**Step 3: Add a Renovate regex manager for rclone**

Add to the `customManagers` array in `.github/renovate.json5`:

```json5
    // ── rclone binary download in CI workflow ──
    // Matches the version and SHA256 as env vars in the Install rclone step
    {
      "customType": "regex",
      "managerFilePatterns": [
        "/\\.github/workflows/build-egg\\.yml$/"
      ],
      "matchStrings": [
        "RCLONE_VERSION:\\s*\"(?<currentValue>\\d+\\.\\d+\\.\\d+)\"\\n\\s+.*RCLONE_SHA256:\\s*\"(?<currentDigest>[a-f0-9]{64})\""
      ],
      "depNameTemplate": "rclone/rclone",
      "datasourceTemplate": "github-releases",
      "extractVersionTemplate": "^v(?<version>.+)$"
    },
```

Also add `"rclone/rclone"` to the auto-merge patch rule's `matchDepNames` array.

**Step 4: Verify by reading both modified files**

Confirm:
- rclone version and checksum are in env vars (not hardcoded in URL)
- Binary is downloaded from GitHub releases, not rclone.org
- Checksum is verified before installation
- Renovate config has matching regex that will track version bumps

**Step 5: Commit**

```bash
git add .github/workflows/build-egg.yml .github/renovate.json5
git commit -m "fix: install rclone from GitHub releases with checksum verification

Replaces fragile 'curl | bash' installation with direct binary download
from GitHub releases, verified by SHA256 checksum. Adds Renovate
tracking so version bumps are automated."
```

---

## Task 6: Clean Up Stale Renovate Config

**Files:**
- Modify: `.github/renovate.json5:28-40` (bazel-remote regex manager)
- Modify: `.github/renovate.json5:84-85` (bazel-remote in auto-merge rule)

This addresses issue #7. The bazel-remote regex manager matches a download pattern that no longer exists in the workflow (we migrated from bazel-remote to rclone).

**Step 1: Remove the stale bazel-remote regex manager**

Delete the entire block at lines 28-40:

```json5
    // ── bazel-remote binary download in CI workflow ──
    // Matches the download URL and SHA256 checksum as a pair
    {
      "customType": "regex",
      "managerFilePatterns": [
        "/\\.github/workflows/build-egg\\.yml$/"
      ],
      "matchStrings": [
        "https://github\\.com/(?<depName>buchgr/bazel-remote)/releases/download/v(?<currentValue>\\d+\\.\\d+\\.\\d+)/bazel-remote-[\\d.]+-linux-amd64\"\\n\\s+echo \"(?<currentDigest>[a-f0-9]{64})"
      ],
      "datasourceTemplate": "github-releases",
      "extractVersionTemplate": "^v(?<version>.+)$"
    },
```

**Step 2: Remove `buchgr/bazel-remote` from the auto-merge package rule**

In the `packageRules` section (around line 85), remove `"buchgr/bazel-remote"` from the `matchDepNames` array.

**Step 3: Verify no other references to bazel-remote remain**

Search both `.github/workflows/build-egg.yml` and `.github/renovate.json5` for "bazel-remote" and confirm all references are gone.

**Step 4: Commit**

```bash
git add .github/renovate.json5
git commit -m "chore: remove stale bazel-remote renovate config

The workflow migrated from bazel-remote to rclone for R2 cache access.
The regex manager and auto-merge rule for bazel-remote are dead code."
```

---

## Task 7: Update CI Pipeline Operations Skill

**Files:**
- Modify: `.opencode/skills/ci-pipeline-operations/SKILL.md`

The ci-pipeline-operations skill still references bazel-remote as the cache proxy and documents the old architecture. Update it to reflect the rclone-based approach.

**Step 1: Update the Quick Reference table**

Remove bazel-remote entries (gRPC port, HTTP port, etc.). Add:

| What | Value |
|---|---|
| Cache strategy | rclone direct to Cloudflare R2 (no proxy) |
| CAS archive format | `cas.tar.zst` (single zstd-compressed tar) |
| Metadata sync | `artifacts/` and `source_protos/` (per-file rclone copy) |
| Background sync interval | Every 5 minutes during build |
| Lock file | `/tmp/r2-sync.lock` (coordinates bg/final sync) |

**Step 2: Update the Caching Architecture section**

Replace the three-layer + bazel-remote description with:
- CAS stored as single tar+zstd archive on R2
- Restored at build start, uploaded at build end + every 5 min background
- Artifact refs and source protos synced as individual files
- No proxy process — rclone talks directly to R2's S3 API
- Lock file coordination between background and final sync

Remove the "bazel-remote Bridge" subsection entirely.

**Step 3: Remove the `type: storage` trap warning**

This was specific to bazel-remote's CAS protocol. No longer relevant since we don't configure BuildStream to talk to a remote CAS server — the cache is restored as local files.

**Step 4: Update Workflow Steps table**

Update steps that changed:
- Step 5 is now "Install rclone" (pinned version, checksum verified)
- Replace cache proxy steps with: "Restore BuildStream cache from R2", "Post-restore cache health check", "Start background R2 sync", "Final sync to R2"
- Remove "Start cache proxy", "Cache proxy stats", "Stop cache proxy"

**Step 5: Update the Common Failures table**

Remove bazel-remote-specific failures. Add:
- "rclone download exits 0 but file empty" → Hardened: file-exists check catches this
- "Background and final sync overlap" → Lock file mechanism prevents this
- "Cache restore succeeds but build is cold" → Check post-restore health check output; artifact refs may be missing

**Step 6: Update Debugging Workflow section**

Remove references to `bazel-remote-logs` artifact. Add:
- Check "CACHE RESTORE REPORT" in the restore step output
- Check `/tmp/r2-sync-loop.log` (uploaded as part of build logs) for background sync issues
- Check "CACHE UPLOAD REPORT" in final sync step for upload status

**Step 7: Commit**

```bash
git add .opencode/skills/ci-pipeline-operations/SKILL.md
git commit -m "docs: update ci-pipeline-operations skill for rclone-based cache

Replaces bazel-remote references with rclone direct-to-R2 architecture.
Updates caching section, workflow steps, common failures, and debugging
workflow to reflect current implementation."
```

---

## Verification

After all tasks are complete, verify the entire workflow is consistent:

1. **Read the full workflow file** and check:
   - No `rclone delete` on the restore path
   - No `rclone sync` anywhere (all replaced with `rclone copy`)
   - No `--s3-no-head-object` on download paths
   - No `--s3-no-head` or `--s3-no-system-metadata` anywhere
   - Lock file coordination present in both background and final sync
   - `rclone copyto` for CAS download (not `rclone copy`)
   - Checksum-verified rclone installation
   - Post-restore health check step present

2. **Read renovate.json5** and check:
   - No bazel-remote references
   - rclone version tracking present
   - Valid JSON5 syntax

3. **Read the ci-pipeline-operations skill** and check:
   - No bazel-remote references
   - Accurate description of rclone-based cache

4. **YAML syntax check**:
   ```bash
   python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-egg.yml'))"
   ```

5. **Push and monitor**: After committing, push to a branch and create a PR. The PR build should:
   - Install rclone from GitHub releases (not curl|bash)
   - Attempt cache restore with all hardening in place
   - Run the post-restore health check
   - Complete the build
   - Upload cache with `rclone copy` (not sync)

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `rclone copyto` behaves differently than expected | Low | Medium | Well-documented in rclone docs; `copyto` is the standard file-to-file command |
| Lock file race (bg writes lock between check and final sync) | Very Low | Low | Final sync kills bg process first, then acquires lock, then waits for sentinel |
| rclone GitHub release URL changes format | Low | Low | Renovate tracks the version; release format has been stable for years |
| `rclone size --json` returns unexpected format | Low | Medium | `jq -r '.bytes // 0'` defaults to 0 on parse failure, triggering "no archive found" |
| Removing `--s3-no-head-object` slows downloads | Very Low | Very Low | HEAD requests add ~50ms per file; CAS download is a single file |

---

## Summary of All File Changes

| File | Changes | Tasks |
|---|---|---|
| `.github/workflows/build-egg.yml` | Fix download bug, remove destructive deletes, replace sync with copy, add lock coordination, add health check, harden rclone install | 1, 2, 3, 4, 5 |
| `.github/renovate.json5` | Add rclone tracking, remove stale bazel-remote config | 5, 6 |
| `.opencode/skills/ci-pipeline-operations/SKILL.md` | Update to reflect rclone-based architecture | 7 |

Total: **3 files modified**, **7 commits**.
