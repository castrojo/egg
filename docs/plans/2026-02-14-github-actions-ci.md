# GitHub Actions CI for bluefin-egg Implementation Plan

> **Status: SUPERSEDED** -- The workflow exists at `.github/workflows/build-egg.yml` and has evolved significantly beyond this plan. The current implementation uses Blacksmith sticky disks for artifact caching (see `2026-02-15-blacksmith-sticky-disk-migration.md`) instead of `actions/cache`. The runner is `blacksmith-4vcpu-ubuntu-2404` (not `ubuntu-24.04`). R2 cache infrastructure was added then removed. Daily source tracking exists in a separate workflow. Retained for historical reference showing the initial CI architecture.

> **For agents:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the bluefin-egg GNOME OS OCI image in GitHub Actions CI using BuildStream, validate it with `bootc container lint`, and publish it to GHCR.

**Architecture:** Run the BuildStream build inside GNOME's official `bst2` container image (via explicit `podman run` on `ubuntu-24.04` runners). The `bst2` image has BuildStream 2.6.0, BuildBox 1.3.52, bubblewrap, and all required tooling pre-installed. A CI-specific `buildstream.conf` is generated at runtime with GNOME-recommended scheduler tuning (32 fetchers, on-error continue, retry-failed). The build leverages GNOME's upstream artifact cache at `gbm.gnome.org:11003` for pre-built components, caches only BuildStream sources locally to stay within GitHub's 10GB cache limit, and uses `ublue-os/remove-unwanted-software` to free disk space. Podman is used throughout -- no Docker daemon dependency.

**Tech Stack:** GitHub Actions, BuildStream 2.6, BuildBox 1.3.52, Podman, GHCR (ghcr.io), bootc

---

## Context & Discoveries

### Repository structure

- `project.conf` -- BuildStream config, min-version 2.5, artifact cache at `https://gbm.gnome.org:11003`, source cache at same URL
- `Justfile` -- Local dev targets: `build` (bst build + podman load), `build-containerfile`, `bootc`, `generate-bootable-image`
- `Containerfile` -- Validation only: `FROM ghcr.io/projectbluefin/egg:latest` + `bootc container lint`
- `elements/oci/bluefin.bst` -- Final OCI image element (the build target)
- Build output is already a complete OCI image tar (built by `oci-builder` from freedesktop-sdk inside the BST pipeline)
- Existing workflow: `bst artifact checkout --tar - oci/bluefin.bst | podman load`
- No `.gitmodules` file -- no git submodules in use

### GNOME's bst2 container image

```
Image: registry.gitlab.com/freedesktop-sdk/infrastructure/freedesktop-sdk-docker-images/bst2
Tag:   f89b4aef847ef040b345acceda15a850219eb8f1  (pinned SHA, same as gnome-build-meta CI)

Pre-installed:
  - BuildStream 2.6.0
  - BuildBox 1.3.52 (casd, fuse, run-bubblewrap, run-hosttools, worker, recc, trexe)
  - Bubblewrap 0.11.0
  - Podman, Flatpak, ostree
  - Git, Git-LFS, Cargo
  - Python 3 + full BST plugin deps

Runtime requirements:
  - /dev/fuse access (required: GHA runners use ext4 which lacks reflink support,
    so buildbox-fuse cannot be disabled like GNOME does on btrfs/XFS runners)
  - ulimit -n 1048576 (buildbox-casd needs many FDs)
  - --privileged (for bubblewrap sandboxing)
```

### Key decisions

1. **Use GNOME's bst2 container image** via `podman run` (not Homebrew, not pip+static-binaries, no Docker daemon)
2. **Use `ublue-os/remove-unwanted-software`** (SHA `695eb75bc387dbcd9685a8e72d23439d8686cba6`, v10) to free disk space
3. **BST tar output approach** -- `bst artifact checkout --tar - oci/bluefin.bst | podman load` -- no Containerfile needed for building
4. **Include `bootc container lint`** validation step
5. **Do NOT push to GHCR on pull requests** -- only on push to main
6. **Cache only BuildStream sources** to stay within 10GB GitHub cache limit
7. **Generate CI-specific buildstream.conf** with GNOME-recommended scheduler tuning
8. **`on-error: continue`** -- find all failures, don't stop at first
9. **Upload build logs as artifacts** -- survive even on failed builds
10. **Always build on PRs** -- no path filtering, catch all breakage

### Techniques adopted from GNOME upstream CI

These patterns come from `gnome-build-meta/.gitlab-ci.yml` and its CI scripts:

