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
# Uses charm.sh gum for a fancy progress TUI when available.
show-me-the-future:
    #!/usr/bin/env bash
    set -euo pipefail

    # ── Fallback: no gum or non-interactive ───────────────────────
    if ! command -v gum &>/dev/null || [[ ! -t 1 ]]; then
        [[ -t 1 ]] && echo "Note: Install 'gum' for a fancy progress display (https://github.com/charmbracelet/gum)"
        echo "==> Step 1/3: Building OCI image..."
        just build
        echo ""
        echo "==> Step 2/3: Generating bootable disk image..."
        just generate-bootable-image
        echo ""
        echo "==> Step 3/3: Launching VM..."
        just boot-vm
        exit 0
    fi

    # ── Configuration ─────────────────────────────────────────────
    TAIL_LINES=5
    SPINNER_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    LOGDIR=$(mktemp -d /tmp/egg-build-XXXXX)

    TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
    TAIL_WIDTH=$((TERM_WIDTH - 6))
    BANNER_WIDTH=$((TERM_WIDTH > 62 ? 60 : TERM_WIDTH - 4))

    # Step state arrays
    STEP_NAMES=("Build OCI image" "Bootable disk" "Launch VM")
    STEP_STATUS=("pending" "pending" "pending")
    STEP_TIMES=("" "" "")

    # Colors (ANSI 256)
    COLOR_ACCENT=212
    COLOR_OK=46
    COLOR_ERR=196
    COLOR_DIM=240
    COLOR_TIME=245
    COLOR_LOG=252
    COLOR_SEP=238

    # Track background PID for cleanup
    BG_PID=""
    OVERALL_START=$SECONDS

    # ── Signal handling ───────────────────────────────────────────
    cleanup_exit() {
        printf '\033[?25h'  # restore cursor
        rm -rf "$LOGDIR"
    }
    trap cleanup_exit EXIT

    cleanup_int() {
        if [[ -n "${BG_PID}" ]] && kill -0 "$BG_PID" 2>/dev/null; then
            kill "$BG_PID" 2>/dev/null || true
            wait "$BG_PID" 2>/dev/null || true
        fi
        printf '\033[?25h\n'
        echo "Interrupted."
        exit 130
    }
    trap cleanup_int INT

    # Hide cursor during TUI rendering
    printf '\033[?25l'

    # ── Helpers ───────────────────────────────────────────────────
    format_time() {
        local secs=$1
        if (( secs >= 3600 )); then
            printf '%dh %02dm %02ds' $((secs / 3600)) $(((secs % 3600) / 60)) $((secs % 60))
        elif (( secs >= 60 )); then
            printf '%dm %02ds' $((secs / 60)) $((secs % 60))
        else
            printf '%ds' "$secs"
        fi
    }

    render_banner() {
        gum style \
            --foreground $COLOR_ACCENT \
            --border-foreground $COLOR_ACCENT \
            --border double \
            --align center \
            --width $BANNER_WIDTH \
            --margin "1 2" \
            --padding "1 4" \
            'SHOW ME THE FUTURE' \
            'Building Bluefin from source and booting it in a VM'
    }

    render_step_bar() {
        local spin_char="${1:-}"
        local parts=()
        for i in 0 1 2; do
            local name="${STEP_NAMES[$i]}"
            local status="${STEP_STATUS[$i]}"
            local time_str="${STEP_TIMES[$i]}"
            local time_suffix=""
            if [[ -n "$time_str" ]]; then
                time_suffix=" (${time_str})"
            fi
            case "$status" in
                pending)
                    parts+=("$(gum style --foreground $COLOR_DIM "○ ${name}")")
                    ;;
                active)
                    parts+=("$(gum style --foreground $COLOR_ACCENT --bold "${spin_char} ${name}$(gum style --foreground $COLOR_TIME "${time_suffix}")")")
                    ;;
                done)
                    parts+=("$(gum style --foreground $COLOR_OK "✓ ${name}$(gum style --foreground $COLOR_TIME "${time_suffix}")")")
                    ;;
                failed)
                    parts+=("$(gum style --foreground $COLOR_ERR "✗ ${name}$(gum style --foreground $COLOR_TIME "${time_suffix}")")")
                    ;;
            esac
        done
        gum join --horizontal "${parts[0]}" "  " "${parts[1]}" "  " "${parts[2]}"
    }

    render_separator() {
        local sep_width=$((TAIL_WIDTH > 56 ? 56 : TAIL_WIDTH))
        gum style --foreground $COLOR_SEP "  $(printf '┄%.0s' $(seq 1 $sep_width))"
    }

    render_tail() {
        local logfile=$1
        local count=0
        if [[ -f "$logfile" ]] && [[ -s "$logfile" ]]; then
            while IFS= read -r line || [[ -n "$line" ]]; do
                printf '\033[2K  \033[38;5;%dm%s\033[0m\n' $COLOR_LOG "${line:0:$TAIL_WIDTH}"
                count=$((count + 1))
            done < <(tail -n "$TAIL_LINES" "$logfile" 2>/dev/null)
        fi
        while (( count < TAIL_LINES )); do
            printf '\033[2K\n'
            count=$((count + 1))
        done
    }

    # ── Core: run command with tail view ──────────────────────────
    run_with_tail() {
        local step_idx=$1; shift
        local logfile="${LOGDIR}/step${step_idx}.log"
        touch "$logfile"

        STEP_STATUS[$step_idx]="active"
        local start_time=$SECONDS
        local spin_idx=0
        local total_area=$((TAIL_LINES + 2))

        # Run command in background
        "$@" > "$logfile" 2>&1 &
        BG_PID=$!

        # Print initial empty tail area
        render_separator
        for _ in $(seq 1 $TAIL_LINES); do printf '\n'; done
        render_separator

        # Refresh loop
        while kill -0 "$BG_PID" 2>/dev/null; do
            local elapsed=$((SECONDS - start_time))
            STEP_TIMES[$step_idx]=$(format_time $elapsed)
            local sc=${SPINNER_CHARS:$((spin_idx % ${#SPINNER_CHARS})):1}

            # Move cursor up: tail area + step bar line
            printf '\033[%dA\r' $((total_area + 1))

            # Re-render step bar
            printf '\033[2K'
            render_step_bar "$sc"

            # Re-render tail area
            render_separator
            render_tail "$logfile"
            render_separator

            spin_idx=$((spin_idx + 1))
            sleep 0.1
        done

        # Collect exit code
        wait "$BG_PID"
        local exit_code=$?
        BG_PID=""

        # Final time
        local elapsed=$((SECONDS - start_time))
        STEP_TIMES[$step_idx]=$(format_time $elapsed)

        if (( exit_code == 0 )); then
            STEP_STATUS[$step_idx]="done"
        else
            STEP_STATUS[$step_idx]="failed"
        fi

        # Final render: update step bar, clear tail area
        printf '\033[%dA\r' $((total_area + 1))
        printf '\033[2K'
        render_step_bar ""
        for _ in $(seq 1 $total_area); do
            printf '\033[2K\n'
        done

        return $exit_code
    }

    # ── Error handler ─────────────────────────────────────────────
    on_error() {
        local failed_step=""
        for i in 0 1 2; do
            if [[ "${STEP_STATUS[$i]}" == "failed" ]]; then
                failed_step="${STEP_NAMES[$i]}"
                break
            fi
        done
        printf '\033[?25h'  # restore cursor
        echo ""
        render_step_bar ""
        echo ""
        gum style \
            --foreground $COLOR_ERR \
            --border-foreground $COLOR_ERR \
            --border rounded \
            --align center \
            --width $BANNER_WIDTH \
            --padding "1 2" \
            'BUILD FAILED' \
            "Failed: ${failed_step}" \
            "Total elapsed: $(format_time $((SECONDS - OVERALL_START)))" \
            '' \
            "Logs: ${LOGDIR}/"
        # Preserve logs on failure
        trap 'printf "\033[?25h"' EXIT
        exit 1
    }

    # ── Main flow ─────────────────────────────────────────────────
    render_banner
    echo ""
    render_step_bar ""
    echo ""

    # Step 1: Build OCI image
    run_with_tail 0 just build || on_error

    # Step 2: Generate bootable disk
    run_with_tail 1 just generate-bootable-image || on_error

    # Step 3: Launch VM (interactive -- no tail view)
    STEP_STATUS[2]="active"
    vm_start=$SECONDS

    # Re-render step bar for step 3
    printf '\033[1A\r\033[2K'
    render_step_bar "▸"
    echo ""

    # Restore cursor before handing off to QEMU
    printf '\033[?25h'
    just boot-vm

    STEP_TIMES[2]=$(format_time $((SECONDS - vm_start)))
    STEP_STATUS[2]="done"

    # ── Completion ────────────────────────────────────────────────
    echo ""
    render_step_bar ""
    echo ""
    gum style \
        --foreground $COLOR_OK \
        --border-foreground $COLOR_OK \
        --border rounded \
        --align center \
        --width 42 \
        --padding "1 2" \
        'ALL STEPS COMPLETE' \
        "Total: $(format_time $((SECONDS - OVERALL_START)))"

# ── Show me the future (plain) ────────────────────────────────────────
# Plain version without TUI -- useful for CI, piped output, or debugging.
show-me-the-future-plain:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> Step 1/3: Building OCI image..."
    just build
    echo ""
    echo "==> Step 2/3: Generating bootable disk image..."
    just generate-bootable-image
    echo ""
    echo "==> Step 3/3: Launching VM..."
    just boot-vm
