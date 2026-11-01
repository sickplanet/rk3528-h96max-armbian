#!/usr/bin/env bash
# H96 Max Armbian builder.
# Synchronizes all project-owned Armbian inputs, prompts for the image flavour,
# builds the DTB or full image, and optionally flashes only a fresh image.

# Do not allow accidental sourcing.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    printf 'Run this script, do not source it:\n  bash %q\n' "${BASH_SOURCE[0]}" >&2
    return 2
fi

set -Eeuo pipefail

MODE="${1:-full}"
if [[ "$MODE" != "full" && "$MODE" != "dtb" ]] || [[ "$#" -gt 1 ]]; then
    printf 'Usage: %s [full|dtb]\n' "$(basename "$0")" >&2
    exit 2
fi

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BUILD_DIR="${H96_BUILD_DIR:-$PROJECT_DIR/armbian-build-h96max-clean}"
PATCHES_DIR="$PROJECT_DIR/patches"

fail() {
    printf '\n[ERROR] %s\n' "$*" >&2
    exit 1
}

on_error() {
    local status=$?
    trap - ERR
    printf '\n[FAILED] Command returned status %s. See the output above.\n' "$status" >&2
    exit "$status"
}
trap on_error ERR

[[ -d "$PATCHES_DIR/config" ]] || fail "Project board config directory not found: $PATCHES_DIR/config"
[[ -d "$PATCHES_DIR/patch" ]] || fail "Project patch directory not found: $PATCHES_DIR/patch"
[[ -d "$BUILD_DIR" ]] || fail "Armbian build directory not found: $BUILD_DIR"
[[ -f "$BUILD_DIR/compile.sh" ]] || fail "compile.sh not found in: $BUILD_DIR"
command -v rsync >/dev/null 2>&1 || fail "rsync is required. Install it with: sudo apt install rsync"
command -v lsblk >/dev/null 2>&1 || fail "lsblk is required (util-linux)."

# ---------------------------------------------------------------------------
# Image selection happens before synchronization or build activity.
# Armbian's current image switches are BUILD_DESKTOP, BUILD_MINIMAL,
# DESKTOP_ENVIRONMENT and DESKTOP_TIER.
# ---------------------------------------------------------------------------
BUILD_DESKTOP="no"
BUILD_MINIMAL="yes"
DESKTOP_ENVIRONMENT=""
DESKTOP_TIER=""

