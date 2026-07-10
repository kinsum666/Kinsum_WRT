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
     # cat "$BASE_PATH/deconfig/proxy.config" >> "$BASE_PATH/../$BUILD_DIR/.config"

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
    option value 'Kinsum love you!'
    option seconds '5'
	option status 'time'
    option lightLevel '2'
    option tempFlag '4'
    
EOF
    echo "✅ athena_led 配置已创建"

    # ========== 修改 banner 登录欢迎信息 ==========
    BANNER_FILE="$BASE_PATH/../$BUILD_DIR/package/base-files/files/etc/banner"

    # 1. 打印实际路径，方便调试确认是否正确
    echo "Banner target path: $BANNER_FILE"

    # 2. 确保目标目录存在（避免因目录不存在而写入失败）
    mkdir -p "$(dirname "$BANNER_FILE")"

    # 3. 写入个性化 Banner（注意：这里 << EOF 不带引号，以便 $(date) 能被Shell展开）
    cat > "$BANNER_FILE" << EOF

--------------------------------------------------------
Welcome to...
--------------------------------------------------------

,--.    ,--.                                  
|  |,-. `--',--,--,  ,---. ,--.,--.,--,--,--. 
|     / ,--.|      \(  .-' |  ||  ||        | 
|  \  \ |  ||  ||  |.-'  ')'  ''  '|  |  |  | 
`--'`--'`--'`--''--'`----'  `----' `--`--`--'            
                                                        
--------------------------------------------------------
  Firmware compiled by Kinsum @ DATE_PLACEHOLDER
--------------------------------------------------------
                                                                                                                   

EOF

    # 4. 检查写入结果
    if [ $? -eq 0 ]; then
        echo "Banner updated successfully with Kinsum."
    else
        echo "ERROR: Failed to update banner."
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

    # ======================== 按键功能：wps 控制底部灯光 ========================
    mkdir -p "$BASE_PATH/../$BUILD_DIR/files/etc"
    cat > "$BASE_PATH/../$BUILD_DIR/files/etc/rgb_toggle.sh" << "EOF"
#!/bin/sh
# 切换底部 RGB 灯光模式：0关、1呼吸、2常亮、3自定义（循环切换）
CURRENT=$(uci get athena_led.config.enable 2>/dev/null)
[ -z "$CURRENT" ] && CURRENT=0
NEXT=$(( (CURRENT + 1) % 4 ))
uci set athena_led.config.enable="$NEXT"
uci commit athena_led
/etc/init.d/athena_led restart
logger -t "rgb_toggle" "RGB mode switched to $NEXT"
EOF
    chmod +x "$BASE_PATH/../$BUILD_DIR/files/etc/rgb_toggle.sh"

    # ======================== 按键功能：BTN_1 切换屏幕显示内容 ========================
    cat > "$BASE_PATH/../$BUILD_DIR/files/etc/screen_toggle.sh" << "EOF"
#!/bin/sh
# 切换屏幕 LED 显示内容：time, date, weather, network, temp 等（循环）
# 请根据实际设备支持的 status 值调整列表（可通过 uci show athena_led 查看）
STATUS_LIST="time date weather network temp"
CURRENT=$(uci get athena_led.config.status 2>/dev/null)
[ -z "$CURRENT" ] && CURRENT="time"

# 查找当前索引
INDEX=0
for s in $STATUS_LIST; do
    if [ "$s" = "$CURRENT" ]; then
        break
    fi
    INDEX=$((INDEX + 1))
done
# 计算下一个索引
NEXT_INDEX=$(( (INDEX + 1) % $(echo $STATUS_LIST | wc -w) ))
NEXT_STATUS=$(echo $STATUS_LIST | cut -d' ' -f$((NEXT_INDEX+1)))

