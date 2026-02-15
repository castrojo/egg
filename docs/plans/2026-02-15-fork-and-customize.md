# Fork and Customize Onboarding Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make it trivially easy for someone to fork this repo, customize the package list, and boot into their own custom Linux desktop -- all locally, no CI or cloud infrastructure needed.

**Architecture:** A `just preflight` command validates prerequisites and auto-installs missing tools via Homebrew. The README documents a 4-step workflow: fork, edit `deps.bst`, run `just show-me-the-future`, boot into your OS. The `boot-vm` recipe is updated to detect Homebrew-installed QEMU firmware paths.

**Tech Stack:** just, podman, Homebrew (for qemu), BuildStream (via bst2 container)

---

## Context

### The Value Proposition

Bluefin Egg lets you build a custom GNOME-based Linux desktop from source. Everything happens on your laptop:

- **No GitHub Actions required** -- CI is a convenience for the upstream project, not a prerequisite for building
- **No cloud caching required** -- BuildStream caches all artifacts locally in `~/.cache/buildstream/`
- **No signing infrastructure** -- local images don't need signatures
- **No container registry** -- the image loads directly into podman

The only hard prerequisites are `podman` and `just`. QEMU (for booting the VM) can be installed automatically via Homebrew.

### Space Requirements

| What | Size |
|---|---|
| BuildStream cache (warm, after first build) | ~50 GB |
| Bootable disk image (`bootable.raw`) | 30 GB (sparse, actual usage ~8-10 GB) |
| bst2 container image | ~2 GB |
| QEMU + dependencies (via brew) | ~1 GB |
| Repository checkout | ~50 MB |
| **Total recommended free disk** | **~100 GB** |

The first build is the slowest -- BuildStream pulls pre-built artifacts from GNOME's upstream cache (`gbm.gnome.org:11003`), which populates `~/.cache/buildstream/`. Subsequent builds only rebuild changed elements and are much faster (minutes, not hours).

### What Gets Customized

The file `elements/bluefin/deps.bst` is the master package list. It's a BuildStream `stack` element that lists every Bluefin-specific package. Adding or removing a line here adds or removes a package from the final OS image.

Current packages include: GNOME Shell extensions, Homebrew, Tailscale, CLI tools (glow, gum, fzf), wallpapers, fonts, container tools (podman, distrobox), and Rust coreutils replacements.

---

## Task Breakdown

### Task 1: Add `just preflight` recipe

**Files:**
- Modify: `Justfile`

Add a preflight check that validates all prerequisites and offers to auto-install what's missing via Homebrew. This is the first thing a new user runs after cloning.

**Step 1: Add the `preflight` recipe to the Justfile**

Add after the configuration block (after line 14), before the bst wrapper:

