#!/usr/bin/env bash
set -euo pipefail

# ==================== 全局配置 ====================
readonly SCRIPT_NAME="$(basename "$0")"
readonly WRT_CORE_DIR="${WRT_CORE_DIR:-wrt_core}"          # 可由外部指定
readonly FIRMWARE_OUTPUT_DIR="${FIRMWARE_OUTPUT_DIR:-firmware}"
readonly DEFAULT_BUILD_MODE="normal"

# ==================== 路径检测 ====================
detect_wrt_core() {
    if [[ -d "$WRT_CORE_DIR" ]]; then
        echo "$WRT_CORE_DIR"
    elif [[ -d "../wrt_core" ]]; then
        echo "../wrt_core"
    else
        echo "ERROR: wrt_core directory not found!" >&2
        exit 1
    fi
}

# ==================== 设备列表 ====================
declare -a SUPPORTED_DEVS=()
load_supported_devs() {
    local base_path="$1"
    SUPPORTED_DEVS=()
    for ini in "$base_path"/compilecfg/*.ini; do
        [[ -f "$ini" ]] || continue
        local dev_key
        dev_key="$(basename "$ini" .ini)"
        if [[ -f "$base_path/deconfig/$dev_key.config" ]]; then
            SUPPORTED_DEVS+=("$dev_key")
        fi
    done
    # 排序
    if [[ ${#SUPPORTED_DEVS[@]} -gt 0 ]]; then
        mapfile -t SUPPORTED_DEVS < <(printf '%s\n' "${SUPPORTED_DEVS[@]}" | LC_ALL=C sort)
    fi
}

# ==================== 交互选择 ====================
interactive_select_dev() {
    local dev
    PS3="Select device by number (or 'q' to quit): "
    select dev in "${SUPPORTED_DEVS[@]}" "Quit"; do
        case "$dev" in
            Quit) echo "Cancelled."; exit 1 ;;
            "") echo "Invalid selection. Try again." ;;
            *) echo "$dev"; return 0 ;;
        esac
    done
}

interactive_select_mode() {
    local mode
    PS3="Select build mode (normal/debug): "
    select mode in "normal" "debug"; do
        case "$mode" in
            normal) echo ""; return 0 ;;
            debug)  echo "debug"; return 0 ;;
            *) echo "Invalid selection. Try again." ;;
        esac
    done
}

# ==================== 配置读取 ====================
read_ini_value() {
    local key="$1"
    local ini_file="$2"
    awk -F"=" -v key="$key" '$1 == key {print $2}' "$ini_file"
}

# ==================== 主构建函数 ====================
main() {
    # ---- 1. 解析参数 / 交互 ----
    local DEVICE="${1:-}"
    local BUILD_MODE="${2:-}"

    local base_path
    base_path="$(cd "$(detect_wrt_core)" && pwd)"
    load_supported_devs "$base_path"

    if [[ -z "$DEVICE" ]]; then
        if [[ ${#SUPPORTED_DEVS[@]} -eq 0 ]]; then
            echo "ERROR: No supported devices found." >&2
            exit 1
        fi
        if [[ ! -t 0 || ! -t 1 ]]; then
            echo "Usage: $0 <device> [debug]" >&2
            echo "Supported devices:" >&2
            printf '  %s\n' "${SUPPORTED_DEVS[@]}" >&2
            exit 1
        fi
        DEVICE="$(interactive_select_dev)"
        if [[ -z "$BUILD_MODE" ]]; then
            BUILD_MODE="$(interactive_select_mode)"
        fi
    fi

    # 校验设备
    local found=0
    for d in "${SUPPORTED_DEVS[@]}"; do
        if [[ "$d" == "$DEVICE" ]]; then
            found=1
            break
        fi
    done
    if [[ $found -eq 0 ]]; then
        echo "ERROR: Device '$DEVICE' not supported." >&2
        exit 1
    fi

    # ---- 2. 加载设备配置 ----
    local config_file="$base_path/deconfig/$DEVICE.config"
    local ini_file="$base_path/compilecfg/$DEVICE.ini"
    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Config not found: $config_file" >&2
        exit 1
    fi
    if [[ ! -f "$ini_file" ]]; then
        echo "ERROR: INI file not found: $ini_file" >&2
        exit 1
    fi

    # 读取关键配置
    local repo_url build_dir commit_hash repo_branch
    repo_url="$(read_ini_value "REPO_URL" "$ini_file")"
    repo_branch="$(read_ini_value "REPO_BRANCH" "$ini_file")"
    repo_branch="${repo_branch:-main}"
    build_dir="$(read_ini_value "BUILD_DIR" "$ini_file")"
    commit_hash="$(read_ini_value "COMMIT_HASH" "$ini_file")"
    commit_hash="${commit_hash:-none}"

    # 若存在 action_build，覆盖 build_dir
    if [[ -d "action_build" ]]; then
        build_dir="action_build"
    fi

    # 全局构建根目录
    local build_root="$base_path/../$build_dir"
    # 构建日期（从环境变量获取，若无则生成）
    local build_date="${BUILD_DATE:-$(TZ=UTC-8 date +"%y.%m.%d_%H.%M.%S")}"
    local version_number="${build_date}"

    # ---- 3. 更新源码 ----
    echo ">>> Updating source from $repo_url (branch $repo_branch)..."
    "$base_path/update.sh" "$repo_url" "$repo_branch" "$build_dir" "$commit_hash"

    # ---- 4. 应用自定义配置 ----
    apply_custom_config \
        "$base_path" \
        "$build_root" \
        "$config_file" \
        "$DEVICE" \
        "$build_date" \
        "$version_number"

    # ---- 5. 集成额外软件包 ----
    integrate_extra_packages "$build_root"

    # ---- 6. 编译固件 ----
    if [[ "$BUILD_MODE" == "debug" ]]; then
        echo ">>> Debug mode: skipping build."
        exit 0
    fi

    build_firmware "$base_path" "$build_root" "$config_file" "$version_number" "$DEVICE"

    # ---- 7. 收集输出 ----
    collect_firmware "$base_path" "$build_root"

    # ---- 8. 清理（如 action_build） ----
    if [[ -d "action_build" ]]; then
        (cd "$build_root" && make clean) || true
    fi

    echo ">>> Build completed successfully."
}

# ==================== 自定义配置应用 ====================
apply_custom_config() {
    local base_path="$1"
    local build_root="$2"
    local config_file="$3"
    local device="$4"
    local build_date="$5"
    local version_number="$6"

    echo ">>> Applying custom configuration for $device..."

    # 1. 复制基础配置
    cp -f "$config_file" "$build_root/.config"

    # 2. 若为 IPQ60xx/IPQ807x 且未启用 Git 镜像，追加 NSS 配置
    if grep -qE "(ipq60xx|ipq807x)" "$build_root/.config" && \
       ! grep -q "CONFIG_GIT_MIRROR" "$build_root/.config"; then
        cat "$base_path/deconfig/nss.config" >> "$build_root/.config"
    fi

    # 3. 追加公共编译基础配置、Docker 依赖、代理配置
    cat "$base_path/deconfig/compile_base.config" \
        "$base_path/deconfig/docker_deps.config" \
        "$base_path/deconfig/proxy.config" >> "$build_root/.config" 2>/dev/null || true

    # 4. 创建 uci-defaults 自定义设置（IP、WiFi、密码等）
    setup_uci_defaults "$build_root"

    # 5. 修改 default-settings 中的构建者信息
    setup_build_info "$build_root" "$version_number"

    # 6. 配置 athena_led
    setup_athena_led "$build_root"

    # 7. 更新 banner
    setup_banner "$build_root"

    # 8. 配置 crontab（定时开关灯）
    setup_cron "$build_root"

    # 9. 配置按键功能（WPS、BTN_1）
    setup_button_handlers "$build_root"

    # 10. 配置 eMMC 数据分区自动格式化与挂载
    setup_data_partition "$build_root"

    # 11. 复制 status.cgi
    copy_status_cgi "$base_path" "$build_root"

    # 12. 添加 feeds 源
    echo 'src-git netem https://github.com/Connectify/openwrt-netem' >> "$build_root/feeds.conf.default"
    echo 'src-git bandix https://github.com/timsaya/luci-app-bandix-plus.git' >> "$build_root/feeds.conf.default"

    echo ">>> Custom configuration applied."
}

# ------------------ 辅助函数（各配置项） ------------------
setup_uci_defaults() {
    local build_root="$1"
    local uci_dir="$build_root/files/etc/uci-defaults"
    mkdir -p "$uci_dir"
    cat > "$uci_dir/99-custom-settings" << 'EOF'
#!/bin/sh
uci set system.@system[0].hostname='Kinsum'
uci commit system
/etc/init.d/system restart

uci set network.lan.proto='static'
uci set network.lan.ipaddr='192.168.188.1'
uci set network.lan.netmask='255.255.255.0'
uci commit network
/etc/init.d/network restart

uci set dhcp.lan.start='100'
uci set dhcp.lan.limit='150'
uci set dhcp.lan.leasetime='12h'
uci set dhcp.lan.ignore='0'
uci commit dhcp
/etc/init.d/dnsmasq restart

uci set wireless.radio0.disabled='0'
uci set wireless.@wifi-iface[0].ssid='Titok'
uci set wireless.@wifi-iface[0].key='yunding888'
uci set wireless.@wifi-iface[0].encryption='psk2'

if uci get wireless.radio1 >/dev/null 2>&1; then
    uci set wireless.radio1.disabled='0'
    uci set wireless.@wifi-iface[1].ssid='Titok_5G'
    uci set wireless.@wifi-iface[1].key='yunding888'
    uci set wireless.@wifi-iface[1].encryption='psk2'
fi
uci commit wireless
wifi

echo "root:erlang" | chpasswd

rm -f /etc/uci-defaults/99-custom-settings
EOF
    chmod +x "$uci_dir/99-custom-settings"
}

setup_build_info() {
    local build_root="$1"
    local version_number="$2"
    local maker="Kinsum@$version_number"
    local makefiles=(
        "$build_root/package/emortal/default-settings/Makefile"
        "$build_root/package/immortalwrt/default-settings/Makefile"
        "$build_root/feeds/emortal/default-settings/Makefile"
        "$build_root/feeds/immortalwrt/default-settings/Makefile"
    )
    for mk in "${makefiles[@]}"; do
        if [[ -f "$mk" ]]; then
            sed -i "s/ZqinKing/$maker/g" "$mk"
            echo "✅ Updated $mk"
        fi
    done
}

setup_athena_led() {
    local build_root="$1"
    local cfg_dir="$build_root/files/etc/config"
    mkdir -p "$cfg_dir"
    cat > "$cfg_dir/athena_led" << 'EOF'
config athena_led 'config'
    option enable '1'
    option value 'Kinsum love you!'
    option seconds '5'
    option status 'time'
    option lightLevel '2'
    option tempFlag '4'
EOF
}

setup_banner() {
    local build_root="$1"
    local banner_file="$build_root/package/base-files/files/etc/banner"
    mkdir -p "$(dirname "$banner_file")"
    cat > "$banner_file" << EOF
--------------
Welcome to...
--------------

,--.    ,--.                                  
|  |,-. `--',--,--,  ,---. ,--.,--.,--,--,--. 
|     / ,--.|      \(  .-' |  ||  ||        | 
|  \  \ |  ||  ||  |.-'  `)'  ''  '|  |  |  | 
`--'`--'`--'`--''--'`----'  `----' `--`--`--'                                              
                                                                                                                    
-----------------------------------------------------
  Firmware compiled by Kinsum @ $(date '+%Y-%m-%d ')
-----------------------------------------------------
EOF
}

setup_cron() {
    local build_root="$1"
    local cron_dir="$build_root/files/etc/crontabs"
    mkdir -p "$cron_dir"
    cat > "$cron_dir/root" << "EOF"
0 23 * * * uci set athena_led.config.enable='0' && uci commit athena_led && /etc/init.d/athena_led reload
0 7 * * * uci set athena_led.config.enable='3' && uci commit athena_led && /etc/init.d/athena_led reload
EOF
}

setup_button_handlers() {
    local build_root="$1"
    local files_dir="$build_root/files"

    # 脚本：切换 RGB
    cat > "$files_dir/etc/rgb_toggle.sh" << "EOF"
#!/bin/sh
CURRENT=$(uci get athena_led.config.enable 2>/dev/null)
[ -z "$CURRENT" ] && CURRENT=0
NEXT=$(( (CURRENT + 1) % 4 ))
uci set athena_led.config.enable="$NEXT"
uci commit athena_led
/etc/init.d/athena_led restart
logger -t "rgb_toggle" "RGB mode switched to $NEXT"
EOF
    chmod +x "$files_dir/etc/rgb_toggle.sh"

    # 脚本：切换屏幕显示
    cat > "$files_dir/etc/screen_toggle.sh" << "EOF"
#!/bin/sh
STATUS_LIST="time date weather network temp"
CURRENT=$(uci get athena_led.config.status 2>/dev/null)
[ -z "$CURRENT" ] && CURRENT="time"

INDEX=0
for s in $STATUS_LIST; do
    if [ "$s" = "$CURRENT" ]; then
        break
    fi
    INDEX=$((INDEX + 1))
done
NEXT_INDEX=$(( (INDEX + 1) % $(echo $STATUS_LIST | wc -w) ))
NEXT_STATUS=$(echo $STATUS_LIST | cut -d' ' -f$((NEXT_INDEX+1)))

uci set athena_led.config.status="$NEXT_STATUS"
uci commit athena_led
/etc/init.d/athena_led restart
logger -t "screen_toggle" "Screen display switched to $NEXT_STATUS"
EOF
    chmod +x "$files_dir/etc/screen_toggle.sh"

    # 热插拔事件
    local hotplug_dir="$files_dir/etc/hotplug.d/button"
    mkdir -p "$hotplug_dir"
    cat > "$hotplug_dir/01-custom-buttons" << "EOF"
#!/bin/sh
case "$ACTION" in
    pressed)
        LAST=$(cat /tmp/button_last_time 2>/dev/null)
        NOW=$(cut -d '.' -f 1 /proc/uptime)
        if [ -n "$LAST" ] && [ $((NOW - LAST)) -lt 1 ]; then
            exit 0
        fi
        echo "$NOW" > /tmp/button_last_time
        logger -t "button-handler" "Button pressed: $BUTTON"
        case "$BUTTON" in
            wps)   /etc/rgb_toggle.sh & ;;
            BTN_1) /etc/screen_toggle.sh & ;;
        esac
        ;;
esac
EOF
    chmod +x "$hotplug_dir/01-custom-buttons"
}

setup_data_partition() {
    local build_root="$1"
    local initd_dir="$build_root/files/etc/init.d"
    mkdir -p "$initd_dir"
    cat > "$initd_dir/format_data" << 'EOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10
MOUNT_POINT="/opt"
FS_TYPE="ext4"
STAMP="/etc/.data_formatted"

find_partition() {
    for p in /dev/mmcblk0p27 /dev/mmcblk0p28 /dev/mmcblk1p1; do
        [ -b "$p" ] && { echo "$p"; return 0; }
    done
    for p in /dev/mmcblk[0-9]p*; do
        [ -b "$p" ] || continue
        mount | grep -q "$p" && continue
        size=$(blockdev --getsz "$p" 2>/dev/null)
        [ -z "$size" ] && continue
        if [ "$size" -gt 2000000 ]; then
            echo "$p"; return 0
        fi
    done
    local last=$(ls /dev/mmcblk0p* 2>/dev/null | sort -V | tail -1)
    [ -n "$last" ] && echo "$last" && return 0
    return 1
}

start() {
    logger -t "format_data" "Starting data partition setup"
    PARTITION=$(find_partition)
    [ -z "$PARTITION" ] && { logger -t "format_data" "No suitable partition found"; return 1; }
    logger -t "format_data" "Using partition: $PARTITION"
    mount | grep -q "$PARTITION" && { logger -t "format_data" "Already mounted"; return 0; }
    FSTYPE=$(blkid -s TYPE -o value "$PARTITION" 2>/dev/null)
    if [ ! -f "$STAMP" ] && [ "$FSTYPE" != "$FS_TYPE" ]; then
        logger -t "format_data" "Formatting $PARTITION as $FS_TYPE"
        mkfs.ext4 -F "$PARTITION" >/dev/null 2>&1 || return 1
        touch "$STAMP"
    fi
    mkdir -p "$MOUNT_POINT"
    mount -t "$FS_TYPE" "$PARTITION" "$MOUNT_POINT" 2>/dev/null || {
        sleep 2
        mount -t "$FS_TYPE" "$PARTITION" "$MOUNT_POINT" 2>/dev/null || return 1
    }
    grep -q "$PARTITION" /etc/fstab || echo "$PARTITION $MOUNT_POINT $FS_TYPE defaults 0 0" >> /etc/fstab
    logger -t "format_data" "Mounted successfully"
}
EOF
    chmod +x "$initd_dir/format_data"
    local rc_dir="$build_root/files/etc/rc.d"
    mkdir -p "$rc_dir"
    ln -sf /etc/init.d/format_data "$rc_dir/S99format_data" 2>/dev/null || true
}

copy_status_cgi() {
    local base_path="$1"
    local build_root="$2"
    local src="$base_path/modules/status.cgi"
    if [[ -f "$src" ]]; then
        local dst_dir="$build_root/files/www/cgi-bin"
        mkdir -p "$dst_dir"
        cp -f "$src" "$dst_dir/"
        chmod +x "$dst_dir/status.cgi"
        echo "✅ status.cgi copied"
    else
        echo "⚠️ status.cgi not found, skip"
    fi
}

remove_uhttpd_dependency() {
    local build_root="$1"
    local config_path="$build_root/.config"
    local luci_makefile="$build_root/feeds/luci/collections/luci/Makefile"
    if grep -q "CONFIG_PACKAGE_luci-app-quickfile=y" "$config_path" && [[ -f "$luci_makefile" ]]; then
        sed -i '/luci-light/d' "$luci_makefile"
        echo "Removed uhttpd dependency due to quickfile (nginx)"
    fi
}

# ==================== 集成额外软件包（修复版） ====================
integrate_extra_packages() {
    local build_root="$1"
    echo ">>> Integrating rtp2httpd packages..."

    local tmp_dir=""
    tmp_dir="$(mktemp -d)" || {
        echo "ERROR: Failed to create temp directory" >&2
        return 1
    }
    # ✅ 修复：使用安全展开，避免 unbound variable
    trap 'rm -rf "${tmp_dir:-}"' RETURN

    git clone --depth=1 https://github.com/stackia/rtp2httpd.git "$tmp_dir" || {
        echo "ERROR: Failed to clone rtp2httpd" >&2
        return 1
    }

    local packages=("luci-app-rtp2httpd" "taskd" "luci-lib-taskd")
    for pkg in "${packages[@]}"; do
        if [[ -d "$tmp_dir/$pkg" ]]; then
            rm -rf "$build_root/package/$pkg"
            cp -r "$tmp_dir/$pkg" "$build_root/package/"
            echo "✅ Copied $pkg"
        else
            echo "⚠️ $pkg not found in repo, skip"
        fi
    done

    # 在 .config 中启用
    echo "CONFIG_PACKAGE_luci-app-rtp2httpd=y" >> "$build_root/.config"
    echo "CONFIG_PACKAGE_taskd=y" >> "$build_root/.config"
    echo "CONFIG_PACKAGE_luci-lib-taskd=y" >> "$build_root/.config"

    # （可选）集成 netem —— 注释掉，若需要可取消
    # ...
}

# ==================== 编译固件 ====================
build_firmware() {
    local base_path="$1"
    local build_root="$2"
    local config_file="$3"
    local version_number="$4"
    local device="$5"

    echo ">>> Building firmware for $device..."

    cd "$build_root"

    # 运行 defconfig
    make defconfig

    # 下载 OpenClash 内核（若有 diy-part.sh）
    if [[ -f "$(dirname "$0")/diy-part.sh" ]]; then
        (cd "$build_root" && "$(dirname "$0")/diy-part.sh")
    fi

    # 追加必要包
    cat >> .config << EOF
CONFIG_PACKAGE_e2fsprogs=y
CONFIG_PACKAGE_blkid=y
EOF

    # 强制写入版本信息
    cat >> .config << EOF
CONFIG_VERSION_DIST="KinWRT"
CONFIG_VERSION_MANUFACTURER="Kinsum@$version_number"
CONFIG_VERSION_NUMBER="$version_number"
EOF

    make oldconfig

    # 若目标是 x86_64，修改 distfeeds
    if grep -qE "^CONFIG_TARGET_x86_64=y" "$config_file"; then
        local distfeeds="$build_root/package/emortal/default-settings/files/99-distfeeds.conf"
        if [[ -f "$distfeeds" ]]; then
            sed -i 's/aarch64_cortex-a53/x86_64/g' "$distfeeds"
        fi
    fi

    # 移除 uhttpd 依赖（如果需要）
    remove_uhttpd_dependency "$build_root"

    # 清理旧固件（保留目录结构）
    local target_dir="$build_root/bin/targets"
    if [[ -d "$target_dir" ]]; then
        find "$target_dir" -type f \( -name "*.bin" -o -name "*.manifest" -o -name "*efi.img.gz" -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" -o -name "*rootfs.tar.gz" \) -exec rm -f {} +
    fi

    # 下载源码
    make download -j"$(nproc)"

    # 编译
    if ! make -j"$(nproc)"; then
        echo ">>> Build failed, retrying with V=s..." >&2
        make -j1 V=s || {
            echo ">>> Build failed again. Exiting." >&2
            exit 1
        }
    fi

    # 修正 openwrt_release
    local release_file
    release_file="$(find "$target_dir" -path "*/root-*/etc/openwrt_release" 2>/dev/null | head -1)"
    if [[ -f "$release_file" ]]; then
        sed -i "s/ZqinKing/Kinsum@$version_number/g" "$release_file"
        echo "✅ Updated openwrt_release"
    fi
}

# ==================== 收集固件 ====================
collect_firmware() {
    local base_path="$1"
    local build_root="$2"
    local target_dir="$build_root/bin/targets"
    local output_dir="$base_path/../$FIRMWARE_OUTPUT_DIR"

    rm -rf "$output_dir"
    mkdir -p "$output_dir"

    if [[ -d "$target_dir" ]]; then
        find "$target_dir" -type f \( -name "*.bin" -o -name "*.manifest" -o -name "*efi.img.gz" -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" -o -name "*rootfs.tar.gz" \) -exec cp -f {} "$output_dir/" \;
        echo ">>> Firmware copied to $output_dir"
    else
        echo "WARNING: No target directory found, firmware may not be generated." >&2
    fi

    rm -f "$output_dir/Packages.manifest" 2>/dev/null || true
}

# ==================== 入口 ====================
main "$@"
