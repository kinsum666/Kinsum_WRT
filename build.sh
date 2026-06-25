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

# 设置 root 密码为 erlang
echo "root:erlang" | chpasswd

# 删除自身（首次启动后生效）
rm -f /etc/uci-defaults/99-custom-settings
EOF
    chmod +x "$UCI_DEFAULTS_DIR/99-custom-settings"

    # ========== 修改 default-settings 中的构建者信息 ==========
    if [ -n "$BUILD_DATE" ]; then
        VERSION_SUFFIX="$BUILD_DATE"
    else
        VERSION_SUFFIX="$(date +%y.%m.%d)"
    fi

    # 查找并替换所有包含 ZqinKing 的 Makefile（多个可能路径）
    for mk in "$BASE_PATH/../$BUILD_DIR/package/emortal/default-settings/Makefile" \
              "$BASE_PATH/../$BUILD_DIR/package/immortalwrt/default-settings/Makefile" \
              "$BASE_PATH/../$BUILD_DIR/feeds/emortal/default-settings/Makefile" \
              "$BASE_PATH/../$BUILD_DIR/feeds/immortalwrt/default-settings/Makefile"; do
        if [ -f "$mk" ]; then
            sed -i "s/ZqinKing/Kinsum@$VERSION_SUFFIX/g" "$mk"
            echo "✅ 已修改 $mk"
        fi
    done

    # ========== 修改 athena_led 默认配置 ==========
    ATHENA_CFG="$BASE_PATH/../$BUILD_DIR/files/etc/config/athena_led"
    mkdir -p "$(dirname "$ATHENA_CFG")"
    cat > "$ATHENA_CFG" << 'EOF'
config athena_led 'config'
    option enable '1'
    option value 'Kinsum love you.'
    option lightLevel '3'
EOF
    echo "✅ athena_led 配置已创建"

    # ========== 修改 banner 登录欢迎信息 ==========
    BANNER_FILE="$BASE_PATH/../$BUILD_DIR/package/base-files/files/etc/banner"
    if [ -f "$BANNER_FILE" ]; then
        if ! grep -q "Compiled by Kinsum" "$BANNER_FILE"; then
            cat >> "$BANNER_FILE" << "EOF"
-----------------------------------------------
  Firmware: JDC
  Compiled by Kinsum @ $(TZ=UTC-8 date '+%Y-%m-%d %H:%M:%S')
-----------------------------------------------
EOF
            echo "✅ banner 已追加"
        else
            echo "ℹ️ banner 已包含 Kinsum 信息，跳过"
        fi
    else
        echo "⚠️  $BANNER_FILE not found, skip banner modification"
    fi

    # ======================== 定时开关灯 ========================
    mkdir -p "$BASE_PATH/../$BUILD_DIR/files/etc/crontabs"
    cat > "$BASE_PATH/../$BUILD_DIR/files/etc/crontabs/root" << "EOF"
# 每天 23:00 关闭 LED
0 23 * * * uci set athena_led.config.enable='0' && uci commit athena_led && /etc/init.d/athena_led reload
# 每天 07:00 开启 LED
0 7 * * * uci set athena_led.config.enable='3' && uci commit athena_led && /etc/init.d/athena_led reload
EOF
    echo "✅ 定时开关灯 crontab 已配置"


    # ======================== LED 按键控制（三色指示灯专用） ========================
    mkdir -p "$BASE_PATH/../$BUILD_DIR/files/etc"
    cat > "$BASE_PATH/../$BUILD_DIR/files/etc/led_toggle.sh" << "EOF"
#!/bin/sh
LED_STATE_FILE="/tmp/led_state"

