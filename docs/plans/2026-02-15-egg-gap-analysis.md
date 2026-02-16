# Egg Gap Analysis & Curated Package Additions

> **Status: PARTIALLY IMPLEMENTED** -- Three of four packages complete: glow, gum, and fzf are present in `elements/bluefin/`. Caffeine GNOME Shell extension is not yet implemented. The gap analysis research (egg vs production Bluefin) in this plan remains the definitive reference for understanding egg's positioning as a curated subset, not a 1:1 clone.

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Close the most impactful gaps between egg and production Bluefin with four curated package additions: Caffeine extension, glow, gum, and fzf.

**Architecture:** Caffeine follows the Make + Zip GNOME Shell extension pattern (identical to blur-my-shell). glow, gum, and fzf are pre-built Go binary tarballs (identical to Tailscale, but simpler -- single-arch, no systemd services). All four are added as dependencies of `elements/bluefin/deps.bst` and flow into the image via the existing layer chain.

**Tech Stack:** BuildStream 2, YAML element definitions, shell install commands.

**Decision:** Egg is a **curated subset** of production Bluefin, not a 1:1 clone. It intentionally includes things production Bluefin doesn't have (sudo-rs, uutils-coreutils, GNOME nightly) and intentionally omits things that don't make sense for a from-source build (Nvidia drivers, ZFS, enterprise AD/Kerberos). The four packages in this plan were selected because they're part of the core Bluefin daily-use experience.

---

## Context: Three-Way Image Comparison

This section documents the full analysis of egg vs ublue-os/bluefin vs ublue-os/bluefin-lts for future reference. It was conducted on 2026-02-15.

### Architecture Overview

