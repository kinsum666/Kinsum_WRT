# ======================================================
# OpenClash Meta 内核自动下载（适用于京东云雅典娜/亚瑟）
# ======================================================

# 1. 定义目标目录（相对于 OpenWrt 编译根目录）
OPENCLASH_CORE_DIR="package/luci-app-openclash/files/etc/openclash/core"
mkdir -p "$OPENCLASH_CORE_DIR"

# 2. 获取目标设备架构（从 .config 读取）
if [ -f .config ]; then
    ARCH=$(grep -o 'CONFIG_ARCH="[^"]*"' .config | cut -d'"' -f2)
else
    echo "❌ .config not found, skip OpenClash kernel download"
    exit 0
fi

# 3. 架构映射（京东云雅典娜/亚瑟为 aarch64）
case "$ARCH" in
    "aarch64") KERNEL_ARCH="arm64" ;;
    "x86_64")  KERNEL_ARCH="amd64" ;;
    "arm")     KERNEL_ARCH="armv7" ;;
    *)         echo "⚠️  Unsupported architecture: $ARCH, skip"; exit 0 ;;
esac

# 4. 获取最新版本号（从 MetaCubeX/mihomo）
LATEST_VERSION=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
if [ -z "$LATEST_VERSION" ]; then
    echo "❌ Failed to get latest version, using fallback v1.18.10"
    LATEST_VERSION="v1.18.10"
fi
echo "✅ Latest mihomo version: $LATEST_VERSION"

# 5. 下载并解压 Meta 内核
KERNEL_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/mihomo-linux-${KERNEL_ARCH}-${LATEST_VERSION}.gz"
echo "📥 Downloading: $KERNEL_URL"

if wget -qO- "$KERNEL_URL" | gunzip -c > "$OPENCLASH_CORE_DIR/clash_meta"; then
    chmod +x "$OPENCLASH_CORE_DIR/clash_meta"
    echo "✅ OpenClash Meta kernel installed (${LATEST_VERSION})"
else
    echo "❌ Download failed, please check network or URL"
    exit 1
fi
