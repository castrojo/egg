---
name: patching-upstream-junctions
description: Use when modifying upstream freedesktop-sdk or gnome-build-meta elements, when fixing bugs in junction dependencies, or when deciding between patching an element vs replacing it entirely
---

# Patching Upstream Junctions

## Overview

Bluefin-egg builds on top of two upstream BuildStream projects via junctions: **freedesktop-sdk** and **gnome-build-meta**. When you need to modify an upstream element (fix a bug, change a build flag, backport a fix), you have two mechanisms: **patch_queue** (modify in-place) or **config.overrides** (replace entirely). This skill covers both.

## When to Use

- Fixing a bug in an upstream element (freedesktop-sdk or gnome-build-meta)
- Changing build flags or configure options on an upstream package
- Backporting a fix from a newer upstream version
- Deciding whether to patch an element or replace it with a local override

## Mechanism: patch_queue

Both junction elements apply a directory of patches to the upstream checkout:

```yaml
# elements/freedesktop-sdk.bst
sources:
- kind: git_repo
  url: gitlab:freedesktop-sdk/freedesktop-sdk.git
  ref: <pinned-ref>
- kind: patch_queue
  path: patches/freedesktop-sdk

# elements/gnome-build-meta.bst
sources:
- kind: git_repo
  url: gnome:gnome-build-meta.git
  ref: <pinned-ref>
- kind: patch_queue
  path: patches/gnome-build-meta
```

BuildStream applies all `.patch` files from the queue directory **in filename-sorted order** after checking out the git source.

## Patch Directories

| Junction | Patch directory |
|---|---|
| freedesktop-sdk | `patches/freedesktop-sdk/` |
| gnome-build-meta | `patches/gnome-build-meta/` |

## Creating a Patch

### Step 1: Clone the upstream project at the pinned ref

Find the ref in the junction element:
```bash
# For freedesktop-sdk:
grep 'ref:' elements/freedesktop-sdk.bst
# For gnome-build-meta:
grep 'ref:' elements/gnome-build-meta.bst
```

Clone and checkout (the `gitlab:` alias in `include/aliases.yml` resolves to `https://gitlab.com/`):
```bash
# freedesktop-sdk:
git clone https://gitlab.com/freedesktop-sdk/freedesktop-sdk.git /tmp/fdsdk
cd /tmp/fdsdk
git checkout <ref-from-junction>

# gnome-build-meta:
git clone https://gitlab.gnome.org/GNOME/gnome-build-meta.git /tmp/gbm
cd /tmp/gbm
git checkout <ref-from-junction>
```

### Step 2: Apply existing patches first

If the patch directory already has patches, apply them before making changes (your patch must apply on top of all existing ones):
```bash
# git am works for git format-patch output (0NNN-*.patch files)
git am /path/to/bluefin-egg/patches/freedesktop-sdk/0*.patch
# For plain diffs (e.g., flatpak-1.16.3.patch), use git apply instead:
git apply /path/to/bluefin-egg/patches/freedesktop-sdk/flatpak-*.patch
```

### Step 3: Make your changes and commit

Edit the upstream element files (paths are relative to the upstream repo root):
```bash
vim elements/components/openssh.bst
git add elements/components/openssh.bst
git commit -m "openssh: Use /etc/ssh as sysconfdir"
```

### Step 4: Generate the patch

```bash
git format-patch -1 HEAD -o /path/to/bluefin-egg/patches/freedesktop-sdk/
```

Rename the output to follow the numbering convention (see below).

### Step 5: Verify

```bash
just bst show oci/bluefin.bst
```

This resolves the full dependency graph including applying patch queues. If patches fail to apply, this will error.

## Naming Convention

**freedesktop-sdk** uses a numbered series:
```
0001-project-Specify-more-limits-to-the-CAS-configs.patch
0002-project.conf-Add-GNOME-CAS-servers.patch
0004-openssh-Use-etc-ssh-as-sysconfdir.patch
0007-lvm2-Disable-event-activation-by-default.patch
```