prompt_desktop_choice() {
    local answer choice tier_choice
    local -a desktop_ids=(xfce kde-plasma mate cinnamon gnome i3-wm)
    local -a desktop_names=("XFCE (lightweight)" "KDE Plasma" "MATE" "Cinnamon" "GNOME" "i3 (tiling window manager)")
    local -a tier_ids=(minimal mid full)

    if [[ -n "${H96_DESKTOP:-}" ]]; then
        answer="${H96_DESKTOP,,}"
    else
        [[ -t 0 ]] || fail "Full builds need an interactive desktop choice. Set H96_DESKTOP=no or H96_DESKTOP=yes (plus H96_DESKTOP_ENVIRONMENT and H96_DESKTOP_TIER) for non-interactive use."
        printf '\n============================================================\n'
        printf ' H96 Max image: graphical desktop selection\n'
        printf '============================================================\n'
        read -r -p 'Do you want a graphical desktop environment? [y/N]: ' answer
        answer="${answer:-no}"
        answer="${answer,,}"
    fi

    case "$answer" in
        y|yes|1|true)
            BUILD_DESKTOP="yes"
            BUILD_MINIMAL="no"
            ;;
        n|no|0|false|'')
            BUILD_DESKTOP="no"
            BUILD_MINIMAL="yes"
            printf '\nSelected image: minimal CLI (no graphical desktop).\n'
            return 0
            ;;
        *)
            fail "Invalid H96_DESKTOP value '$answer'. Use yes or no."
            ;;
    esac

    if [[ -n "${H96_DESKTOP_ENVIRONMENT:-}" ]]; then
        DESKTOP_ENVIRONMENT="${H96_DESKTOP_ENVIRONMENT,,}"
    else
        [[ -t 0 ]] || fail "Set H96_DESKTOP_ENVIRONMENT for a non-interactive desktop build."
        printf '\nChoose a desktop environment:\n'
        for i in "${!desktop_ids[@]}"; do
            printf '  %d) %s\n' "$((i + 1))" "${desktop_names[$i]}"
        done
        while true; do
            read -r -p 'Desktop choice [1-6, default 1 = XFCE]: ' choice
            choice="${choice:-1}"
            if [[ "$choice" =~ ^[1-6]$ ]]; then
                DESKTOP_ENVIRONMENT="${desktop_ids[$((choice - 1))]}"
                break
            fi
            # Also accept the Armbian switch value directly.
            choice="${choice,,}"
            local found=no
            for id in "${desktop_ids[@]}"; do
                if [[ "$choice" == "$id" ]]; then
                    DESKTOP_ENVIRONMENT="$id"
                    found=yes
                    break
                fi
            done
            [[ "$found" == yes ]] && break
            printf 'Invalid choice. Enter 1-6 or one of: %s\n' "${desktop_ids[*]}" >&2
        done
    fi

    local valid_environment=no
    for id in "${desktop_ids[@]}"; do
        [[ "$DESKTOP_ENVIRONMENT" == "$id" ]] && valid_environment=yes
    done
    [[ "$valid_environment" == yes ]] || fail "Unsupported desktop choice '$DESKTOP_ENVIRONMENT'. Choose one of: ${desktop_ids[*]}"

    if [[ -n "${H96_DESKTOP_TIER:-}" ]]; then
        DESKTOP_TIER="${H96_DESKTOP_TIER,,}"
    else
        [[ -t 0 ]] || fail "Set H96_DESKTOP_TIER (minimal, mid or full) for a non-interactive desktop build."
        printf '\nChoose the desktop software tier:\n'
        printf '  1) minimal — desktop and basic utilities only\n'
        printf '  2) mid     — desktop plus browser and common applications\n'
        printf '  3) full    — mid plus office and creative applications\n'
        while true; do
            read -r -p 'Desktop tier [1-3, default 2 = mid]: ' tier_choice
            tier_choice="${tier_choice:-2}"
            case "$tier_choice" in
                1|minimal) DESKTOP_TIER=minimal; break ;;
                2|mid)     DESKTOP_TIER=mid; break ;;
                3|full)    DESKTOP_TIER=full; break ;;
                *) printf 'Invalid tier. Enter 1, 2 or 3.\n' >&2 ;;
            esac
        done
    fi

    case "$DESKTOP_TIER" in
        minimal|mid|full) ;;
        *) fail "Invalid desktop tier '$DESKTOP_TIER'. Use minimal, mid or full." ;;
    esac

    printf '\nSelected image: desktop=%s, tier=%s\n' "$DESKTOP_ENVIRONMENT" "$DESKTOP_TIER"
    printf 'Armbian documents these switches; desktop availability can vary by release/architecture.\n'
}

if [[ "$MODE" == "full" ]]; then
    prompt_desktop_choice
else
    printf '\nDTB-only mode: desktop selection is not applicable.\n'
fi

printf '\n============================================================\n'
printf ' H96 Max: synchronize project inputs, then build (%s)\n' "$MODE"
printf '============================================================\n'
printf 'Project: %s\n' "$PROJECT_DIR"
printf 'Build:   %s\n' "$BUILD_DIR"

# ---------------------------------------------------------------------------
# Synchronize every project-owned Armbian input tree. We intentionally do not
# use --delete: config/, patch/, packages/ and extensions/ also contain
# upstream Armbian content that must be preserved.
# --checksum ensures changed contents are copied even if timestamps match.
# ---------------------------------------------------------------------------
sync_tree() {
    local source_dir="$1"
    local destination_dir="$2"
    local label="$3"

    if [[ -d "$source_dir" ]]; then
        printf '\n========== SYNC: %s -> %s ==========' "$label" "$destination_dir"
        mkdir -p "$destination_dir"
        rsync -a --checksum --itemize-changes "$source_dir/" "$destination_dir/"
    else
        printf '\n[SKIP] Optional project input directory not present: %s\n' "$source_dir"
    fi
}