uci set athena_led.config.status="$NEXT_STATUS"
uci commit athena_led
/etc/init.d/athena_led restart
logger -t "screen_toggle" "Screen display switched to $NEXT_STATUS"
EOF
    chmod +x "$BASE_PATH/../$BUILD_DIR/files/etc/screen_toggle.sh"

    # ======================== 热插拔事件处理（交换按键功能） ========================
    mkdir -p "$BASE_PATH/../$BUILD_DIR/files/etc/hotplug.d/button"
    cat > "$BASE_PATH/../$BUILD_DIR/files/etc/hotplug.d/button/01-custom-buttons" << "EOF"
#!/bin/sh
# 按键功能映射：
#   wps   → 切换 RGB 灯光模式（关/呼吸/常亮/自定义）
#   BTN_1 → 切换屏幕显示内容（时间/日期/天气/网络等）
case "$ACTION" in
    pressed)
        # 防抖动
        LAST=$(cat /tmp/button_last_time 2>/dev/null)
        NOW=$(cut -d '.' -f 1 /proc/uptime)
        if [ -n "$LAST" ] && [ $((NOW - LAST)) -lt 1 ]; then
            exit 0
        fi
        echo "$NOW" > /tmp/button_last_time

        logger -t "button-handler" "Button pressed: $BUTTON"

        case "$BUTTON" in
            wps)
                /etc/rgb_toggle.sh &
                ;;
            BTN_1)
                /etc/screen_toggle.sh &
                ;;
        esac
        ;;
esac
EOF
    chmod +x "$BASE_PATH/../$BUILD_DIR/files/etc/hotplug.d/button/01-custom-buttons"
    # ============================================================

    # ========== 通用 eMMC 数据分区自动格式化与挂载（增强版） ==========
    mkdir -p "$BASE_PATH/../$BUILD_DIR/files/etc/init.d"
    cat > "$BASE_PATH/../$BUILD_DIR/files/etc/init.d/format_data" << 'EOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10

MOUNT_POINT="/opt"
FS_TYPE="ext4"
STAMP="/etc/.data_formatted"

# 更智能的分区查找：优先查找最大的未挂载 mmcblk 分区
find_partition() {
    local part=""
    # 1. 尝试常见的雅典娜分区
    for p in /dev/mmcblk0p27 /dev/mmcblk0p28 /dev/mmcblk1p1; do
        [ -b "$p" ] && { echo "$p"; return 0; }
    done

    # 2. 搜索所有 mmcblk 分区，排除已挂载的，选择最大的（通常是用户数据区）
    for p in /dev/mmcblk[0-9]p*; do
        [ -b "$p" ] || continue
        # 跳过已挂载的分区
        mount | grep -q "$p" && continue
        # 跳过 boot 分区（通常很小）
        size=$(blockdev --getsz "$p" 2>/dev/null)
        [ -z "$size" ] && continue
        # 大于 1GB 的分区视为可能的数据区
        if [ "$size" -gt 2000000 ]; then
            part="$p"
            break
        fi
    done

    if [ -n "$part" ]; then
        echo "$part"
        return 0
    fi

    # 3. 回退：列出所有 mmcblk0p* 取最后一个
    local last=$(ls /dev/mmcblk0p* 2>/dev/null | sort -V | tail -1)
    [ -n "$last" ] && echo "$last" && return 0

    return 1
}

