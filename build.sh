#!/usr/bin/env bash

set -e

# Determine wrt_core path
if [ -d "wrt_core" ]; then
    WRT_CORE_PATH="wrt_core"
elif [ -d "../wrt_core" ]; then
    WRT_CORE_PATH="../wrt_core"
else
    echo "Error: wrt_core directory not found!"
    exit 1
fi

BASE_PATH=$(cd "$WRT_CORE_PATH" && pwd)

Dev=$1
Build_Mod=$2

SUPPORTED_DEVS=()

collect_supported_devs() {
    local ini_file
    local dev_key
    local IFS

    SUPPORTED_DEVS=()

    for ini_file in "$BASE_PATH"/compilecfg/*.ini; do
        [[ -f "$ini_file" ]] || continue

        dev_key=$(basename "$ini_file" .ini)
        if [[ -f "$BASE_PATH/deconfig/$dev_key.config" ]]; then
            SUPPORTED_DEVS+=("$dev_key")
        fi
    done

    if [[ ${#SUPPORTED_DEVS[@]} -eq 0 ]]; then
        return
    fi

    IFS=$'\n' SUPPORTED_DEVS=($(printf '%s\n' "${SUPPORTED_DEVS[@]}" | LC_ALL=C sort))
}

print_usage() {
    echo "Usage: $0 <device> [debug]"
}

print_supported_devs() {
    local index

    echo "Supported devices:"
    for ((index = 0; index < ${#SUPPORTED_DEVS[@]}; index++)); do
        printf "  %d) %s\n" "$((index + 1))" "${SUPPORTED_DEVS[index]}"
    done
}

prompt_select_dev() {
    local input
    local selected_index

    while true; do
        print_supported_devs
        printf "Select device by number (q to quit): "

        if ! read -r input; then
            echo
            echo "Cancelled."
            exit 1
        fi

        if [[ "$input" =~ ^[[:space:]]*[qQ][[:space:]]*$ ]]; then
            echo "Cancelled."
            exit 1
        fi

        if [[ "$input" =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
            selected_index=${BASH_REMATCH[1]}
            if ((selected_index >= 1 && selected_index <= ${#SUPPORTED_DEVS[@]})); then
                Dev=${SUPPORTED_DEVS[selected_index - 1]}
                return
            fi
        fi

        echo "Invalid selection. Please enter a number between 1 and ${#SUPPORTED_DEVS[@]}."
    done
}

prompt_select_build_mode() {
    local input

    while true; do
        echo "Build mode:"
        echo "  1) normal"
        echo "  2) debug"
        printf "Select build mode (1-2, q to quit): "

        if ! read -r input; then
            echo
            echo "Cancelled."
            exit 1
        fi

        if [[ "$input" =~ ^[[:space:]]*[qQ][[:space:]]*$ ]]; then
            echo "Cancelled."
            exit 1
        fi

        if [[ "$input" =~ ^[[:space:]]*1[[:space:]]*$ ]]; then
            Build_Mod=""
            return
        fi

        if [[ "$input" =~ ^[[:space:]]*2[[:space:]]*$ ]]; then
            Build_Mod="debug"
            return
        fi

        echo "Invalid selection. Please enter 1 or 2."
    done
}

is_interactive_terminal() {
    [[ -t 0 && -t 1 ]]
}

if [[ $# -eq 0 ]]; then
    collect_supported_devs

    if [[ ${#SUPPORTED_DEVS[@]} -eq 0 ]]; then
        echo "Error: no supported devices found."
        exit 1
    fi

    if ! is_interactive_terminal; then
        print_usage
        print_supported_devs
        exit 1
    fi

    prompt_select_dev

    if [[ -z $Build_Mod ]]; then
        prompt_select_build_mode
    fi
fi

CONFIG_FILE="$BASE_PATH/deconfig/$Dev.config"
INI_FILE="$BASE_PATH/compilecfg/$Dev.ini"

if [[ ! -f $CONFIG_FILE ]]; then
    echo "Config not found: $CONFIG_FILE"
    exit 1
fi

if [[ ! -f $INI_FILE ]]; then
    echo "INI file not found: $INI_FILE"
    exit 1
fi

read_ini_by_key() {
    local key=$1
    awk -F"=" -v key="$key" '$1 == key {print $2}' "$INI_FILE"
}

remove_uhttpd_dependency() {
    local config_path="$BASE_PATH/../$BUILD_DIR/.config"
    local luci_makefile_path="$BASE_PATH/../$BUILD_DIR/feeds/luci/collections/luci/Makefile"

    if grep -q "CONFIG_PACKAGE_luci-app-quickfile=y" "$config_path"; then
        if [ -f "$luci_makefile_path" ]; then
            sed -i '/luci-light/d' "$luci_makefile_path"
            echo "Removed uhttpd (luci-light) dependency as luci-app-quickfile (nginx) is enabled."
        fi
    fi
}

apply_config() {
    # 1. 复制设备基础配置
    \cp -f "$CONFIG_FILE" "$BASE_PATH/../$BUILD_DIR/.config"
    # 2. 若为 IPQ60xx/IPQ807x 且未启用 Git 镜像，追加 NSS 配置
    if grep -qE "(ipq60xx|ipq807x)" "$BASE_PATH/../$BUILD_DIR/.config" &&
        ! grep -q "CONFIG_GIT_MIRROR" "$BASE_PATH/../$BUILD_DIR/.config"; then
        cat "$BASE_PATH/deconfig/nss.config" >> "$BASE_PATH/../$BUILD_DIR/.config"
    fi
    # 3. 追加公共编译基础配置
    cat "$BASE_PATH/deconfig/compile_base.config" >> "$BASE_PATH/../$BUILD_DIR/.config"
    # 4. 追加 Docker 依赖
    cat "$BASE_PATH/deconfig/docker_deps.config" >> "$BASE_PATH/../$BUILD_DIR/.config"
    # 5. 追加代理配置（如有）
    cat "$BASE_PATH/deconfig/proxy.config" >> "$BASE_PATH/../$BUILD_DIR/.config"

    # ========== 创建自定义默认配置（IP、Netmask、DHCP、WiFi、主机名、密码） ==========
    local UCI_DEFAULTS_DIR="$BASE_PATH/../$BUILD_DIR/files/etc/uci-defaults"
    mkdir -p "$UCI_DEFAULTS_DIR"
    cat > "$UCI_DEFAULTS_DIR/99-custom-settings" << 'EOF'
#!/bin/sh
# 设置主机名
uci set system.@system[0].hostname='Kinsum'
uci commit system
/etc/init.d/system restart

# 设置 LAN IP 和子网掩码
uci set network.lan.proto='static'
uci set network.lan.ipaddr='192.168.188.1'
uci set network.lan.netmask='255.255.255.0'
uci commit network
/etc/init.d/network restart

# 配置 DHCP（dnsmasq）为 LAN 接口分配地址
uci set dhcp.lan.start='100'
uci set dhcp.lan.limit='150'
uci set dhcp.lan.leasetime='12h'
uci set dhcp.lan.ignore='0'
uci commit dhcp
/etc/init.d/dnsmasq restart

# 设置 2.4G WiFi
uci set wireless.radio0.disabled='0'
uci set wireless.@wifi-iface[0].ssid='Titok'
uci set wireless.@wifi-iface[0].key='yunding888'
uci set wireless.@wifi-iface[0].encryption='psk2'

# 设置 5G WiFi（如果存在 radio1）
if uci get wireless.radio1 >/dev/null 2>&1; then
    uci set wireless.radio1.disabled='0'
    uci set wireless.@wifi-iface[1].ssid='Titok_5G'
    uci set wireless.@wifi-iface[1].key='yunding888'
    uci set wireless.@wifi-iface[1].encryption='psk2'
fi
uci commit wireless
wifi

# 设置 root 密码为 erlang（使用 chpasswd 更可靠）
echo "root:erlang" | chpasswd

# 删除自身（首次启动后生效）
rm -f /etc/uci-defaults/99-custom-settings
EOF
    chmod +x "$UCI_DEFAULTS_DIR/99-custom-settings"
}

REPO_URL=$(read_ini_by_key "REPO_URL")
REPO_BRANCH=$(read_ini_by_key "REPO_BRANCH")
REPO_BRANCH=${REPO_BRANCH:-main}
BUILD_DIR=$(read_ini_by_key "BUILD_DIR")
COMMIT_HASH=$(read_ini_by_key "COMMIT_HASH")
COMMIT_HASH=${COMMIT_HASH:-none}

if [[ -d action_build ]]; then
    BUILD_DIR="action_build"
fi

"$BASE_PATH/update.sh" "$REPO_URL" "$REPO_BRANCH" "$BUILD_DIR" "$COMMIT_HASH"

apply_config
remove_uhttpd_dependency

cd "$BASE_PATH/../$BUILD_DIR"
make defconfig

# ========== 在 make defconfig 之后强制写入版本信息 ==========
# 优先使用 GitHub Actions 传入的 BUILD_DATE，否则使用当前日期
if [ -n "$BUILD_DATE" ]; then
    VERSION_NUMBER="$BUILD_DATE"
else
    VERSION_NUMBER="$(date +%y.%m.%d)"
fi

# 追加版本配置，覆盖任何之前的设置
# 如果您想保留 "ImmortalWRT" 发行版名称，请注释掉下一行
echo "CONFIG_VERSION_DIST=\"MyWRT\"" >> .config
echo "CONFIG_VERSION_MANUFACTURER=\"Kinsum@$VERSION_NUMBER\"" >> .config
echo "CONFIG_VERSION_NUMBER=\"$VERSION_NUMBER\"" >> .config
echo 'CONFIG_VERSION_REPO="https://github.com/kinsum666/wrt_release"' >> .config

# 重新合并配置（使新追加的配置生效）
make oldconfig

# 如果目标是 x86_64，修改 distfeeds
if grep -qE "^CONFIG_TARGET_x86_64=y" "$CONFIG_FILE"; then
    DISTFEEDS_PATH="$BASE_PATH/../$BUILD_DIR/package/emortal/default-settings/files/99-distfeeds.conf"
    if [ -d "${DISTFEEDS_PATH%/*}" ] && [ -f "$DISTFEEDS_PATH" ]; then
        sed -i 's/aarch64_cortex-a53/x86_64/g' "$DISTFEEDS_PATH"
    fi
fi

if [[ $Build_Mod == "debug" ]]; then
    exit 0
fi

TARGET_DIR="$BASE_PATH/../$BUILD_DIR/bin/targets"
if [[ -d $TARGET_DIR ]]; then
    find "$TARGET_DIR" -type f \( -name "*.bin" -o -name "*.manifest" -o -name "*efi.img.gz" -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" -o -name "*rootfs.tar.gz" \) -exec rm -f {} +
fi

make download -j$(($(nproc) * 2))
make -j$(($(nproc) + 1)) || make -j1 V=s

FIRMWARE_DIR="$BASE_PATH/../firmware"
\rm -rf "$FIRMWARE_DIR"
mkdir -p "$FIRMWARE_DIR"
find "$TARGET_DIR" -type f \( -name "*.bin" -o -name "*.manifest" -o -name "*efi.img.gz" -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" -o -name "*rootfs.tar.gz" \) -exec cp -f {} "$FIRMWARE_DIR/" \;
\rm -f "$BASE_PATH/../firmware/Packages.manifest" 2>/dev/null

if [[ -d action_build ]]; then
    make clean
fi

# ============================================
# 🎛️ 修改 athena_led 默认配置
# ============================================
ATHENA_CFG="./files/etc/config/athena_led"

if [ -f "$ATHENA_CFG" ]; then
    sed -i "s/option value '.*'/option value 'Kinsum love you.'/" "$ATHENA_CFG"
    sed -i "s/option lightLevel '.*'/option lightLevel '3'/" "$ATHENA_CFG"
    echo "✅ athena_led 配置已修改：文本='Kinsum love you.'，亮度=3"
else
    echo "⚠️ 未找到 athena_led 配置文件，路径：$ATHENA_CFG"
fi


# ========== 修改 banner 登录欢迎信息（防重复） ==========
BANNER_FILE="package/base-files/files/etc/banner"
if [ -f "$BANNER_FILE" ]; then
    if grep -q "Compiled by Kinsum" "$BANNER_FILE"; then
        echo "Banner already modified, skipping."
    else
        cat >> "$BANNER_FILE" << "EOF"
-----------------------------------------------
  Firmware: JDC
  Compiled by Kinsum @ $(TZ=UTC-8 date '+%Y-%m-%d %H:%M:%S')
-----------------------------------------------
EOF
    fi
else
    echo "⚠️  $BANNER_FILE not found, skip banner modification"
fi

# ======================== 定时开关灯 ========================
mkdir -p ./files/etc/crontabs
cat > ./files/etc/crontabs/root << "EOF"
# 每天 23:00 关闭 LED
0 23 * * * uci set athena_led.config.enable='0' && uci commit athena_led && /etc/init.d/athena_led reload
# 每天 07:00 开启 LED
0 7 * * * uci set athena_led.config.enable='1' && uci commit athena_led && /etc/init.d/athena_led reload
EOF

# ======================== LED 按键控制（增强版） ========================
mkdir -p ./files/etc
cat > ./files/etc/led_toggle.sh << "EOF"
#!/bin/sh
LED_STATE_FILE="/tmp/led_state"

led_off() {
    for led in /sys/class/leds/*; do
        [ -e "$led/brightness" ] && echo 0 > "$led/brightness" 2>/dev/null
        [ -e "$led/trigger" ] && echo none > "$led/trigger" 2>/dev/null
    done
}

led_on() {
    for led in /sys/class/leds/*; do
        [ -e "$led/trigger" ] && echo default-on > "$led/trigger" 2>/dev/null
    done
}

if [ -f "$LED_STATE_FILE" ]; then
    STATE=$(cat "$LED_STATE_FILE")
else
    STATE="1"
fi

if [ "$STATE" = "1" ]; then
    led_off
    echo "0" > "$LED_STATE_FILE"
else
    led_on
    echo "1" > "$LED_STATE_FILE"
fi
EOF
chmod +x ./files/etc/led_toggle.sh

mkdir -p ./files/etc/hotplug.d/button
cat > ./files/etc/hotplug.d/button/01-mesh-led << "EOF"
#!/bin/sh
# 按键 LED 开关（防抖，适配所有常见键值）

case "$ACTION" in
    pressed)
        LAST=$(cat /tmp/button_last_time 2>/dev/null)
        NOW=$(cut -d '.' -f 1 /proc/uptime)
        if [ -n "$LAST" ] && [ $((NOW - LAST)) -lt 1 ]; then
            exit 0
        fi
        echo "$NOW" > /tmp/button_last_time

        case "$BUTTON" in
            BTN_*|mesh|wps|reset)
                /etc/led_toggle.sh &
                ;;
        esac
        ;;
esac
EOF
chmod +x ./files/etc/hotplug.d/button/01-mesh-led

# ========== 京东云 eMMC p27 首次格式化 + 自动挂载 ==========
mkdir -p ./files/etc/init.d
cat > ./files/etc/init.d/format_p27 << 'EOF'
#!/bin/sh /etc/rc.common
START=95
STOP=10

PARTITION="/dev/mmcblk0p27"
MOUNT_POINT="/opt"
FS_TYPE="ext4"
STAMP="/etc/.p27_formatted"

start() {
    if [ ! -b "$PARTITION" ]; then
        logger -t "format_p27" "Partition $PARTITION not found, exit."
        return 1
    fi

    if mount | grep -q "$PARTITION"; then
        logger -t "format_p27" "$PARTITION already mounted, nothing to do."
        return 0
    fi

    if [ ! -f "$STAMP" ]; then
        logger -t "format_p27" "First boot detected, formatting $PARTITION to $FS_TYPE..."
        echo "y" | mkfs.ext4 "$PARTITION" || {
            logger -t "format_p27" "Format failed!"
            return 1
        }
        touch "$STAMP"
        logger -t "format_p27" "Format complete, stamp created."
    else
        logger -t "format_p27" "Already formatted, mounting..."
    fi

    mkdir -p "$MOUNT_POINT"
    mount -t "$FS_TYPE" "$PARTITION" "$MOUNT_POINT" || {
        logger -t "format_p27" "Mount failed!"
        return 1
    }
    logger -t "format_p27" "Mounted $PARTITION to $MOUNT_POINT"

    if ! grep -q "$PARTITION" /etc/fstab; then
        echo "$PARTITION $MOUNT_POINT $FS_TYPE defaults 0 0" >> /etc/fstab
    fi
}
EOF
chmod +x ./files/etc/init.d/format_p27

# 启用开机自启
ln -sf /etc/init.d/format_p27 ./files/etc/rc.d/S95format_p27 2>/dev/null || true