printf '\n\n========== SYNCHRONIZE ALL PROJECT BUILD INPUTS ==========' 
sync_tree "$PATCHES_DIR/config" "$BUILD_DIR/config" "patches/config"
sync_tree "$PATCHES_DIR/patch" "$BUILD_DIR/patch" "patches/patch"
sync_tree "$PROJECT_DIR/extensions" "$BUILD_DIR/extensions" "extensions"
sync_tree "$PROJECT_DIR/packages" "$BUILD_DIR/packages" "packages"
sync_tree "$PROJECT_DIR/userpatches" "$BUILD_DIR/userpatches" "userpatches"
# Also accept conventional top-level Armbian config/patch trees if the project
# adds them later; the patches/ trees above remain the current source layout.
sync_tree "$PROJECT_DIR/config" "$BUILD_DIR/config" "config"
sync_tree "$PROJECT_DIR/patch" "$BUILD_DIR/patch" "patch"

# Remove only the known obsolete H96 Max AIC8801 Wi-Fi overlay left by earlier
# local syncs. Armbian's Docker build can leave cache files owned by root, so
# first try normal rm and then escalate only the exact stale path via sudo.
# Never chown or recursively chmod the kernel cache.
remove_stale_file() {
    local stale_file="$1"

    [[ -e "$stale_file" || -L "$stale_file" ]] || return 0

    if rm -f -- "$stale_file" 2>/dev/null; then
        return 0
    fi

    printf '[INFO] Normal removal was denied; retrying this exact stale file with sudo.\n' >&2
    if command -v sudo >/dev/null 2>&1 && sudo rm -f -- "$stale_file"; then
        return 0
    fi

    printf '\n[DIAGNOSTIC] Could not remove: %s\n' "$stale_file" >&2
    ls -ld -- "$(dirname -- "$stale_file")" 2>&1 || true
    stat -c 'File: %n | owner=%U:%G | mode=%A' -- "$stale_file" 2>&1 || true
    if command -v lsattr >/dev/null 2>&1; then
        lsattr -- "$stale_file" 2>&1 || true
    fi
    fail "Could not remove the obsolete AIC DTS artifact. Check for an immutable attribute or filesystem restriction; do not recursively change permissions."
}

LEGACY_AIC_DTS='rk3528-h96max-stock-rails-net-hdmi-wifi.dts'
LEGACY_REL="patch/kernel/rk35xx-vendor-6.1/dt/$LEGACY_AIC_DTS"
if [[ ! -f "$PATCHES_DIR/$LEGACY_REL" ]]; then
    LEGACY_PATCH_COPY="$BUILD_DIR/$LEGACY_REL"
    if [[ -e "$LEGACY_PATCH_COPY" || -L "$LEGACY_PATCH_COPY" ]]; then
        printf '\n[REMOVE] Obsolete project-owned AIC Wi-Fi DTS: %s\n' "$LEGACY_PATCH_COPY"
        remove_stale_file "$LEGACY_PATCH_COPY"
    fi

    KERNEL_DTS_DIR="$BUILD_DIR/cache/sources/linux-kernel-worktree/6.1__rk35xx__arm64/arch/arm64/boot/dts/rockchip"
    for stale_file in \
        "$KERNEL_DTS_DIR/$LEGACY_AIC_DTS" \
        "$KERNEL_DTS_DIR/${LEGACY_AIC_DTS%.dts}.dtb" \
        "$KERNEL_DTS_DIR/.${LEGACY_AIC_DTS%.dts}.dtb.cmd"; do
        if [[ -e "$stale_file" || -L "$stale_file" ]]; then
            printf '[REMOVE] Obsolete generated/source AIC DTS artifact: %s\n' "$stale_file"
            remove_stale_file "$stale_file"
        fi
    done
fi