start() {
    logger -t "format_data" "=== Starting data partition setup ==="

    PARTITION=$(find_partition)
    if [ -z "$PARTITION" ]; then
        logger -t "format_data" "ERROR: No suitable partition found. Skip."
        return 1
    fi
    logger -t "format_data" "Using partition: $PARTITION"

    if mount | grep -q "$PARTITION"; then
        logger -t "format_data" "$PARTITION already mounted."
        return 0
    fi

    # 检查文件系统类型
    FSTYPE=$(blkid -s TYPE -o value "$PARTITION" 2>/dev/null)
    logger -t "format_data" "Current filesystem: ${FSTYPE:-none}"

    # 如果不存在标记文件且文件系统不是 ext4，则格式化
    if [ ! -f "$STAMP" ] && [ "$FSTYPE" != "$FS_TYPE" ]; then
        logger -t "format_data" "Formatting $PARTITION as $FS_TYPE..."
        if mkfs.ext4 -F "$PARTITION" >/dev/null 2>&1; then
            touch "$STAMP"
            logger -t "format_data" "Format completed."
        else
            logger -t "format_data" "Format failed!"
            return 1
        fi
    else
        logger -t "format_data" "Partition already $FS_TYPE or stamp exists, skipping format."
    fi

    # 挂载
    mkdir -p "$MOUNT_POINT"
    if mount -t "$FS_TYPE" "$PARTITION" "$MOUNT_POINT" 2>/dev/null; then
        logger -t "format_data" "Mounted $PARTITION to $MOUNT_POINT"
    else
        sleep 2
        if mount -t "$FS_TYPE" "$PARTITION" "$MOUNT_POINT" 2>/dev/null; then
            logger -t "format_data" "Mounted $PARTITION to $MOUNT_POINT (retry)"
        else
            logger -t "format_data" "Mount failed!"
            return 1
        fi
    fi

    # 写入 fstab（避免重复）
    if ! grep -q "$PARTITION" /etc/fstab; then
        echo "$PARTITION $MOUNT_POINT $FS_TYPE defaults 0 0" >> /etc/fstab
        logger -t "format_data" "Added to fstab"
    fi
}
EOF
    chmod +x "$BASE_PATH/../$BUILD_DIR/files/etc/init.d/format_data"
    mkdir -p "$BASE_PATH/../$BUILD_DIR/files/etc/rc.d"
    ln -sf /etc/init.d/format_data "$BASE_PATH/../$BUILD_DIR/files/etc/rc.d/S99format_data" 2>/dev/null || true
    echo "✅ format_data 已配置（增强版）"
    # ============================================================

    # ========== 复制 status.cgi 到 /www/cgi-bin/ ==========
    SOURCE_CGI="$BASE_PATH/modules/status.cgi"
    if [ -f "$SOURCE_CGI" ]; then
        TARGET_CGI_DIR="$BASE_PATH/../$BUILD_DIR/files/www/cgi-bin"
        mkdir -p "$TARGET_CGI_DIR"
        cp -f "$SOURCE_CGI" "$TARGET_CGI_DIR/"
        chmod +x "$TARGET_CGI_DIR/status.cgi"
        echo "✅ status.cgi 已复制并赋予执行权限"
    else
        echo "⚠️  status.cgi 未找到，跳过"
    fi
    # ========================================================

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

# ========== 强制禁用 GDB（在 defconfig 之前） ==========
# 确保 .config 中 GDB 被关闭
sed -i '/^CONFIG_GDB/d' .config
echo "# CONFIG_GDB is not set" >> .config
echo "✅ 已在 defconfig 前禁用 GDB"
# ====================================================

# ========== 添加自定义 feeds 源（注释掉） ==========
# echo 'src-git bandix https://github.com/timsaya/luci-app-bandix-plus.git' >> feeds.conf.default
# echo 'src-git kiddin9 https://github.com/kiddin9/kwrt-packages.git;main' >> feeds.conf.default
echo "✅ 自定义 feeds 源已跳过（如需要请取消注释）"

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

# ========== 集成 WiFiPortal 插件 ==========
echo "正在集成 WiFiPortal 插件..."
WIFIPORTAL_TMP="/tmp/WiFiPortal_repo"
rm -rf "$WIFIPORTAL_TMP"
git clone --depth=1 https://github.com/wiwizcom/WiFiPortal.git "$WIFIPORTAL_TMP"

# 复制插件核心目录到 package/ 下
for pkg in dcc2-wiwiz eqos-master-wiwiz wifidog-wiwiz; do
    if [ -d "$WIFIPORTAL_TMP/$pkg" ]; then
        rm -rf "package/$pkg"
        cp -r "$WIFIPORTAL_TMP/$pkg" "package/"
        echo "✅ 已复制 $pkg 到 package/"
    else
        echo "⚠️  未找到 $pkg，跳过"
    fi