When adding a new patch, use the next number in the sequence (e.g., `0008-`). Gaps in numbering are acceptable (patches may have been removed).

**gnome-build-meta** uses upstream commit SHA as filename:
```
736f7794f272f9d9e4b60e9f3a7f32f40518addf.patch
```

Both formats are standard `git format-patch` output.

## Patches vs. Overrides

The junction elements also support `config.overrides` which **completely replaces** an upstream element with a local one:

```yaml
# In elements/gnome-build-meta.bst:
config:
  overrides:
    oci/os-release.bst: oci/os-release.bst        # Local Bluefin os-release
    oci/gnomeos.bst: oci/gnomeos.bst              # Local GNOME OS assembly
    gnomeos-deps/bootc.bst: core/bootc.bst        # Custom bootc build
    gnomeos-deps/plymouth-gnome-theme.bst: bluefin/plymouth-bluefin-theme.bst
```

### Decision Matrix

| Situation | Use | Why |
|---|---|---|
| Tweaking a build flag or variable | `patch_queue` | Small, targeted change |
| Adding a configure option | `patch_queue` | Small, targeted change |
| Bumping a source ref for one package | `patch_queue` | Changes one field |
| Fixing a bug in upstream build commands | `patch_queue` | Preserves upstream structure |
| Completely different build from upstream | `config.overrides` | Too many changes for a patch |
| Using a package from a different source | `config.overrides` | Replacing the entire element |
| Removing a package from the dependency graph | `config.overrides` (to void element) | Cannot be done with patches |
| The element needs ongoing local maintenance | `config.overrides` | Patches break on every upstream update |

**Rule of thumb:** If you'd change more than ~20 lines, consider an override instead of a patch.

## Cross-Junction Overrides

The `freedesktop-sdk.bst` junction has overrides that point to **gnome-build-meta** elements:

```yaml
# In elements/freedesktop-sdk.bst:
config:
  overrides:
    components/glib.bst: gnome-build-meta.bst:sdk/glib.bst
    components/systemd.bst: gnome-build-meta.bst:core-deps/systemd.bst
```

This means some freedesktop-sdk components are replaced by newer versions maintained in gnome-build-meta. This is an upstream GNOME pattern -- Bluefin inherits it.

## Common Mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| Patch paths relative to bluefin-egg root | Patch fails to apply | Paths must be relative to the upstream project root |
| Not applying existing patches before creating new one | New patch has wrong context lines | `git am` existing patches first |
| Forgetting to re-number after removing a patch | Confusing gaps (cosmetic only) | Renumber for clarity, or leave gaps |
| Not testing with `bst show` after adding patch | Discover failure at build time | Always `just bst show oci/bluefin.bst` first |
| Patching an element that's already overridden | Patch has no effect | Check `config.overrides` -- overrides take precedence |
| Not rebasing patches after bumping junction ref | Patches fail to apply on new upstream | Regenerate patches against new ref |

## Gotchas

- **Patches are applied in sorted filename order.** If patch B depends on patch A's changes, B must sort after A.
- **All `.patch` files in the directory are applied.** No selective skipping. Remove or rename to disable.
- **Bumping the junction ref may break patches.** When updating `ref:` in a junction element, check that all patches still apply cleanly.
- **`bst source track` on junction elements updates the ref.** This can invalidate patches -- always recheck after tracking.

## Real Examples

- **Build flag change:** `patches/freedesktop-sdk/0004-openssh-Use-etc-ssh-as-sysconfdir.patch` -- adds `sysconfdir: '/etc/ssh'` variable
- **Project config change:** `patches/freedesktop-sdk/0002-project.conf-Add-GNOME-CAS-servers.patch` -- modifies freedesktop-sdk's project.conf
- **Cherry-picked upstream commit:** `patches/gnome-build-meta/736f7794...patch` -- large upstream change for generated boot keys
- **Element override:** `elements/gnome-build-meta.bst` overrides for bootc, os-release, gnomeos