# Assert that the critical EA6521QF inputs reached the build tree.
[[ -f "$BUILD_DIR/config/boards/rk3528-h96max.csc" ]] || fail "H96 Max board config was not synchronized."
[[ -f "$BUILD_DIR/extensions/ea6x21q-dkms/ea6x21q-dkms.sh" ]] || fail "EA6521QF extension was not synchronized."
[[ -f "$BUILD_DIR/patch/kernel/rk35xx-vendor-6.1/dt/rk3528-h96max-stock-rails-net-hdmi-seekwave.dts" ]] || fail "EA6521QF SeekWave DTS was not synchronized."
[[ -f "$PROJECT_DIR/extensions/ea6x21q-dkms/firmware/EA6521QF_SEEKWAVE_R00005.bin" ]] || fail "EA6521QF calibration firmware is missing from the project."

printf '\n\n========== PROJECT INPUT SYNCHRONIZATION COMPLETE ==========' 
printf '\nVerified: board config, SeekWave DTS, DKMS extension and EA6521QF firmware source.\n'

# A full Armbian image build attaches raw image files through loop devices.
# Test a real host attach/detach (not just `losetup --find`, which only reports
# a candidate). Docker access is tested separately with docker-shell before the
# next long image build; a host test alone cannot prove container access.
check_loop_devices() {
    local test_image free_loop loop_size
    command -v losetup >/dev/null 2>&1 || fail "losetup is required (util-linux)."
    command -v blockdev >/dev/null 2>&1 || fail "blockdev is required (util-linux)."
    command -v sudo >/dev/null 2>&1 || fail "sudo is required for the host loop-device test."

    if [[ ! -c /dev/loop-control ]]; then
        fail "Host /dev/loop-control is missing. Try: sudo modprobe loop; sudo udevadm trigger --subsystem-match=block; sudo udevadm settle"
    fi

    sudo modprobe loop || fail "Could not load the host loop module."
    sudo udevadm trigger --subsystem-match=block 2>/dev/null || true
    sudo udevadm settle 2>/dev/null || true

    test_image="$(mktemp "${TMPDIR:-/tmp}/h96-loop-test.XXXXXX")"
    truncate -s 32M "$test_image" || { rm -f -- "$test_image"; fail "Could not create the temporary loop-test image."; }

    if ! free_loop="$(sudo losetup --find --show --partscan "$test_image" 2>&1)"; then
        rm -f -- "$test_image"
        printf '\n[HOST LOOP ATTACH FAILED]\n%s\n' "$free_loop" >&2
        fail "Host could not attach a temporary image to a loop device. Check sudo modprobe loop; sudo udevadm trigger --subsystem-match=block; sudo udevadm settle; ls -l /dev/loop*"
    fi

    if [[ ! -b "$free_loop" ]]; then
        sudo losetup -d "$free_loop" >/dev/null 2>&1 || true
        rm -f -- "$test_image"
        fail "losetup attached $test_image but $free_loop is not a block device."
    fi

    if ! loop_size="$(sudo blockdev --getsize64 "$free_loop" 2>&1)"; then
        sudo losetup -d "$free_loop" >/dev/null 2>&1 || true
        rm -f -- "$test_image"
        fail "The host loop device $free_loop was attached but blockdev could not read its size: $loop_size"
    fi

    if ! sudo losetup -d "$free_loop"; then
        rm -f -- "$test_image"
        fail "Host attached $free_loop but could not detach it; inspect with sudo losetup -a."
    fi
    rm -f -- "$test_image"

    printf '\n[OK] Host loop attach/read/detach test passed: %s (%s bytes).\n' "$free_loop" "$loop_size"
    printf '[NOT YET VERIFIED] Docker loop access must pass the docker-shell test before the full build.\n'
}

cd "$BUILD_DIR"

if [[ "$MODE" == "dtb" ]]; then
    printf '\nStarting DTB-only kernel build (no root filesystem/image build)...\n\n'
    ./compile.sh kernel \
        BOARD=rk3528-h96max \
        BRANCH=vendor \
        RELEASE=trixie \
        KERNEL_CONFIGURE=no \
        KERNEL_GIT=shallow \
        KERNEL_DTB_ONLY=yes

    printf '\n============================================================\n'
    printf ' DTB-ONLY BUILD COMPLETED SUCCESSFULLY\n'
    printf '============================================================\n'
    printf 'Packages: %s/output/debs\n' "$BUILD_DIR"
    printf 'No full .img was created, so SD-card image flashing is skipped.\n'
    exit 0