# 查找三色LED节点（支持常见命名方式）
find_color_led() {
    local color=$1
    # 尝试多种可能的命名模式
    for pattern in ":$color" ":$color:" "$color" "*:$color" "*:$color:"; do
        for led in /sys/class/leds/*; do
            [ -d "$led" ] || continue
            if echo "$led" | grep -q "$pattern"; then
                echo "$led/brightness"
                return 0
            fi
        done
    done
    # 如果找不到，尝试直接匹配包含颜色的节点名
    for led in /sys/class/leds/*; do
        [ -d "$led" ] || continue
        if echo "$led" | grep -qi "$color"; then
            echo "$led/brightness"
            return 0
        fi
    done
    return 1
}

# 获取三色LED亮度文件路径
RED_LED=$(find_color_led red)
GREEN_LED=$(find_color_led green)
BLUE_LED=$(find_color_led blue)

# 如果找不到颜色LED，则使用通配方式控制所有LED（兼容旧方案）
if [ -z "$RED_LED" ] || [ -z "$GREEN_LED" ] || [ -z "$BLUE_LED" ]; then
    logger -t "led_toggle" "Color LEDs not found, fallback to all LEDs"
    get_leds() {
        find /sys/class/leds -maxdepth 1 -type l ! -name "trigger" -exec basename {} \; 2>/dev/null
    }
    led_off() {
        for led in $(get_leds); do
            echo 0 > "/sys/class/leds/$led/brightness" 2>/dev/null
        done
        logger -t "led_toggle" "All LEDs turned OFF (fallback)"
    }
    led_on() {
        for led in $(get_leds); do
            echo 255 > "/sys/class/leds/$led/brightness" 2>/dev/null
        done
        logger -t "led_toggle" "All LEDs turned ON (fallback)"
    }
else
    # 三色专用控制
    led_off() {
        echo 0 > "$RED_LED" 2>/dev/null
        echo 0 > "$GREEN_LED" 2>/dev/null
        echo 0 > "$BLUE_LED" 2>/dev/null
        logger -t "led_toggle" "RGB LEDs turned OFF (R:0 G:0 B:0)"
    }
    led_on() {
        # 设置为白色（255,255,255），也可以自定义，例如绿色（0,255,0）
        echo 255 > "$RED_LED" 2>/dev/null
        echo 255 > "$GREEN_LED" 2>/dev/null
        echo 255 > "$BLUE_LED" 2>/dev/null
        logger -t "led_toggle" "RGB LEDs turned ON (R:255 G:255 B:255)"
    }
fi

# 切换状态
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
    chmod +x "$BASE_PATH/../$BUILD_DIR/files/etc/led_toggle.sh"

    # ========== 通用 eMMC 数据分区自动格式化与挂载 ==========
    mkdir -p "$BASE_PATH/../$BUILD_DIR/files/etc/init.d"
    cat > "$BASE_PATH/../$BUILD_DIR/files/etc/init.d/format_data" << 'EOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10

MOUNT_POINT="/opt"
FS_TYPE="ext4"
STAMP="/etc/.data_formatted"

find_partition() {
    for p in /dev/mmcblk0p27 /dev/mmcblk0p28 /dev/mmcblk1p1; do
        [ -b "$p" ] && echo "$p" && return 0
    done
    local last=$(ls /dev/mmcblk0p* 2>/dev/null | sort -V | tail -1)
    [ -n "$last" ] && echo "$last" && return 0
    return 1
}

start() {
    PARTITION=$(find_partition)
    if [ -z "$PARTITION" ]; then
        logger -t "format_data" "No suitable partition found. Skip."
        return 1
    fi

    if mount | grep -q "$PARTITION"; then
        logger -t "format_data" "$PARTITION already mounted."
        return 0
    fi

    FSTYPE=$(blkid -s TYPE -o value "$PARTITION" 2>/dev/null)
    if [ "$FSTYPE" != "$FS_TYPE" ] && [ ! -f "$STAMP" ]; then
        logger -t "format_data" "Formatting $PARTITION as $FS_TYPE..."
        mkfs.ext4 -F "$PARTITION" || {
            logger -t "format_data" "Format failed!"
            return 1
        }
        touch "$STAMP"
        logger -t "format_data" "Format completed."
    else
        logger -t "format_data" "Partition already has $FSTYPE or stamp exists, skipping format."
    fi

    mkdir -p "$MOUNT_POINT"
    mount -t "$FS_TYPE" "$PARTITION" "$MOUNT_POINT" || {
        sleep 2
        mount -t "$FS_TYPE" "$PARTITION" "$MOUNT_POINT" || {
            logger -t "format_data" "Mount failed!"
            return 1
        }
    }
    logger -t "format_data" "Mounted $PARTITION to $MOUNT_POINT"

    if ! grep -q "$PARTITION" /etc/fstab; then
        echo "$PARTITION $MOUNT_POINT $FS_TYPE defaults 0 0" >> /etc/fstab
    fi
}
EOF
    chmod +x "$BASE_PATH/../$BUILD_DIR/files/etc/init.d/format_data"
    mkdir -p "$BASE_PATH/../$BUILD_DIR/files/etc/rc.d"
    ln -sf /etc/init.d/format_data "$BASE_PATH/../$BUILD_DIR/files/etc/rc.d/S99format_data" 2>/dev/null || true

    echo "✅ apply_config: 所有自定义配置已完成"
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

# ========== 集成 rtp2httpd 源码 ==========
# 将 rtp2httpd 仓库中的三个独立包复制到 package/ 根目录
RTP2HTTPD_TMP="/tmp/rtp2httpd_repo"
RTP2HTTPD_PACKAGES="luci-app-rtp2httpd taskd luci-lib-taskd"

# 清理旧临时目录（避免残留）
rm -rf "$RTP2HTTPD_TMP"
git clone --depth=1 https://github.com/stackia/rtp2httpd.git "$RTP2HTTPD_TMP"

for pkg in $RTP2HTTPD_PACKAGES; do
    if [ -d "$RTP2HTTPD_TMP/$pkg" ]; then
        rm -rf "package/$pkg"
        cp -r "$RTP2HTTPD_TMP/$pkg" "package/"
        echo "✅ 已复制 $pkg 到 package/"
    else
        echo "⚠️  源目录中未找到 $pkg，跳过"
    fi
done

rm -rf "$RTP2HTTPD_TMP"
echo "✅ rtp2httpd 相关包已集成到 package/"

# 在 .config 中启用这些包（确保被选中）
echo "CONFIG_PACKAGE_luci-app-rtp2httpd=y" >> .config
echo "CONFIG_PACKAGE_taskd=y" >> .config
echo "CONFIG_PACKAGE_luci-lib-taskd=y" >> .config


# ===========================================
make defconfig

# 下载 OpenClash Meta 内核
if [ -f "$(dirname "$0")/diy-part.sh" ]; then
    (cd "$BASE_PATH/../$BUILD_DIR" && "$(dirname "$0")/diy-part.sh")
fi

# 追加必要的包（用于分区格式化）
echo "CONFIG_PACKAGE_e2fsprogs=y" >> .config
echo "CONFIG_PACKAGE_blkid=y" >> .config

# ========== 在 make defconfig 之后强制写入版本信息 ==========
if [ -n "$BUILD_DATE" ]; then
    VERSION_NUMBER="$BUILD_DATE"
else
    VERSION_NUMBER="$(date +%y.%m.%d)"
fi

echo "CONFIG_VERSION_DIST=\"MyWRT\"" >> .config
echo "CONFIG_VERSION_MANUFACTURER=\"Kinsum@$VERSION_NUMBER\"" >> .config
echo "CONFIG_VERSION_NUMBER=\"$VERSION_NUMBER\"" >> .config
echo 'CONFIG_VERSION_REPO="https://github.com/kinsum666/wrt_release"' >> .config
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

# ========== 在打包前修正 openwrt_release ==========
# 查找并修改生成的 openwrt_release 文件，确保 build by 正确
RELEASE_FILE=$(find "$TARGET_DIR" -path "*/root-*/etc/openwrt_release" 2>/dev/null | head -1)
if [ -f "$RELEASE_FILE" ]; then
    sed -i "s/ZqinKing/Kinsum@$VERSION_NUMBER/g" "$RELEASE_FILE"
    echo "✅ 已修正 openwrt_release ($RELEASE_FILE)"
else
    echo "⚠️ 未找到 openwrt_release 文件，跳过"
fi

FIRMWARE_DIR="$BASE_PATH/../firmware"
\rm -rf "$FIRMWARE_DIR"
mkdir -p "$FIRMWARE_DIR"
find "$TARGET_DIR" -type f \( -name "*.bin" -o -name "*.manifest" -o -name "*efi.img.gz" -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" -o -name "*rootfs.tar.gz" \) -exec cp -f {} "$FIRMWARE_DIR/" \;
\rm -f "$BASE_PATH/../firmware/Packages.manifest" 2>/dev/null

if [[ -d action_build ]]; then
    make clean
fi