| Technique | GNOME's approach | Our adaptation |
|-----------|-----------------|----------------|
| CI-specific buildstream.conf | Generated at runtime by `generate-buildtream-conf.sh` | Generate inline in workflow step |
| Scheduler tuning | `fetchers: 32`, `builders: nproc/4`, `on-error: continue` | Same values (GHA has 4 vCPUs -> 1 builder) |
| Build retry | `retry-failed: True` in scheduler config | Same |
| Error context | `error-lines: 80` | Same |
| Log collection | `--log-file` + artifacts `when: always` | `--log-file` + `if: always()` upload |
| Non-interactive | `--no-interactive` (implicit via config) | Explicit `--no-interactive` flag |
| Build trees | Not cached (implicit) | Explicit `cache-buildtrees: never` to save disk |
| OCI export | `bst artifact checkout --tar - \| podman load` | Identical |
| Registry push | `podman push --retry 3` | Same |
| Image pinning | SHA-pinned bst2 image | Same SHA |

### Upstream artifact cache risks

The build depends on `gbm.gnome.org:11003` for pre-built artifacts from `freedesktop-sdk` and `gnome-build-meta`. If this cache is:
- **Slow:** Build times increase dramatically (hours instead of minutes for components like WebKitGTK)
- **Unavailable:** Build will attempt to build everything from source, likely exceeding runner time limits (6h max on free tier)
- **Mitigation:** connection-config in `project.conf` has `request-timeout: 180`, `retry-limit: 5`, `retry-delay: 500`; CI config adds `retry-failed: True`

---

## Task 1: Create the complete workflow file

All steps are implemented in a single file. The workflow is written as one coherent unit since the tasks are interdependent.

**Files:**
- Create: `.github/workflows/build-egg.yml`

**Step 1: Create the directory structure**

```bash
mkdir -p .github/workflows
```

**Step 2: Write the complete workflow**

Create `.github/workflows/build-egg.yml` with the content from the "Complete workflow reference" section below.

**Step 3: Verify YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-egg.yml'))"
```

If python3-yaml is not available:
```bash
python3 -c "
import json, sys
# Basic structure check -- full validation happens on push
data = open('.github/workflows/build-egg.yml').read()
print(f'File size: {len(data)} bytes')
print('YAML file exists and is readable')
"
```

**Step 4: Commit**

```bash
git add .github/workflows/build-egg.yml
git commit -m "ci: add GitHub Actions workflow to build bluefin egg OCI image

Build bluefin-egg using BuildStream inside GNOME's bst2 container on
ubuntu-24.04 runners. Uses GNOME upstream artifact cache, validates with
bootc container lint, and publishes to GHCR on push to main.

Scheduler tuned per gnome-build-meta CI: 32 fetchers, on-error continue,
retry-failed, error-lines 80, cache-buildtrees never."
```

---

## Complete workflow reference

```yaml
name: Build Bluefin Egg

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

