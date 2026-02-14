default: build

# ── Configuration ─────────────────────────────────────────────────────
image_name := env("BUILD_IMAGE_NAME", "egg")
image_tag := env("BUILD_IMAGE_TAG", "latest")
base_dir := env("BUILD_BASE_DIR", ".")
filesystem := env("BUILD_FILESYSTEM", "btrfs")

# Same bst2 container image CI uses -- pinned by SHA for reproducibility
bst2_image := env("BST2_IMAGE", "registry.gitlab.com/freedesktop-sdk/infrastructure/freedesktop-sdk-docker-images/bst2:f89b4aef847ef040b345acceda15a850219eb8f1")

# VM settings
vm_ram := env("VM_RAM", "4096")
vm_cpus := env("VM_CPUS", "2")

# ── BuildStream wrapper ──────────────────────────────────────────────
# Runs any bst command inside the bst2 container via podman.
# Usage: just bst build oci/bluefin.bst
#        just bst show oci/bluefin.bst
bst *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "${HOME}/.cache/buildstream"
    podman run --rm \
        --privileged \
        --device /dev/fuse \
        -v "{{justfile_directory()}}:/src:rw" \
        -v "${HOME}/.cache/buildstream:/root/.cache/buildstream:rw" \
        -w /src \
        "{{bst2_image}}" \
        bash -c 'ulimit -n 1048576 || true; bst --colors "$@"' -- {{ARGS}}

# ── Build ─────────────────────────────────────────────────────────────
# Build the OCI image and load it into podman.
build:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "==> Building OCI image with BuildStream (inside bst2 container)..."
    just bst build oci/bluefin.bst

    echo "==> Exporting OCI image and loading into podman..."
    just bst artifact checkout --tar - oci/bluefin.bst | podman load

    echo "==> Build complete. Image loaded as {{image_name}}:{{image_tag}}"
    podman images | grep -E "{{image_name}}|REPOSITORY" || true

# ── Containerfile build (alternative) ────────────────────────────────
build-containerfile $image_name=image_name:
    sudo podman build --security-opt label=type:unconfined_t --squash-all -t "${image_name}:latest" .

# ── bootc helper ─────────────────────────────────────────────────────
bootc *ARGS:
    sudo podman run \
        --rm --privileged --pid=host \
        -it \
        -v /var/lib/containers:/var/lib/containers \
        -v /dev:/dev \
        -v "{{base_dir}}:/data" \
        --security-opt label=type:unconfined_t \
        "{{image_name}}:{{image_tag}}" bootc {{ARGS}}

# ── Generate bootable disk image ─────────────────────────────────────
generate-bootable-image $base_dir=base_dir $filesystem=filesystem:
    #!/usr/bin/env bash
    set -euo pipefail

    if [ ! -e "${base_dir}/bootable.raw" ] ; then
        echo "==> Creating 30G sparse disk image..."
        fallocate -l 30G "${base_dir}/bootable.raw"
    fi

    echo "==> Installing OS to disk image via bootc..."
    just bootc install to-disk --composefs-backend \
        --via-loopback /data/bootable.raw \
        --filesystem "${filesystem}" \
        --wipe \
        --bootloader systemd \
        --karg systemd.firstboot=no \
        --karg splash \
        --karg quiet \
        --karg console=tty0 \
        --karg systemd.debug_shell=ttyS1

    echo "==> Bootable disk image ready: ${base_dir}/bootable.raw"

# ── Boot VM ───────────────────────────────────────────────────────────
# Boot the raw disk image in QEMU with UEFI (OVMF).
# Requires: qemu-system-x86_64, OVMF firmware, KVM access
boot-vm $base_dir=base_dir:
    #!/usr/bin/env bash
    set -euo pipefail

    DISK="${base_dir}/bootable.raw"
    if [ ! -e "$DISK" ]; then
        echo "ERROR: ${DISK} not found. Run 'just generate-bootable-image' first." >&2
        exit 1
    fi

    # Auto-detect OVMF firmware paths
    OVMF_CODE=""
    for candidate in \
        /usr/share/edk2/ovmf/OVMF_CODE.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd \
        /usr/share/qemu/OVMF_CODE.fd; do
        if [ -f "$candidate" ]; then
            OVMF_CODE="$candidate"
            break
        fi
    done
    if [ -z "$OVMF_CODE" ]; then
        echo "ERROR: OVMF firmware not found. Install edk2-ovmf (Fedora) or ovmf (Debian/Ubuntu)." >&2
        exit 1
    fi

    # OVMF_VARS must be writable -- use a local copy
    OVMF_VARS="${base_dir}/.ovmf-vars.fd"
    if [ ! -e "$OVMF_VARS" ]; then
        OVMF_VARS_SRC=""
        for candidate in \
            /usr/share/edk2/ovmf/OVMF_VARS.fd \
            /usr/share/OVMF/OVMF_VARS.fd \
            /usr/share/OVMF/OVMF_VARS_4M.fd \
            /usr/share/edk2/x64/OVMF_VARS.4m.fd \
            /usr/share/qemu/OVMF_VARS.fd; do
            if [ -f "$candidate" ]; then
                OVMF_VARS_SRC="$candidate"
                break
            fi
        done
        if [ -z "$OVMF_VARS_SRC" ]; then
            echo "ERROR: OVMF_VARS not found alongside OVMF_CODE." >&2
            exit 1
        fi
        cp "$OVMF_VARS_SRC" "$OVMF_VARS"
    fi

    echo "==> Booting ${DISK} in QEMU (UEFI, KVM)..."
    echo "    Firmware: ${OVMF_CODE}"
    echo "    RAM: {{vm_ram}}M, CPUs: {{vm_cpus}}"
    echo "    Serial debug shell on ttyS1 available via QEMU monitor"
    echo ""

    qemu-system-x86_64 \
        -enable-kvm \
        -m "{{vm_ram}}" \
        -cpu host \
        -smp "{{vm_cpus}}" \
        -drive file="${DISK}",format=raw,if=virtio \
        -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
        -drive if=pflash,format=raw,file="${OVMF_VARS}" \
        -device virtio-vga \
        -display gtk \
        -device virtio-keyboard \
        -device virtio-mouse \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0 \
        -chardev stdio,id=char0,mux=on,signal=off \
        -serial chardev:char0 \
        -serial chardev:char0 \
        -mon chardev=char0

# ── Show me the future ────────────────────────────────────────────────
# The full end-to-end: build the OCI image, install it to a bootable
# disk, and launch it in a QEMU VM. One command to rule them all.
show-me-the-future:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              SHOW ME THE FUTURE                             ║"
    echo "║  Building Bluefin from source and booting it in a VM        ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    echo "==> Step 1/3: Building OCI image..."
    just build

    echo ""
    echo "==> Step 2/3: Generating bootable disk image..."
    just generate-bootable-image

    echo ""
    echo "==> Step 3/3: Launching VM..."
    just boot-vm