```just
# ── Preflight checks ─────────────────────────────────────────────────
# Validate prerequisites and offer to install missing tools via Homebrew.
# Run this after cloning the repo to ensure everything is ready.
preflight:
    #!/usr/bin/env bash
    set -euo pipefail

    OK=true
    NEED_BREW=()

    check() {
        local name=$1 cmd=$2 brew_pkg=${3:-}
        if command -v "$cmd" &>/dev/null; then
            printf '  %-18s %s\n' "$name" "$(command -v "$cmd")"
        else
            printf '  %-18s %s\n' "$name" "MISSING"
            OK=false
            if [ -n "$brew_pkg" ]; then
                NEED_BREW+=("$brew_pkg")
            fi
        fi
    }

    echo "Checking prerequisites..."
    echo ""
    check "podman"    podman    ""
    check "just"      just      ""
    check "qemu"      qemu-system-x86_64  qemu
    echo ""

    # Check disk space (need ~100 GB free)
    FREE_GB=$(df --output=avail -BG . 2>/dev/null | tail -1 | tr -d ' G' || echo "0")
    if [ "$FREE_GB" -ge 100 ] 2>/dev/null; then
        printf '  %-18s %s GB free\n' "disk space" "$FREE_GB"
    elif [ "$FREE_GB" -ge 50 ] 2>/dev/null; then
        printf '  %-18s %s GB free (tight -- 100 GB recommended)\n' "disk space" "$FREE_GB"
    else
        printf '  %-18s %s GB free (need at least 50 GB, 100 GB recommended)\n' "disk space" "$FREE_GB"
        OK=false
    fi
    echo ""

    # OVMF/edk2 firmware check
    OVMF_FOUND=false
    for candidate in \
        /usr/share/edk2/ovmf/OVMF_CODE.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd \
        /usr/share/qemu/OVMF_CODE.fd; do
        if [ -f "$candidate" ]; then
            printf '  %-18s %s\n' "UEFI firmware" "$candidate"
            OVMF_FOUND=true
            break
        fi
    done
    # Check brew qemu's bundled edk2 firmware
    if ! $OVMF_FOUND; then
        BREW_QEMU_SHARE="$(brew --prefix qemu 2>/dev/null)/share/qemu" 2>/dev/null || true
        if [ -f "${BREW_QEMU_SHARE}/edk2-x86_64-code.fd" ] 2>/dev/null; then
            printf '  %-18s %s\n' "UEFI firmware" "${BREW_QEMU_SHARE}/edk2-x86_64-code.fd (brew)"
            OVMF_FOUND=true
        fi
    fi
    if ! $OVMF_FOUND; then
        printf '  %-18s %s\n' "UEFI firmware" "MISSING (install qemu via brew or edk2-ovmf via system package manager)"
        OK=false
    fi
    echo ""

    # Offer to install missing brew packages
    if [ ${#NEED_BREW[@]} -gt 0 ] && command -v brew &>/dev/null; then
        echo "Missing tools available via Homebrew: ${NEED_BREW[*]}"
        read -rp "Install them now? [Y/n] " answer
        if [[ "${answer:-y}" =~ ^[Yy]$ ]]; then
            brew install "${NEED_BREW[@]}"
            echo ""
            echo "Installed. Re-running preflight..."
            exec just preflight
        fi
    elif [ ${#NEED_BREW[@]} -gt 0 ]; then
        echo "Missing tools: ${NEED_BREW[*]}"
        echo "Install Homebrew (https://brew.sh) then run: brew install ${NEED_BREW[*]}"
    fi

    if $OK; then
        echo "All prerequisites met. You're ready to build."
        echo ""
        echo "Quick start:"
        echo "  just show-me-the-future     # Build + boot VM (first run: ~1 hour)"
        echo ""
        echo "Or step by step:"
        echo "  just build                  # Build the OCI image"
        echo "  just generate-bootable-image  # Create bootable disk"
        echo "  just boot-vm                # Launch QEMU VM"
    else
        echo "Some prerequisites are missing. Install them and re-run: just preflight"
        exit 1
    fi
```

**Step 2: Verify the recipe parses**

Run: `just --list | grep preflight`
Expected: `preflight` appears in the list.

**Step 3: Test the preflight check**

Run: `just preflight`
Expected: All checks pass (podman, just, qemu all present on this machine). Disk space shown. UEFI firmware detected.

**Step 4: Commit**

```bash
git add Justfile
git commit -m "feat: add just preflight recipe for prerequisite validation"
```

---

### Task 2: Update `boot-vm` to detect Homebrew QEMU firmware

**Files:**
- Modify: `Justfile`

The current `boot-vm` recipe only checks system paths for OVMF firmware. Homebrew's QEMU ships edk2 firmware under a different name (`edk2-x86_64-code.fd` instead of `OVMF_CODE.fd`) and in the brew prefix. Update the detection to find it.

**Step 1: Update OVMF_CODE detection in `boot-vm`**

In the `boot-vm` recipe, replace the OVMF_CODE candidate list (lines 118-127) to also check the brew path:

The current block:
```bash
    OVMF_CODE=""
    for candidate in \
        /usr/share/edk2/ovmf/OVMF_CODE.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd \
        /usr/share/qemu/OVMF_CODE.fd; do
```

Replace with:
```bash
    # Resolve brew's qemu share directory (if brew is available)
    BREW_QEMU_SHARE=""
    if command -v brew &>/dev/null; then
        BREW_QEMU_SHARE="$(brew --prefix qemu 2>/dev/null)/share/qemu" 2>/dev/null || true
    fi

    OVMF_CODE=""
    for candidate in \
        /usr/share/edk2/ovmf/OVMF_CODE.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd \
        /usr/share/qemu/OVMF_CODE.fd \
        "${BREW_QEMU_SHARE}/edk2-x86_64-code.fd"; do
        [ -z "$candidate" ] && continue
```

**Step 2: Update OVMF_VARS detection**

The OVMF_VARS detection needs the same treatment. Additionally, Homebrew's QEMU edk2 firmware does not ship a separate x86_64 VARS file. When using brew's edk2-x86_64-code.fd, create an empty VARS file (UEFI variable store) using `truncate`:

