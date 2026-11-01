# @description Installs the SeekWave EA6521QF SDIO Wi-Fi/BT driver using DKMS.
# Driver source is pinned; EA6521QF calibration data is carried by this extension.

function extension_finish_config__ea6x21q_require_kernel_headers() {
    if [[ "${KERNEL_HAS_WORKING_HEADERS:-no}" != "yes" ]]; then
        display_alert "EA6521QF driver requires working kernel headers" \
            "KERNEL_HAS_WORKING_HEADERS=${KERNEL_HAS_WORKING_HEADERS:-unset}; cannot build DKMS modules" "error"
        exit 1
    fi
    declare -g INSTALL_HEADERS="yes"
    display_alert "Enabling kernel headers for EA6521QF DKMS" "INSTALL_HEADERS=yes" "info"
}

function post_install_kernel_debs__install_ea6x21q_dkms() {
    local ext_dir="${EXTENSION_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)}"
    local commit="b193d8b41e42f4ccf2cb23302ce2e3c940ad2415"
    local dkms_name="ea6621q"
    local dkms_version="1.0"
    local cache_root="${SRC}/cache/ea6x21q"
    local archive="${cache_root}/ea6x21-dkms-${commit}.tar.gz"
    local source_dir="${cache_root}/source-${commit}"
    local stage_dir="${SDCARD}/usr/src/ea6621q-1.0"
    local kernel_version
    local -a installed_kernels=()

    [[ -f "${ext_dir}/firmware/EA6521QF_SEEKWAVE_R00005.bin" ]] || {
        display_alert "Missing EA6521QF calibration firmware" "${ext_dir}/firmware" "error"
        exit 1
    }

    mkdir -p "${cache_root}"
    if [[ ! -f "${archive}" ]]; then
        display_alert "Downloading pinned SeekWave driver source" "${commit}" "info"
        run_host_command_logged curl -fL --retry 3 \
            "https://github.com/joilg/ea6x21-dkms/archive/${commit}.tar.gz" \
            -o "${archive}.tmp"
        mv -f "${archive}.tmp" "${archive}"
    fi

    if [[ ! -f "${source_dir}/dkms.conf" ]]; then
        rm -rf "${source_dir}.tmp"
        mkdir -p "${source_dir}.tmp"
        tar -xzf "${archive}" -C "${source_dir}.tmp" --strip-components=2
        [[ -f "${source_dir}.tmp/dkms.conf" && -f "${source_dir}.tmp/Makefile" ]] || {
            display_alert "Unexpected SeekWave source archive layout" "${archive}" "error"
            exit 1
        }
        mv "${source_dir}.tmp" "${source_dir}"
    fi

    mapfile -t installed_kernels < <(
        find "${SDCARD}/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
    )
    if [[ "${#installed_kernels[@]}" -ne 1 ]]; then
        display_alert "Expected exactly one installed kernel for EA6521QF DKMS" \
            "found: ${#installed_kernels[@]} (${installed_kernels[*]:-none})" "error"
        exit 1
    fi
    kernel_version="${installed_kernels[0]}"

    rm -rf "${stage_dir}"
    install -d "${stage_dir}"
    cp -a "${source_dir}/." "${stage_dir}/"

    # Use the EA6521QF calibration name. Do not ship the unrelated EA6621Q blob.
    sed -i 's/EA6621Q_SEEKWAVE_R00005\.bin/EA6521QF_SEEKWAVE_R00005.bin/g' \
        "${stage_dir}/Makefile"
    # This board uses SDIO; do not build/install the unused USB transport.
    sed -i '/^export CONFIG_SKW_USB:=m$/d' "${stage_dir}/Makefile"
    # The image is ARM64. Make DKMS explicit so the host's uname cannot select x86.
    sed -i 's/ -C \$kernel_source_dir M=/ -C \$kernel_source_dir ARCH=arm64 M=/g' \
        "${stage_dir}/dkms.conf"

    install -m 0644 "${ext_dir}/firmware/EA6521QF_SEEKWAVE_R00005.bin" \
        "${SDCARD}/lib/firmware/EA6521QF_SEEKWAVE_R00005.bin"
    for fw in RAM_RW_KERNEL_DRAM.bin ROM_EXEC_KERNEL_IRAM.bin sv6160.nvbin sv6160lite.nvbin sv6316.nvbin; do
        [[ -f "${source_dir}/firmware/${fw}" ]] || {
            display_alert "Required SeekWave firmware missing" "${fw}" "error"
            exit 1
        }
        install -m 0644 "${source_dir}/firmware/${fw}" "${SDCARD}/lib/firmware/${fw}"
    done

    install -d "${SDCARD}/etc/modules-load.d"
    cat > "${SDCARD}/etc/modules-load.d/ea6x21q.conf" <<'MODULES'
# SeekWave EA6521QF SDIO transport, boot/service layer, Wi-Fi and Bluetooth.
skw_sdio
skw_bootcoms
skw
skwbt
MODULES

    display_alert "Installing DKMS build dependency" "dkms (kernel ${kernel_version})" "info"
    chroot_sdcard_apt_get_install "dkms"

    declare -ag if_error_find_files_sdcard=("/var/lib/dkms/ea6621q*/*/build/*.log")
    display_alert "Building SeekWave modules in image chroot" "${dkms_name} ${dkms_version} / ${kernel_version}" "info"
    use_clean_environment="yes" chroot_sdcard \
        "dkms add -m ${dkms_name} -v ${dkms_version}"
    use_clean_environment="yes" chroot_sdcard \
        "dkms build -m ${dkms_name} -v ${dkms_version} -k ${kernel_version}"
    use_clean_environment="yes" chroot_sdcard \
        "dkms install -m ${dkms_name} -v ${dkms_version} -k ${kernel_version}"
    use_clean_environment="yes" chroot_sdcard "depmod -a ${kernel_version}"

    display_alert "SeekWave EA6521QF modules installed into image" "${kernel_version}" "info"
}