fi

check_loop_devices

# Marker lets us distinguish the image created by THIS build from an older
# image that may already be in output/images.
IMAGE_DIR="$BUILD_DIR/output/images"
mkdir -p "$IMAGE_DIR"
BUILD_MARKER="$(mktemp "${TMPDIR:-/tmp}/h96-build-start.XXXXXX")"
trap 'rm -f -- "$BUILD_MARKER"' EXIT
touch "$BUILD_MARKER"

printf '\n========== BUILD CONFIGURATION ==========' 
printf '\nBoard: rk3528-h96max\nKernel: vendor 6.1\nRelease: trixie\n'
printf 'BUILD_DESKTOP=%s\nBUILD_MINIMAL=%s\n' "$BUILD_DESKTOP" "$BUILD_MINIMAL"
if [[ "$BUILD_DESKTOP" == yes ]]; then
    printf 'DESKTOP_ENVIRONMENT=%s\nDESKTOP_TIER=%s\n' "$DESKTOP_ENVIRONMENT" "$DESKTOP_TIER"
fi

BUILD_ARGS=(
    BOARD=rk3528-h96max
    BRANCH=vendor
    # Make the image-assembly requirements explicit rather than relying on
    # whatever defaults happen to be in the local Armbian config.
    PREFER_DOCKER=yes
    DOCKER_PRIVILEGED=yes
    BUILD_DESKTOP="$BUILD_DESKTOP"
    BUILD_MINIMAL="$BUILD_MINIMAL"
    RELEASE=trixie
    KERNEL_CONFIGURE=no
    KERNEL_GIT=shallow
)
if [[ "$BUILD_DESKTOP" == yes ]]; then
    BUILD_ARGS+=("DESKTOP_ENVIRONMENT=$DESKTOP_ENVIRONMENT" "DESKTOP_TIER=$DESKTOP_TIER")
fi

printf '\nStarting full Armbian image build...\n\n'
./compile.sh build "${BUILD_ARGS[@]}"

printf '\n============================================================\n'
printf ' FULL BUILD COMPLETED SUCCESSFULLY\n'
printf '============================================================\n'
printf 'Images: %s\n' "$IMAGE_DIR"

# Find an .img whose modification time is newer than the marker created above.
mapfile -d '' -t NEW_IMAGES < <(
    find "$IMAGE_DIR" -maxdepth 1 -type f -name '*.img' -newer "$BUILD_MARKER" -print0
)

if [[ "${#NEW_IMAGES[@]}" -eq 0 ]]; then
    printf '\n[WARNING] Build succeeded, but no newly-created .img was found in:\n  %s\n' "$IMAGE_DIR"
    printf 'Not offering to flash an older image, to avoid writing a stale build.\n'
    exit 0
fi

# Normally Armbian creates one image. If there are several, select the newest
# without a head(1) pipeline (avoids SIGPIPE with pipefail enabled).
IMAGE_PATH=""
if [[ "${#NEW_IMAGES[@]}" -eq 1 ]]; then
    IMAGE_PATH="${NEW_IMAGES[0]}"
else
    newest_mtime=-1
    for candidate in "${NEW_IMAGES[@]}"; do
        candidate_mtime="$(stat -c '%Y' -- "$candidate")"
        if (( candidate_mtime > newest_mtime )); then
            newest_mtime="$candidate_mtime"
            IMAGE_PATH="$candidate"
        fi
    done
fi

[[ -n "$IMAGE_PATH" && -f "$IMAGE_PATH" ]] || fail "Could not identify the newly-built image."
IMAGE_BYTES="$(stat -c '%s' -- "$IMAGE_PATH")"

printf '\nNew image: %s\n' "$IMAGE_PATH"
printf 'Image size: %s bytes\n' "$IMAGE_BYTES"