Replace the OVMF_VARS candidate block with:
```bash
    OVMF_VARS="${base_dir}/.ovmf-vars.fd"
    if [ ! -e "$OVMF_VARS" ]; then
        OVMF_VARS_SRC=""
        for candidate in \
            /usr/share/edk2/ovmf/OVMF_VARS.fd \
            /usr/share/OVMF/OVMF_VARS.fd \
            /usr/share/OVMF/OVMF_VARS_4M.fd \
            /usr/share/edk2/x64/OVMF_VARS.4m.fd \
            /usr/share/qemu/OVMF_VARS.fd \
            "${BREW_QEMU_SHARE}/edk2-i386-vars.fd"; do
            [ -z "$candidate" ] && continue
            if [ -f "$candidate" ]; then
                OVMF_VARS_SRC="$candidate"
                break
            fi
        done
        if [ -z "$OVMF_VARS_SRC" ]; then
            echo "WARN: No OVMF_VARS template found. Creating empty 528K variable store." >&2
            truncate -s 540672 "$OVMF_VARS"
        else
            cp "$OVMF_VARS_SRC" "$OVMF_VARS"
        fi
    fi
```

Note: `edk2-i386-vars.fd` (528 KB) works as a variable store for x86_64 UEFI -- the variable store format is architecture-independent. If no template exists at all, we create an empty 528 KB file which QEMU will initialize on first boot.

**Step 3: Verify boot-vm still works**

Run: `just boot-vm` (assuming a bootable.raw exists)
Expected: QEMU launches using the detected firmware. If no bootable.raw exists, the recipe exits with the expected "bootable.raw not found" error.

**Step 4: Commit**

```bash
git add Justfile
git commit -m "feat: detect Homebrew QEMU edk2 firmware in boot-vm"
```

---

### Task 3: Wire `just preflight` into `show-me-the-future`

**Files:**
- Modify: `Justfile`

Make `show-me-the-future` run the preflight check as its first step, so first-time users who jump straight to `just show-me-the-future` get prerequisite validation automatically.

**Step 1: Add preflight as the first step in `show-me-the-future`**

In the `show-me-the-future` recipe, add a preflight step after the banner and before `run_step "Build OCI image"`:

```bash
    # ── Preflight ─────────────────────────────────────────────────
    run_step "Preflight check" just preflight
    echo ""
```

This goes right after the banner `echo ""` on line 274, before the `# ── Steps ──` comment on line 276.

**Step 2: Verify show-me-the-future includes preflight**

Run: `just show-me-the-future` (or just check the recipe parses with `just --list`)
Expected: Preflight check runs first, then build, then generate-bootable-image, then boot-vm.

**Step 3: Commit**

```bash
git add Justfile
git commit -m "feat: run preflight check at start of show-me-the-future"
```

---

### Task 4: Update the README

**Files:**
- Modify: `README.md`

Replace the current minimal README with a proper onboarding guide. Keep it concise -- the audience is end users who want to fork and customize, not BuildStream developers.

**Step 1: Write the new README**

```markdown
![Conga](https://github.com/user-attachments/assets/2e3dc15c-4f49-48e4-98f8-bcf448f8af2f)

# egg

Bluefin's Primal Form -- build a custom GNOME Linux desktop entirely from source on your laptop.

No CI pipelines. No cloud infrastructure. No container registries. Just `podman`, `just`, and disk space.

## Make It Yours

1. **Fork this repo** and clone your fork
2. **Edit the package list** in `elements/bluefin/deps.bst` -- add or remove lines to customize what ships in your image
3. **Build and boot:**
   ```
   just show-me-the-future
   ```

That's it. The first build takes about an hour (it pulls cached artifacts from GNOME's upstream servers). After that, rebuilds only touch what changed.

## Prerequisites

You need [podman](https://podman.io/docs/installation), [just](https://just.systems/man/en/packages.html), and [QEMU](https://www.qemu.org/) with UEFI firmware.

On Fedora/Bluefin:

```bash
sudo dnf install podman just qemu-system-x86 edk2-ovmf
```

**(WIP)** `just preflight` -- a preflight check that validates your setup and auto-installs missing tools (like QEMU) via [Homebrew](https://brew.sh), reducing hard prerequisites to just `podman` and `just`.

## How It Works

[BuildStream](https://buildstream.build/) resolves a dependency graph rooted at `elements/oci/bluefin.bst`, pulls pre-built artifacts from GNOME's public cache, builds anything that's missing, and produces a bootable OCI container image. The image is installed to a virtual disk and booted in QEMU.

All build artifacts are cached locally in `~/.cache/buildstream/`. There is no cloud dependency beyond the initial artifact fetch from GNOME's servers. Your laptop is the build farm.

### Disk Space

| What | Size |
|---|---|
| Build cache (after first build) | ~50 GB |
| Bootable VM disk | 30 GB (sparse) |
| Total recommended free | **100 GB** |

### Step-by-Step Commands

If you prefer more control over each step:

```bash
just build                     # Build the OCI image (~1 hour first time, minutes after)
just generate-bootable-image   # Create a bootable disk from the image
just boot-vm                   # Launch QEMU VM -- a GNOME desktop appears
```

### Iterative Development

After the first build, the edit-rebuild-boot cycle is fast:

```bash
# 1. Edit elements/bluefin/deps.bst (or any element)
# 2. Rebuild -- only changed elements are rebuilt
just build
# 3. Regenerate the disk and boot
just generate-bootable-image
just boot-vm
```

**(WIP)** Local OTA updates -- push rebuilt images to a local registry and update a running VM without rebooting the full pipeline:

```bash
just registry-start              # Start local OCI registry
just build && just publish       # Build and push to local registry
# In VM: sudo bootc upgrade      # Pull the update over the network
```

## Customizing Packages

The file `elements/bluefin/deps.bst` controls what ships in the image. Each line is a BuildStream element:

```yaml
depends:
  # GNOME Shell extensions
  - bluefin/gnome-shell-extensions.bst

  # CLI tools
  - bluefin/glow.bst
  - bluefin/gum.bst
  - bluefin/fzf.bst

  # Fonts
  - bluefin/jetbrains-mono.bst

  # ... add your own here