env:
  IMAGE_NAME: egg
  IMAGE_REGISTRY: ghcr.io/${{ github.repository_owner }}
  BST2_IMAGE: registry.gitlab.com/freedesktop-sdk/infrastructure/freedesktop-sdk-docker-images/bst2:f89b4aef847ef040b345acceda15a850219eb8f1

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      packages: write
    steps:
      # ── Host-level setup ──────────────────────────────────────────────
      # These steps MUST run on the host, not inside the bst2 container.
      # We cannot use `container:` at job level because
      # ublue-os/remove-unwanted-software needs host filesystem access.

      - name: Free disk space
        uses: ublue-os/remove-unwanted-software@695eb75bc387dbcd9685a8e72d23439d8686cba6

      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Pull BuildStream container image
        run: podman pull "$BST2_IMAGE"

      - name: Cache BuildStream sources
        uses: actions/cache@v4
        with:
          path: ~/.cache/buildstream/sources
          key: bst-sources-${{ hashFiles('elements/**/*.bst', 'project.conf') }}
          restore-keys: |
            bst-sources-

      - name: Disk space before build
        run: df -h /

      - name: Prepare BuildStream cache directory
        run: mkdir -p "$HOME/.cache/buildstream/sources"

      # ── Generate CI-specific BuildStream config ───────────────────────
      # Tuned per gnome-build-meta CI patterns:
      # - on-error: continue  -> find ALL failures, don't stop at first
      # - fetchers: 32        -> aggressive parallel downloads from cache
      # - builders: 1         -> GHA has 4 vCPUs; nproc/4 = 1
      # - retry-failed: True  -> auto-retry flaky builds
      # - error-lines: 80     -> generous error context in logs
      # - cache-buildtrees: never -> save disk (we only need final artifacts)

      - name: Generate BuildStream CI config
        run: |
          mkdir -p logs
          cat > buildstream-ci.conf <<'BSTCONF'
          scheduler:
            on-error: continue
            fetchers: 32
            builders: 1
            network-retries: 3

          logging:
            message-format: '[%{wallclock}][%{elapsed}][%{key}][%{element}] %{action} %{message}'
            error-lines: 80

          build:
            max-jobs: 0
            retry-failed: True

          cache:
            cache-buildtrees: never
          BSTCONF

      # ── BuildStream build ─────────────────────────────────────────────
      # Runs inside the bst2 container with:
      # - --privileged: required for bubblewrap sandboxing
      # - --device /dev/fuse: required for buildbox-fuse (ext4 lacks reflinks)
      # - ulimit -n 1048576: buildbox-casd needs many file descriptors
      # - --no-interactive: prevent blocking on prompts in CI

      - name: Build OCI image with BuildStream
        run: |
          podman run --rm \
            --privileged \
            --device /dev/fuse \
            -v "${{ github.workspace }}:/src:rw" \
            -v "$HOME/.cache/buildstream:/root/.cache/buildstream:rw" \
            -w /src \
            "$BST2_IMAGE" \
            bash -c '
              ulimit -n 1048576
              bst --no-interactive \
                  --colors \
                  --config /src/buildstream-ci.conf \
                  --log-file /src/logs/build.log \
                  build oci/bluefin.bst
            '
        timeout-minutes: 120

      - name: Disk space after build
        if: always()
        run: df -h /

      # ── Export OCI image ──────────────────────────────────────────────
      # Stream the OCI tar from BuildStream directly into podman on the
      # host. This avoids writing an intermediate tar file to disk.
      # Pattern: bst artifact checkout --tar - | podman load

      - name: Export OCI image from BuildStream
        id: export
        run: |
          LOADED=$(podman run --rm \
            --privileged \
            --device /dev/fuse \
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
          # podman load prints "Loaded image: <name>:<tag>" or "Loaded image(s): <id>"
          IMAGE_REF=$(echo "$LOADED" | grep -oP '(?<=Loaded image: ).*' || \
                      echo "$LOADED" | grep -oP '(?<=Loaded image\(s\): ).*')
          echo "image_ref=$IMAGE_REF" >> "$GITHUB_OUTPUT"
          echo "Loaded: $IMAGE_REF"

      - name: Verify image loaded
        run: podman images

      # ── Validation ────────────────────────────────────────────────────

      - name: Validate with bootc container lint
        run: |
          podman run --rm --privileged \
            -v /var/lib/containers:/var/lib/containers \
            "${{ steps.export.outputs.image_ref }}" \
            bootc container lint

      # ── Upload build logs ─────────────────────────────────────────────
      # Always upload, even on failure, so build failures can be diagnosed.

      - name: Upload build logs
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: buildstream-logs
          path: logs/
          retention-days: 7
          if-no-files-found: ignore

      # ── Publish to GHCR (main branch only) ───────────────────────────

      - name: Login to GHCR
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        run: |
          echo "${{ secrets.GITHUB_TOKEN }}" | \
            podman login ghcr.io --username ${{ github.actor }} --password-stdin

      - name: Tag image for GHCR
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        run: |
          podman tag "${{ steps.export.outputs.image_ref }}" \
            "${{ env.IMAGE_REGISTRY }}/${{ env.IMAGE_NAME }}:latest" \
            "${{ env.IMAGE_REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.sha }}"

      - name: Push to GHCR
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        run: |
          podman push --retry 3 "${{ env.IMAGE_REGISTRY }}/${{ env.IMAGE_NAME }}:latest"
          podman push --retry 3 "${{ env.IMAGE_REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.sha }}"
```

---

## Post-implementation checklist

After the workflow is committed, verify on first run:

- [ ] `ublue-os/remove-unwanted-software` completes and frees >30GB
- [ ] bst2 image pulls successfully from gitlab.com registry
- [ ] BuildStream picks up the CI config (`buildstream-ci.conf`)
- [ ] Upstream artifact cache at `gbm.gnome.org:11003` is reachable and serving artifacts
- [ ] `bst build oci/bluefin.bst` completes within 120 minutes
- [ ] `bst artifact checkout --tar - | podman load` produces a valid image
- [ ] `podman images` shows the loaded image with correct name/tag
- [ ] `bootc container lint` passes (or document known failures)
- [ ] Build logs are uploaded as artifacts even on failure
- [ ] Disk space does not exhaust during build (check `df -h` output)
- [ ] GHCR push works on main branch (requires `packages: write` permission)
- [ ] GHCR push is skipped on PRs
- [ ] Concurrency cancellation works (push two commits rapidly)

## Open risks / future improvements

1. **Upstream cache availability** -- If `gbm.gnome.org:11003` is down, builds will be extremely slow or fail. Consider adding a cache health-check step.
2. **Image name from podman load** -- The exact image name/tag baked into the BST OCI tar needs to be verified on first run. The `grep` in the export step may need adjustment.
3. **Disk space** -- Even after cleanup, large BST builds may exhaust runner disk. The `df -h` steps will reveal this.
4. **bst2 image updates** -- The pinned SHA will become stale. Consider periodic manual bumps or a Dependabot custom config.
5. **Image signing** -- ublue-os/bluefin uses cosign for image signing and Syft for SBOM generation. Add as follow-up.
6. **Multi-arch** -- Currently x86_64 only. If aarch64 is needed, add `ARCH_OPT: -o arch aarch64` and a matrix job.
7. **Source cache effectiveness** -- GitHub's 10GB cache limit may be insufficient for all BST sources. Monitor cache hit rates.
8. **`on-error: continue` runner cost** -- Continues building after failures, which uses more runner minutes. Worth it for diagnostics but monitor costs.