if [[ ! -t 0 ]]; then
    printf '\nNon-interactive session detected; skipping optional SD-card flash.\n'
    exit 0
fi

printf '\n============================================================\n'
printf ' OPTIONAL SD-CARD INSTALLATION\n'
printf '============================================================\n'
read -r -p 'Do you want to write this image to an SD card now? [y/N]: ' FLASH_ANSWER
case "$FLASH_ANSWER" in
    y|Y|yes|YES|Yes) ;;
    *) printf 'Skipping SD-card flashing. Build image is preserved at:\n  %s\n' "$IMAGE_PATH"; exit 0 ;;
esac

# Show whole /dev/sdX disks only (never partitions), and exclude card readers
# that are present as USB devices but have no medium inserted (SIZE=0).
# A block-device node alone is not proof that media is present: blockdev on an
# empty reader returns ENOMEDIUM, as happened with /dev/sdc.
mapfile -t SD_DISKS < <(
    lsblk -bdnpo NAME,TYPE,SIZE | awk \
        '$2 == "disk" && $1 ~ /^\/dev\/sd[a-z]+$/ && $3 ~ /^[0-9]+$/ && $3 > 0 { print $1 }'
)

if [[ "${#SD_DISKS[@]}" -eq 0 ]]; then
    printf '\n[WARNING] No media-present whole-disk /dev/sdX devices were found.\n'
    printf 'Insert the SD card into its reader, wait a moment, then rerun this script.\n'
    printf 'Empty readers (0 bytes / no medium) are deliberately excluded.\n'
    exit 0
fi

printf '\nDetected whole-disk /dev/sdX devices:\n'
printf ' No.  DEVICE       SIZE      MODEL / TRANSPORT / REMOVABLE\n'
printf '%s\n' '--------------------------------------------------------------------------'
for i in "${!SD_DISKS[@]}"; do
    disk="${SD_DISKS[$i]}"
    printf ' [%d] ' "$((i + 1))"
    lsblk -dnpo NAME,SIZE,MODEL,TRAN,RM "$disk"
done

printf '\nChoose the number corresponding to your SD card reader/device.\n'
read -r -p 'Device number (Enter to cancel): ' DEVICE_CHOICE
if [[ -z "$DEVICE_CHOICE" ]]; then
    printf 'Cancelled. No device was modified.\n'
    exit 0