```

To **remove a package**: delete its line from `deps.bst`.

To **add a package**: create a `.bst` element in `elements/bluefin/` and add it to `deps.bst`. Look at existing elements like `elements/bluefin/glow.bst` for a simple example -- it downloads a pre-built binary and installs it to the right path.

Packages from the upstream [freedesktop-sdk](https://gitlab.com/freedesktop-sdk/freedesktop-sdk) and [gnome-build-meta](https://gitlab.gnome.org/GNOME/gnome-build-meta) projects can be included directly by referencing their junction path:

```yaml
  - freedesktop-sdk.bst:components/some-package.bst
  - gnome-build-meta.bst:gnomeos-deps/some-other-package.bst
```

## Project Structure

```
elements/
  bluefin/           Bluefin-specific packages (edit these)
    deps.bst         Master package list (start here)
  core/              Core system overrides (bootc, grub, ptyxis)
  oci/               Image assembly pipeline
    bluefin.bst      THE build target
  freedesktop-sdk.bst   Junction to freedesktop-sdk
  gnome-build-meta.bst  Junction to gnome-build-meta
files/               Static files (plymouth theme, etc.)
patches/             Patches applied to upstream projects
Justfile             All build commands
```

## Roadmap

These features are planned but not yet implemented:

- **`just preflight`** -- automated prerequisite checking with Homebrew auto-install
- **Local OTA updates** -- `just registry-start` / `just publish` for iterative VM updates via `bootc upgrade`
- **`just add-package <url>`** -- scaffolding a new package element from a GitHub release URL
- **Rebranding guide** -- documentation for people who want to change the image name/identity
- **Multi-arch builds** -- aarch64 support
```

**Step 2: Verify README renders**

Review the written README content for correctness:
- Commands that exist today (`just show-me-the-future`, `just build`, `just generate-bootable-image`, `just boot-vm`) are documented without WIP markers.
- Commands that don't exist yet (`just preflight`, `just registry-start`, `just publish`) are marked with **(WIP)**.
- The Roadmap section lists all planned-but-unimplemented features.

**Step 3: Commit**

```bash
git add README.md
git commit -m "docs: rewrite README with fork-and-customize onboarding guide"
```

---

## Design Decisions

| Decision | Why |
|---|---|
| Packages only, no rebranding | YAGNI -- most forkers want custom packages, not a new distro identity. Rebranding can be documented later. |
| `just preflight` over manual prereq list | New users get cryptic errors when podman/qemu are missing. Automated checks with auto-install are friendlier. |
| Brew for QEMU | Reduces hard prerequisites to just `podman` and `just`. Brew QEMU includes edk2 firmware, eliminating the separate OVMF install step. |
| Preflight in `show-me-the-future` | First-time users will run this command. Catching missing prereqs before a long build is essential. |
| 100 GB recommended disk | 50 GB cache + 30 GB disk image + overhead. Under-estimating causes frustrating mid-build failures. |
| No CI documentation | This plan is for local-only users. CI setup is a separate concern for people who want to publish images. |
| Build-and-boot, not local OTA | The local OTA registry (zot, bootc switch) is a power-user workflow. The default onboarding should be the simplest possible path. |

## Future Work

See the Roadmap section in the README for user-facing planned features. Additional internal work:

- **Update README after each plan is implemented** -- remove (WIP) markers and add concrete instructions as features land
- **Rebranding automation** -- evaluate a `just rebrand` command if demand exists
- **Onboarding telemetry** -- understand where new users get stuck (build failures, disk space, etc.)

## Skills That Should Reference This Plan

- **`local-e2e-testing`** -- Reference the preflight check and brew QEMU path
- **`adding-a-package`** -- Reference the README's "Customizing Packages" section as end-user documentation
