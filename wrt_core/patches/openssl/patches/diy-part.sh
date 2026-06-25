#!/bin/bash
# ======================================================
# OpenClash Meta 内核自动下载脚本
# 适用于京东云雅典娜/亚瑟 (ARM64 / aarch64)
# ======================================================

# 1. 定义路径
OPENCLASH_CORE_DIR="package/luci-app-openclash/files/etc/openclash/core"
mkdir -p $OPENCLASH_CORE_DIR

# 2. 获取目标设备架构
#    从 .config 中读取架构
ARCH=$(grep -o 'CONFIG_ARCH="[^"]*"' .config | cut -d'"' -f2)

# 3. 根据架构映射内核文件名
#    京东云雅典娜/亚瑟均为 aarch64 (ARM64)
case "$ARCH" in
    "aarch64") KERNEL_ARCH="arm64" ;;
    "x86_64")  KERNEL_ARCH="amd64" ;;
    "arm")     KERNEL_ARCH="armv7" ;;
    *)         echo "Unknown architecture: $ARCH"; exit 1 ;;
esac

# 4. 获取最新版本号
#    从 MetaCubeX/mihomo 的 GitHub Release 获取最新版本
LATEST_VERSION=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
if [ -z "$LATEST_VERSION" ]; then
    echo "❌ Failed to get latest version, using fallback"
    # 如果获取失败，可以设置一个备用版本号
    LATEST_VERSION="v1.18.10"
fi
echo "✅ Latest mihomo version: $LATEST_VERSION"

# 5. 下载 Meta 内核
#    文件名格式: mihomo-linux-{arch}-{version}.gz
KERNEL_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/mihomo-linux-${KERNEL_ARCH}-${LATEST_VERSION}.gz"
echo "📥 Downloading: $KERNEL_URL"

# 下载并解压到目标目录
wget -qO- $KERNEL_URL | gunzip -c > $OPENCLASH_CORE_DIR/clash_meta
if [ $? -eq 0 ]; then
    chmod +x $OPENCLASH_CORE_DIR/clash_meta
    echo "✅ OpenClash Meta kernel downloaded successfully (${LATEST_VERSION})"
else
    echo "❌ Download failed! Please check the URL or network."
    exit 1
fi