fi
if [[ ! "$DEVICE_CHOICE" =~ ^[0-9]+$ ]] || (( DEVICE_CHOICE < 1 || DEVICE_CHOICE > ${#SD_DISKS[@]} )); then
    printf '[WARNING] Invalid selection. No device was modified.\n'
    exit 0
fi

TARGET_DISK="${SD_DISKS[$((DEVICE_CHOICE - 1))]}"
[[ -b "$TARGET_DISK" ]] || fail "Selected target is no longer a block device: $TARGET_DISK"

printf '\nSelected device and its partitions:\n'
lsblk -o NAME,PATH,SIZE,MODEL,TRAN,TYPE,FSTYPE,LABEL,MOUNTPOINTS "$TARGET_DISK"

# Protect physical devices backing the root filesystem and the project/build
# directories, so the script cannot overwrite the running OS or its own inputs.
declare -A PROTECTED_DISKS=()
protect_mount_backing_devices() {
    local mountpoint="$1"
    local source node
    source="$(findmnt -nro SOURCE --target "$mountpoint" 2>/dev/null || true)"
    [[ -n "$source" ]] || return 0
    source="${source%%\[*}"
    [[ -b "$source" ]] || return 0
    while IFS= read -r node; do
        [[ -n "$node" ]] && PROTECTED_DISKS["$node"]=1
    done < <(lsblk -s -nrpo NAME "$source" 2>/dev/null || true)
}

for protected_mount in / /boot /boot/efi "$PROJECT_DIR" "$BUILD_DIR"; do
    protect_mount_backing_devices "$protected_mount"
done

if [[ -n "${PROTECTED_DISKS[$TARGET_DISK]+x}" ]]; then
    printf '\n[ABORTED] %s contains a filesystem backing the running OS or this project/build.\n' "$TARGET_DISK"
    printf 'Choose the actual SD-card device instead. Nothing was written.\n'
    exit 0
fi

# Recheck media presence after selection. Readers can remain as /dev/sdX even
# when no card is inserted; blockdev then fails with "No medium found".
if ! TARGET_BYTES="$(sudo blockdev --getsize64 "$TARGET_DISK" 2>&1)"; then
    printf '\n[ABORTED] Cannot access media in %s: %s\n' "$TARGET_DISK" "$TARGET_BYTES"
    printf 'No data was written. Insert the SD card and run the flash step again.\n'
    exit 0
fi
if [[ ! "$TARGET_BYTES" =~ ^[0-9]+$ ]] || (( TARGET_BYTES == 0 )); then
    printf '\n[ABORTED] %s reports no usable media (capacity: %s). No data was written.\n' \
        "$TARGET_DISK" "$TARGET_BYTES"
    exit 0
fi
if (( TARGET_BYTES < IMAGE_BYTES )); then
    printf '\n[ABORTED] Target is too small: %s bytes available; image needs %s bytes.\n' \
        "$TARGET_BYTES" "$IMAGE_BYTES"
    exit 0
fi

printf '\n============================================================\n'
printf ' DANGER: THIS WILL ERASE EVERYTHING ON %s\n' "$TARGET_DISK"
printf 'Image:  %s\n' "$IMAGE_PATH"
printf 'Target: %s (%s bytes)\n' "$TARGET_DISK" "$TARGET_BYTES"
printf '============================================================\n'
printf 'To confirm, type the complete device path exactly.\n'
read -r -p "Type ${TARGET_DISK} to start writing (anything else cancels): " FINAL_CONFIRM
if [[ "$FINAL_CONFIRM" != "$TARGET_DISK" ]]; then
    printf 'Cancelled. No device was modified.\n'
    exit 0
fi

sudo -v

printf '\nUnmounting any mounted partitions on %s...\n' "$TARGET_DISK"
mapfile -t TARGET_NODES < <(lsblk -lnpo NAME "$TARGET_DISK")
for node in "${TARGET_NODES[@]:1}"; do
    while IFS= read -r mountpoint; do
        [[ -n "$mountpoint" ]] || continue
        printf '  umount %s\n' "$mountpoint"
        sudo umount -- "$mountpoint"
    done < <(findmnt -rn -S "$node" -o TARGET 2>/dev/null || true)
done

# Final capacity check immediately before dd, in case the card was removed
# or the reader changed state while the confirmation prompt was displayed.
if ! CURRENT_TARGET_BYTES="$(sudo blockdev --getsize64 "$TARGET_DISK" 2>&1)" || \
   [[ ! "$CURRENT_TARGET_BYTES" =~ ^[0-9]+$ ]] || \
   (( CURRENT_TARGET_BYTES < IMAGE_BYTES )) || \
   [[ "$CURRENT_TARGET_BYTES" != "$TARGET_BYTES" ]]; then
    printf '\n[ABORTED] Target media disappeared or its capacity changed.\n'
    printf 'Previously detected: %s bytes; now: %s\n' "$TARGET_BYTES" "${CURRENT_TARGET_BYTES:-unavailable}"
    printf 'No dd command was started.\n'
    exit 0
fi

printf '\n========== FLASHING IMAGE TO %s ==========\n' "$TARGET_DISK"
printf 'This can take a few minutes. dd progress is shown below.\n\n'
sudo dd if="$IMAGE_PATH" of="$TARGET_DISK" bs=4M status=progress conv=fsync
sudo blockdev --flushbufs "$TARGET_DISK"
sync

printf '\n============================================================\n'
printf ' FLASH COMPLETED SUCCESSFULLY\n'
printf '============================================================\n'
lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$TARGET_DISK"
printf '\nYou can now safely remove the SD card and boot the H96 Max.\n'
printf 'Image file remains available at:\n  %s\n' "$IMAGE_PATH"