| Dimension | **egg** | **bluefin** | **bluefin-lts** |
|---|---|---|---|
| **Base** | freedesktop-sdk + gnome-build-meta (from source) | Fedora Silverblue (pre-built RPMs) | CentOS Stream 10 (pre-built RPMs) |
| **Build system** | BuildStream 2 (hermetic sandbox builds) | Containerfile + `dnf install` | Containerfile + `dnf install` |
| **Build time** | 120 min CI timeout, heavy | ~30-60 min CI | ~45-60 min CI |
| **Disk required** | **>50 GB** (BuildStream CAS) | ~15-20 GB | ~15-20 GB |
| **Desktop** | GNOME (nightly/latest) | GNOME (Fedora's version) | GNOME 48 (pinned via COPR) |
| **Kernel** | freedesktop-sdk kernel | Fedora kernel + akmods | CentOS kernel + akmods |
| **Update model** | `bootc` (native) | `rpm-ostree` (migrating to bootc) | `bootc` (native) |
| **Package count** | ~20 Bluefin-specific elements | ~80 base + ~60 DX RPMs | ~80 base + DX/GDX RPMs |
| **Architectures** | x86_64, aarch64, riscv64 | x86_64 primarily | x86_64, aarch64 |
| **Variants** | Single image | bluefin, bluefin-dx, nvidia | base, dx, gdx, HWE, nvidia |

### Fundamental Difference

Production Bluefin images (both regular and LTS) are **Containerfile-based overlays** -- they start with `FROM base_image` and run `dnf install` to add ~80-140 pre-built RPMs. Total build is 30-60 minutes on 15-20 GB disk. They never compile anything from source except 7 GNOME Shell extensions.

Egg **builds the entire stack from source** using BuildStream -- freedesktop-sdk provides glibc/systemd/kernel, gnome-build-meta provides GNOME Shell/Mutter/GTK, and egg adds Bluefin-specific packages. With good cache hits from GNOME's upstream CAS, most of this is pre-built. But Bluefin-specific Rust packages (bootc, uutils-coreutils, sudo-rs) and GRUB are compiled from source, making the build substantially heavier.

### What Egg Has That Others Don't

| Egg Unique Feature | Notes |
|---|---|
| **sudo-rs** (Rust sudo) | Memory-safe sudo replacement -- not in any production Bluefin |
| **uutils-coreutils** (Rust coreutils) | Memory-safe coreutils -- not in any production Bluefin |
| **Built entirely from source** | Reproducible, auditable, no RPM dependency |
| **GNOME nightly** | Latest GNOME, ahead of Fedora |
| **riscv64 support** | Neither bluefin nor bluefin-lts supports this |

### Full Gap Analysis

Organized by category. Y = present, N = absent, P = partial.

#### GNOME Shell Extensions

| Extension | egg | bluefin | bluefin-lts |
|---|:---:|:---:|:---:|
| AppIndicator | Y | Y | Y |
| Blur My Shell | Y | Y | Y |
| Dash to Dock | Y | Y | Y |
| GSConnect | Y | Y | Y |
| Logo Menu | Y | Y | Y |
| Search Light | Y | Y | Y |
| **Caffeine** | **N** | Y | Y |

#### Shell & Terminal Tools

| Package | egg | bluefin | bluefin-lts |
|---|:---:|:---:|:---:|
| just | Y | Y | Y |
| wl-clipboard | Y | Y | Y |
| **glow** | **N** | Y | Y |
| **gum** | **N** | Y | Y |
| **fzf** | **N** | Y | Y |
| fish | N | Y | N |
| zsh | N | Y | N |
| tmux | N | Y | N |
| Starship prompt | N | Y | N |
| fastfetch | N | Y | Y |
| xdg-terminal-exec | N | Y | Y |

#### Networking & VPN

| Package | egg | bluefin | bluefin-lts |
|---|:---:|:---:|:---:|
| Tailscale | Y | Y | Y |
| wireguard-tools | N | Y | Y |
| samba | N | Y | N |
| NM-openvpn | N | N | Y |

#### Containers

| Package | egg | bluefin | bluefin-lts |
|---|:---:|:---:|:---:|
| podman | Y | Y | Y |
| skopeo | Y | Y | Y |
| distrobox | Y | N | Y |
| containerd | N | Y | Y |
| buildah | N | N | Y |

#### Hardware & Drivers (intentionally out of scope for egg)

| Feature | egg | bluefin | bluefin-lts |
|---|:---:|:---:|:---:|
| Nvidia drivers | N | Y (variant) | Y (GDX variant) |
| ZFS | N | Y | Y |
| Xbox controller (xone) | N | Y | Y (HWE) |
| Framework laptop modules | N | Y | Y (HWE) |
| v4l2loopback | N | Y | Y (HWE) |

#### Developer Experience (DX -- future consideration)

| Package | egg | bluefin-dx | bluefin-lts-dx |
|---|:---:|:---:|:---:|
| Docker CE | N | Y | Y |
| VS Code | N | Y | Y |
| libvirt/QEMU | N | Y | Y |
| Cockpit | N | Y | Y |
| ROCm (AMD GPU) | N | Y | N |

#### Other Notable Gaps

| Package | egg | bluefin | bluefin-lts | Priority |
|---|:---:|:---:|:---:|---|
| fwupd | N | Y | Y | Future |
| firewalld | N | N | Y | Future |
| HPLIP (printing) | N | Y | Y | Future |
| ddcutil (monitors) | N | Y | Y | Future |
| restic/rclone (backup) | N | Y | Y | Future |
| adw-gtk3-theme | N | Y | N | Future |
| uupd (auto-updater) | N | Y | Y | Future (complex) |
| Bazaar (app store) | N | Y | Y | Future (complex) |
| AD/Kerberos/SSSD | N | Y | N | Probably never |

### Build Optimization Notes

The heaviest parts of the egg build (for future reference):

1. **Rust packages** -- bootc (~200 crates), uutils-coreutils (~250 crates), sudo-rs are compiled from source. Decision: **keep building from source** -- these are the crown jewels of egg's approach. Optimize via R2 caching instead.

2. **GRUB** -- built in 3 variants (i386-pc, i386-efi, x86_64-efi). Required because upstream GNOME OS uses systemd-boot only; Bluefin needs GRUB for bootc compatibility.

3. **Junction patches** -- 8 patches to freedesktop-sdk, 1 to gnome-build-meta. These modify the junction identity hash which may affect upstream cache hit rates. Upstreaming patches would improve this, but is out of scope for now.

4. **Pre-built binary pattern** -- already used successfully for Tailscale, Zig, Homebrew, fonts, and wallpapers. The Go CLI tools in this plan follow the same pattern.

---

## Implementation Tasks

### Task 1: Package Caffeine GNOME Shell Extension

**Files:**
- Create: `elements/bluefin/shell-extensions/caffeine.bst`
- Modify: `elements/bluefin/gnome-shell-extensions.bst` (add dependency)
- Modify: `elements/bluefin/shell-extensions/disable-ext-validator.bst` (add enabled-extensions override)

**Skills:** `packaging-gnome-shell-extensions` (Pattern 4: Make + Zip)

**Step 1: Create `elements/bluefin/shell-extensions/caffeine.bst`**

```yaml
kind: make

sources:
  - kind: git_repo
    url: github:eonpatapon/gnome-shell-extension-caffeine.git
    track: v*
    ref: v59-0-gbe31208

build-depends:
  - freedesktop-sdk.bst:public-stacks/buildsystem-make.bst
  - freedesktop-sdk.bst:components/jq.bst

depends:
  - freedesktop-sdk.bst:components/gettext.bst
  - gnome-build-meta.bst:sdk/glib.bst
  - gnome-build-meta.bst:core/gnome-shell.bst

variables:
  strip-binaries: ""

config:
  install-commands:
    - |
      %{make} build

      _uuid="$(jq -r .uuid "caffeine@patapon.info/metadata.json")"
      install -d "%{install-root}/usr/share/gnome-shell/extensions/${_uuid}"
      bsdtar xvf "${_uuid}.zip" \
        -C "%{install-root}/usr/share/gnome-shell/extensions/${_uuid}/" \
        --no-same-owner
      if [ -d "%{install-root}/usr/share/gnome-shell/extensions/${_uuid}/schemas" ]; then
        glib-compile-schemas --strict \
          "%{install-root}%{datadir}/gnome-shell/extensions/${_uuid}/schemas"
      fi
    - |
      %{install-extra}
```

**Important notes for implementer:**
- The `ref` above is approximate. Run `just bst source track bluefin/shell-extensions/caffeine.bst` to get the exact git-describe ref after creating the file.
- Caffeine has a non-standard layout: extension code lives in `caffeine@patapon.info/` subdirectory, so `metadata.json` is at `caffeine@patapon.info/metadata.json`.
- The zip is output as `caffeine@patapon.info.zip` at repo root (not in a `build/` subdirectory like blur-my-shell).
- UUID is `caffeine@patapon.info`.
- GSettings schema: `org.gnome.shell.extensions.caffeine`.

**Step 2: Add to `elements/bluefin/gnome-shell-extensions.bst`**

Add `- bluefin/shell-extensions/caffeine.bst` to the depends list, before `disable-ext-validator.bst`.

**Step 3: Add enabled-extensions GSettings override**

Modify `elements/bluefin/shell-extensions/disable-ext-validator.bst` to also enable all installed extensions by default. Add the `enabled-extensions` key to the existing override:

```
[org.gnome.shell]
disable-extension-version-validation=true
enabled-extensions=['caffeine@patapon.info', 'appindicatorsupport@rgcjonas.gmail.com', 'blur-my-shell@aunetx', 'dash-to-dock@micxgx.gmail.com', 'gsconnect@andyholmes.github.io', 'logomenu@aryan_k', 'search-light@icedman.github.com']
```

**Step 4: Validate**

Run: `just bst show bluefin/shell-extensions/caffeine.bst`

**Step 5: Build element**

Run: `just bst build bluefin/shell-extensions/caffeine.bst`

**Step 6: Commit**

```bash
git add elements/bluefin/shell-extensions/caffeine.bst
git add elements/bluefin/gnome-shell-extensions.bst
git add elements/bluefin/shell-extensions/disable-ext-validator.bst
git commit -m "feat: add Caffeine GNOME Shell extension, enable all extensions by default"
```

---

### Task 2: Package glow (Markdown Renderer)

**Files:**
- Create: `elements/bluefin/glow.bst`
- Modify: `elements/bluefin/deps.bst` (add dependency)

**Skills:** `packaging-pre-built-binaries` (single-arch pre-built binary with completions)

**Step 1: Create `elements/bluefin/glow.bst`**

```yaml
kind: manual

build-depends:
  - freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

sources:
  - kind: tar
    url: github_files:charmbracelet/glow/releases/download/v2.1.1/glow_2.1.1_Linux_x86_64.tar.gz
    ref: 59106b08be69b2a0bda1178327bbb7accd584e7c113ba3d2f5ef6e48ff3ac27f

variables:
  strip-binaries: ""

config:
  install-commands:
    - |
      install -Dm755 -t "%{install-root}%{bindir}" glow
    - |
      install -Dm644 -t "%{install-root}%{datadir}/bash-completion/completions" completions/glow.bash
      install -Dm644 -t "%{install-root}%{datadir}/zsh/site-functions" completions/glow.zsh
      install -Dm644 -t "%{install-root}%{datadir}/fish/vendor_completions.d" completions/glow.fish
    - |
      install -Dm644 -t "%{install-root}%{datadir}/man/man1" manpages/glow.1.gz
    - |
      %{install-extra}
```

**Tarball contents:** `glow` binary, `completions/{glow.bash, glow.fish, glow.zsh}`, `manpages/glow.1.gz`, LICENSE, README.md.

**Step 2: Add `- bluefin/glow.bst` to `elements/bluefin/deps.bst`**

**Step 3: Validate and build**

Run: `just bst show bluefin/glow.bst && just bst build bluefin/glow.bst`

**Step 4: Commit**

```bash
git add elements/bluefin/glow.bst elements/bluefin/deps.bst
git commit -m "feat: add glow markdown renderer v2.1.1"
```

---

### Task 3: Package gum (CLI UX Toolkit)

**Files:**
- Create: `elements/bluefin/gum.bst`
- Modify: `elements/bluefin/deps.bst` (add dependency)

**Skills:** `packaging-pre-built-binaries` (identical pattern to glow)

**Step 1: Create `elements/bluefin/gum.bst`**

```yaml
kind: manual

build-depends:
  - freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

sources:
  - kind: tar
    url: github_files:charmbracelet/gum/releases/download/v0.17.0/gum_0.17.0_Linux_x86_64.tar.gz
    ref: 69ee169bd6387331928864e94d47ed01ef649fbfe875baed1bbf27b5377a6fdb

variables:
  strip-binaries: ""

config:
  install-commands:
    - |
      install -Dm755 -t "%{install-root}%{bindir}" gum
    - |
      install -Dm644 -t "%{install-root}%{datadir}/bash-completion/completions" completions/gum.bash
      install -Dm644 -t "%{install-root}%{datadir}/zsh/site-functions" completions/gum.zsh
      install -Dm644 -t "%{install-root}%{datadir}/fish/vendor_completions.d" completions/gum.fish
    - |
      install -Dm644 -t "%{install-root}%{datadir}/man/man1" manpages/gum.1.gz
    - |
      %{install-extra}
```

**Tarball contents:** `gum` binary, `completions/{gum.bash, gum.fish, gum.zsh}`, `manpages/gum.1.gz`, LICENSE, README.md.

**Step 2: Add `- bluefin/gum.bst` to `elements/bluefin/deps.bst`**

**Step 3: Validate and build**

Run: `just bst show bluefin/gum.bst && just bst build bluefin/gum.bst`

**Step 4: Commit**

```bash
git add elements/bluefin/gum.bst elements/bluefin/deps.bst
git commit -m "feat: add gum CLI UX toolkit v0.17.0"
```

---

### Task 4: Package fzf (Fuzzy Finder)

**Files:**
- Create: `elements/bluefin/fzf.bst`
- Modify: `elements/bluefin/deps.bst` (add dependency)

**Skills:** `packaging-pre-built-binaries` (simplest variant -- binary only)

**Step 1: Create `elements/bluefin/fzf.bst`**

```yaml
kind: manual

build-depends:
  - freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

sources:
  - kind: tar
    url: github_files:junegunn/fzf/releases/download/v0.67.0/fzf-0.67.0-linux_amd64.tar.gz
    ref: 4be08018ca37b32518c608741933ea335a406de3558242b60619e98f25be2be1

variables:
  strip-binaries: ""

config:
  install-commands:
    - |
      install -Dm755 -t "%{install-root}%{bindir}" fzf
    - |
      %{install-extra}
```

**Tarball contents:** `fzf` binary only (flat tarball, no subdirectory). Shell completions are not bundled in the release tarball -- they live in the git repo's `shell/` directory and are typically installed via `fzf --bash`, `fzf --zsh`, or `fzf --fish` at runtime.

**Step 2: Add `- bluefin/fzf.bst` to `elements/bluefin/deps.bst`**

**Step 3: Validate and build**

Run: `just bst show bluefin/fzf.bst && just bst build bluefin/fzf.bst`

**Step 4: Commit**

```bash
git add elements/bluefin/fzf.bst elements/bluefin/deps.bst
git commit -m "feat: add fzf fuzzy finder v0.67.0"
```

---

## Task Dependencies

Tasks 2, 3, and 4 all modify `elements/bluefin/deps.bst`. If dispatching to subagents:
- Task 1 (Caffeine) is fully independent -- can run in parallel with anything.
- Tasks 2, 3, 4 should run **sequentially** to avoid merge conflicts on `deps.bst`, OR batch all `deps.bst` additions into a single final step.

## Verification

After all four tasks are complete:

```bash
just bst show oci/bluefin.bst   # Full dependency graph resolves
just build                       # Full image build (if local build env available)
```

The image should contain:
- `/usr/share/gnome-shell/extensions/caffeine@patapon.info/` with compiled schemas
- `/usr/bin/glow` with bash/zsh/fish completions and man page
- `/usr/bin/gum` with bash/zsh/fish completions and man page
- `/usr/bin/fzf`
- All extensions enabled by default via GSettings override

## Future Work (Not In This Plan)

Based on the gap analysis, these are the highest-priority additions for future plans:

| Package | Why | Effort |
|---|---|---|
| fastfetch | System info tool, in both production Bluefins | Low (pre-built binary) |
| Starship prompt | Shell prompt, core Bluefin UX | Low (pre-built binary) |
| fish shell | Alternative shell, in production Bluefin | Medium (build from source) |
| fwupd | Firmware updates, essential for hardware support | Medium (upstream element exists) |
| adw-gtk3-theme | GTK3 app theming consistency | Low-Medium |