done
rm -rf "$WIFIPORTAL_TMP"

# 更新 feeds（非常重要，让OpenWrt识别新包）
./scripts/feeds update -a
./scripts/feeds install -a
echo "✅ WiFiPortal 插件集成完成"
# =======================================

# ========== 集成 netem 源码（注释掉） ==========
# 如需启用，取消注释以下内容
#NETEM_TMP="/tmp/netem_repo"
#NETEM_PACKAGES="netem-control luci-app-netem"
#rm -rf "$NETEM_TMP"
#git clone --depth=1 https://github.com/Connectify/openwrt-netem.git "$NETEM_TMP"
#for pkg in $NETEM_PACKAGES; do
#    if [ -d "$NETEM_TMP/$pkg" ]; then
#        rm -rf "package/$pkg"
#        cp -r "$NETEM_TMP/$pkg" "package/"
#        echo "✅ 已复制 $pkg 到 package/"
#    else
#        echo "⚠️  源目录中未找到 $pkg，跳过"
#    fi
#done
#rm -rf "$NETEM_TMP"
#echo "✅ netem 相关包已集成到 package/"
#echo "CONFIG_PACKAGE_netem-control=y" >> .config
#echo "CONFIG_PACKAGE_luci-app-netem=y" >> .config
#echo "CONFIG_PACKAGE_kmod-netem=y" >> .config   
#echo "CONFIG_PACKAGE_tc=y" >> .config 

# ===========================================
make defconfig

# ========== 再次确保 GDB 禁用（defconfig 可能覆盖） ==========
sed -i '/^CONFIG_GDB/d' .config
echo "# CONFIG_GDB is not set" >> .config
echo "✅ defconfig 后再次禁用 GDB"
# ============================================================

# 追加必要的包（用于分区格式化）
echo "CONFIG_PACKAGE_e2fsprogs=y" >> .config
echo "CONFIG_PACKAGE_blkid=y" >> .config

# 启用 rtp2httpd 相关包
echo "CONFIG_PACKAGE_luci-app-rtp2httpd=y" >> .config
echo "CONFIG_PACKAGE_taskd=y" >> .config
echo "CONFIG_PACKAGE_luci-lib-taskd=y" >> .config

# 启用 WiFiPortal 相关包
echo "CONFIG_PACKAGE_luci-app-eqos=y" >> .config
echo "CONFIG_PACKAGE_wifidog-wiwiz=y" >> .config
echo "CONFIG_PACKAGE_dcc2-wiwiz-nossl=y" >> .config
echo "CONFIG_PACKAGE_autokick-wiwiz=y" >> .config
# 确保 luci-ssl-openssl 等依赖也被选中
echo "CONFIG_PACKAGE_luci-ssl-openssl=y" >> .config
echo "CONFIG_PACKAGE_luci=y" >> .config
echo "CONFIG_PACKAGE_luci-compat=y" >> .config

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

# ========== 再次检查并修正 GDB（oldconfig 可能恢复） ==========
if grep -q "^CONFIG_GDB=y" .config; then
    sed -i '/^CONFIG_GDB/d' .config
    echo "# CONFIG_GDB is not set" >> .config
    echo "⚠️  oldconfig 恢复了 GDB，已再次禁用"
    make oldconfig   # 重新调整依赖
fi
# 最后再确保一次
if grep -q "^CONFIG_GDB=y" .config; then
    echo "ERROR: 无法禁用 GDB，请手动检查 .config"
    exit 1
fi
echo "✅ GDB 已彻底禁用"
# ============================================================

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

# ========== 清理所有 .la 文件，消除 libtool 硬编码路径 ==========
echo "清理 staging_dir 下所有 .la 文件，避免路径错误..."
find "$BASE_PATH/../$BUILD_DIR/staging_dir" -name "*.la" -type f -delete
echo "✅ .la 文件清理完成"
# ================================================================

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
