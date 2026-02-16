# Local OTA Registry Implementation Plan

> **Status: NOT IMPLEMENTED** -- This plan is complete and ready to execute but has not been implemented yet. The local registry workflow would enable faster local development iterations by allowing VMs to pull OTA updates from the host machine without needing to push to GHCR. Implementation should follow this plan task-by-task.

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable local builds to serve OTA updates to VMs via a local `zot` registry, so a developer machine can build, publish, and self-update without leaving the network.

**Architecture:** A `zot` OCI registry runs on the host as a podman container. After `just build`, a new `just publish` recipe pushes the image to the local registry. The VM (booted via QEMU) reaches the registry at `10.0.2.2:5000` (QEMU's host gateway). A one-time `bootc switch` inside the VM points it at the local registry. Subsequent `bootc upgrade` calls pull updates from the local build.

**Tech Stack:** zot (minimal OCI registry), podman, skopeo, bootc, QEMU user-mode networking

---

## Background

### The Problem

Today, a VM booted from a local build has its update source hardcoded to `ghcr.io/projectbluefin/egg:latest` via:

1. **OCI annotation** `org.opencontainers.image.ref.name` in `elements/oci/bluefin.bst:68`
2. **`IMAGE_REF`** in `elements/oci/os-release.bst:14` (written to `/usr/lib/os-release` and `/usr/share/ublue-os/image-info.json`)

Running `bootc upgrade` inside the VM tries to reach GHCR. There is no way to feed local builds back into a running VM as OTA updates.

### The Solution

A local `zot` registry bridges the gap:

```
 Host                                          VM (QEMU)
 ----                                          ---------
 just build                                    
   |                                           
   v                                           
 egg:latest (podman)                           
   |                                           
 just publish                                  
   |                                           
   v                                           
 zot (localhost:5000/egg:latest)  <---network---  bootc upgrade
                                    10.0.2.2:5000
```

### Why zot?

- Single binary, ~15 MB image (`ghcr.io/project-zot/zot-minimal-linux-amd64`)
- OCI-native -- no legacy Docker v1/v2 baggage
- Zero config for dev use (defaults are sane)
- Commonly used in bootc development workflows

### QEMU Networking

QEMU's user-mode networking (the default, already used in the Justfile) exposes the host at `10.0.2.2` from the guest's perspective. No bridge setup, no tap devices, no firewall rules needed. The VM can reach `10.0.2.2:5000` out of the box.

### Insecure Registry

The local registry has no TLS. Two things must be configured inside the image for `bootc upgrade` to work against it:

1. **`registries.conf.d` drop-in** -- Marks `10.0.2.2:5000` as an insecure (HTTP) registry
2. **`policy.json` override** -- Allows unsigned image pulls from the local registry (the default `IMAGE_REF` uses `ostree-image-signed` transport, but we have no signing infrastructure)

These configs only affect `10.0.2.2:5000` -- an IP that only exists inside QEMU VMs. They have zero effect on production systems or CI builds.

### `bootc switch` -- One-Time Operation

After the VM boots for the first time, run:

```bash
bootc switch --transport registry 10.0.2.2:5000/egg:latest
```

This permanently rewrites the VM's tracked image reference. All subsequent `bootc upgrade` calls pull from the local registry. This persists across reboots. You only do it once per VM disk image.

---

## Task Breakdown

### Task 1: Add insecure registry configuration element

**Files:**
- Create: `elements/bluefin/local-dev-registry.bst`

This BuildStream element drops two files into the image:

**Step 1: Create the element**

Create `elements/bluefin/local-dev-registry.bst`:

```yaml
kind: manual

depends:
  - freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ""

config:
  build-commands:
    # Container registries.conf.d drop-in: mark QEMU host gateway as insecure (HTTP)
    - mkdir -p %{install-root}%{sysconfdir}/containers/registries.conf.d/
    - |
      cat >"%{install-root}%{sysconfdir}/containers/registries.conf.d/50-local-dev.conf" <<'EOF'
      # Allow pulling images from the host's local registry when running inside
      # a QEMU VM with user-mode networking. 10.0.2.2 is QEMU's default gateway
      # to the host -- this address does not exist outside of QEMU VMs.
      [[registry]]
      location = "10.0.2.2:5000"
      insecure = true
      EOF

    # Container policy: accept unsigned images from the local registry
    - mkdir -p %{install-root}%{sysconfdir}/containers/policy.json.d/
    - |
      cat >"%{install-root}%{sysconfdir}/containers/policy.json.d/50-local-dev.json" <<'EOF'
      {
        "transports": {
          "docker": {
            "10.0.2.2:5000": [
              {
                "type": "insecureAcceptAnything"
              }
            ]
          }
        }
      }
      EOF
```

**Step 2: Wire it into the Bluefin layer**

Modify `elements/bluefin/deps.bst` to add `bluefin/local-dev-registry.bst` as a dependency. Find the existing dependency list and add it.

**Step 3: Verify the element resolves**

Run: `just bst show bluefin/local-dev-registry.bst`
Expected: Element metadata printed, no errors.

**Step 4: Commit**

```bash
git add elements/bluefin/local-dev-registry.bst
git commit -m "feat: add insecure registry config for local OTA dev workflow"
```

---

### Task 2: Add `just registry-start` recipe

**Files:**
- Modify: `Justfile`

**Step 1: Add registry configuration variables**

Add after the existing VM settings block (after line 14):

```just
# Local OTA registry settings
registry_name := "egg-registry"
registry_port := env("REGISTRY_PORT", "5000")
registry_image := "ghcr.io/project-zot/zot-minimal-linux-amd64:latest"
```

**Step 2: Add `registry-start` recipe**

Add the recipe:

```just
# ── Local OTA Registry ───────────────────────────────────────────────
# Start a local zot OCI registry for serving updates to VMs.
# The VM reaches the registry at 10.0.2.2:<port> via QEMU user-mode networking.
registry-start:
    #!/usr/bin/env bash
    set -euo pipefail

    if podman container exists "{{registry_name}}" 2>/dev/null; then
        echo "Registry already running on port {{registry_port}}"
        podman ps --filter name="{{registry_name}}" --format "table {{{{.Names}}}}\t{{{{.Status}}}}\t{{{{.Ports}}}}"
        exit 0
    fi

    echo "==> Starting zot registry on port {{registry_port}}..."
    podman run -d \
        --name "{{registry_name}}" \
        --replace \
        -p "{{registry_port}}:5000" \
        -v egg-registry-data:/var/lib/registry \
        "{{registry_image}}"

    echo "==> Registry running. Push images to localhost:{{registry_port}}/egg:latest"
    echo "    VM can pull from 10.0.2.2:{{registry_port}}/egg:latest"
```

**Step 3: Verify recipe parses**

Run: `just --list | grep registry`
Expected: `registry-start` appears in the list.

**Step 4: Commit**

```bash
git add Justfile
git commit -m "feat: add just registry-start recipe for local zot registry"
```

---

### Task 3: Add `just registry-stop` and `just registry-status` recipes

**Files:**
- Modify: `Justfile`

**Step 1: Add `registry-stop` recipe**

```just
# Stop the local OTA registry.
registry-stop:
    #!/usr/bin/env bash
    set -euo pipefail

    if ! podman container exists "{{registry_name}}" 2>/dev/null; then
        echo "Registry is not running."
        exit 0
    fi

    echo "==> Stopping registry..."
    podman stop "{{registry_name}}"
    echo "==> Registry stopped. Data preserved in 'egg-registry-data' volume."
```

**Step 2: Add `registry-status` recipe**

```just
# Show local registry status and catalog.
registry-status:
    #!/usr/bin/env bash
    set -euo pipefail

    if ! podman container exists "{{registry_name}}" 2>/dev/null; then
        echo "Registry is not running."
        echo "Start it with: just registry-start"
        exit 0
    fi

    echo "==> Registry container:"
    podman ps --filter name="{{registry_name}}" --format "table {{{{.Names}}}}\t{{{{.Status}}}}\t{{{{.Ports}}}}"
    echo ""
    echo "==> Catalog:"
    curl -s "http://localhost:{{registry_port}}/v2/_catalog" 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "(empty or unreachable)"
```

**Step 3: Verify recipes parse**

Run: `just --list | grep registry`
Expected: `registry-start`, `registry-stop`, `registry-status` all appear.

**Step 4: Commit**

```bash
git add Justfile
git commit -m "feat: add registry-stop and registry-status recipes"
```

---

### Task 4: Add `just publish` recipe

**Files:**
- Modify: `Justfile`

This recipe pushes the locally-built image from podman storage into the local zot registry.

**Step 1: Add `publish` recipe**

```just
# ── Publish to local registry ────────────────────────────────────────
# Push the locally-built image to the local zot registry.
# The registry must be running (just registry-start).
publish:
    #!/usr/bin/env bash
    set -euo pipefail

    if ! podman container exists "{{registry_name}}" 2>/dev/null; then
        echo "ERROR: Local registry is not running. Start it with: just registry-start" >&2
        exit 1
    fi

    echo "==> Publishing {{image_name}}:{{image_tag}} to localhost:{{registry_port}}..."
    sudo skopeo copy \
        --dest-tls-verify=false \
        containers-storage:{{image_name}}:{{image_tag}} \
        docker://localhost:{{registry_port}}/{{image_name}}:{{image_tag}}

    echo "==> Published. VM can pull from 10.0.2.2:{{registry_port}}/{{image_name}}:{{image_tag}}"
    echo "    To switch a running VM: bootc switch --transport registry 10.0.2.2:{{registry_port}}/{{image_name}}:{{image_tag}}"
```

**Step 2: Verify recipe parses**

Run: `just --list | grep publish`
Expected: `publish` appears in the list.

**Step 3: Commit**

```bash
git add Justfile
git commit -m "feat: add just publish recipe to push images to local registry"
```

---

### Task 5: Add `just vm-switch-local` convenience recipe

**Files:**
- Modify: `Justfile`

This is a convenience that prints the `bootc switch` command for the user. We can't run it automatically (the VM is interactive in QEMU), but we can make the command easy to copy.

**Step 1: Add `vm-switch-local` recipe**

```just
# ── VM update helpers ────────────────────────────────────────────────
# Print the bootc switch command to point a running VM at the local registry.
vm-switch-local:
    #!/usr/bin/env bash
    echo "Run this command INSIDE the VM to point it at the local registry:"
    echo ""
    echo "  sudo bootc switch --transport registry 10.0.2.2:{{registry_port}}/{{image_name}}:{{image_tag}}"
    echo ""
    echo "This is a one-time operation. After switching, 'bootc upgrade' pulls from the local registry."
    echo "The dev loop becomes:"
    echo "  1. Edit elements"
    echo "  2. just build"
    echo "  3. just publish"
    echo "  4. In VM: sudo bootc upgrade"
```

**Step 2: Commit**

```bash
git add Justfile
git commit -m "feat: add vm-switch-local helper recipe"
```

---

### Task 6: Integration -- end-to-end local OTA workflow test

This is a manual verification task. The implementing agent should confirm the full loop works:

**Step 1: Start the registry**

```bash
just registry-start
```

Expected: zot container starts, port 5000 bound.

**Step 2: Build and publish**

```bash
just build
just publish
```

Expected: Image pushed to `localhost:5000/egg:latest`.

**Step 3: Verify image is in registry**

```bash
just registry-status
```

Expected: Catalog shows `egg` repository.

**Step 4: Boot VM and switch**

```bash
just generate-bootable-image
just boot-vm
```

Inside the VM:

```bash
sudo bootc switch --transport registry 10.0.2.2:5000/egg:latest
```

Expected: bootc rewrites tracked image ref. Subsequent `sudo bootc upgrade` would pull from local registry.

**Step 5: Verify update flow**

Make a trivial change (e.g., bump a version string), rebuild, republish:

```bash
just build
just publish
```

Inside the VM:

```bash
sudo bootc upgrade
```

Expected: VM stages the updated image for next boot.

---

## Environment Variables (New)

| Variable | Default | Purpose |
|---|---|---|
| `REGISTRY_PORT` | `5000` | Port for the local zot registry |

## Design Decisions

| Decision | Why |
|---|---|
| zot over distribution/distribution | ~15 MB, OCI-native, zero config, no Docker legacy |
| `10.0.2.2` over localhost | QEMU standard host gateway; works without bridge/tap setup |
| `bootc switch` over build-time ref change | No changes to BuildStream elements or CI pipeline; one-time command |
| `registries.conf.d` drop-in over global config | Scoped to `10.0.2.2:5000` only; no effect on production |
| Named podman volume for registry data | Images persist across `registry-stop`/`registry-start` cycles |
| `skopeo copy` for publish | Already used in the build recipe; consistent tooling |
| No TLS | Local-only dev tool; `10.0.2.2` is unreachable from outside QEMU |

## Future Work

- **Auto-switch at install time:** Modify `just generate-bootable-image` to mount the installed disk and run `bootc switch` before first boot, eliminating the manual step.
- **`just show-me-the-future` integration:** Optionally start the registry and publish as part of the full pipeline.
- **Multi-arch support:** The registry can hold images for multiple architectures; `publish` could push a manifest list.
- **Signing:** Add cosign or similar for local image signing if signature verification is ever enforced.

## Skills That Should Reference This Plan

The following skills should be updated to mention the local registry workflow:

- **`local-e2e-testing`** -- Add a "Local OTA Updates" section describing the registry workflow and `just publish` recipe. This is the natural extension of the local dev loop.
- **`ci-pipeline-operations`** -- Note that the local registry is dev-only and CI continues to use GHCR. Agents should not conflate the two.
- **`oci-layer-composition`** -- Mention that `local-dev-registry.bst` adds container config files and is part of the Bluefin layer.
