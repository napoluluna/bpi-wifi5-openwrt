#!/usr/bin/env bash
# Build OpenWrt for the Banana Pi BPI-WiFi5 (Siflower SF19A2890, MIPS interAptiv).
#
# Base:  ulli-kroll/openwrt, branch openwrt-siflower/v6.18/sf19/master
#        (ethernet + AN8855 DSA switch working; no WiFi driver)
# Adds:  patches/0001-bananapi-wifi5-make-it-flashable.patch
#
# Usage:
#   ./build.sh                  # initramfs + sysupgrade, no LuCI, 8 MiB layout
#   ./build.sh --luci           # add LuCI (check the image still fits!)
#   ./build.sh --flash 16       # ONLY if you confirmed a 16 MiB NOR chip
#   ./build.sh --verbose        # make V=s, single job (for debugging failures)
#   ./build.sh --clean          # wipe bin/ and build_dir before building
set -euo pipefail

REPO_URL="https://github.com/ulli-kroll/openwrt.git"
REPO_BRANCH="openwrt-siflower/v6.18/sf19/master"
REPO_COMMIT="3dcbd9274bc1b065f9490645bae89c025b174e14"   # "add board support for banana pi wifi5"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/openwrt"
FLASH_MB=8
WITH_LUCI=0
VERBOSE=0
CLEAN=0

while [ $# -gt 0 ]; do
	case "$1" in
		--luci)    WITH_LUCI=1 ;;
		--flash)   FLASH_MB="$2"; shift ;;
		--verbose) VERBOSE=1 ;;
		--clean)   CLEAN=1 ;;
		-h|--help) sed -n '2,14p' "$0"; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
	shift
done

case "$FLASH_MB" in 8|16) ;; *) echo "--flash must be 8 or 16" >&2; exit 1 ;; esac

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- host deps --
say "Checking host tools"
missing=()
for t in git make gcc g++ python3 rsync wget unzip file bc; do
	command -v "$t" >/dev/null 2>&1 || missing+=("$t")
done
[ ${#missing[@]} -eq 0 ] || die "missing host tools: ${missing[*]}
Debian/Ubuntu:
  sudo apt install build-essential clang flex bison g++ gawk gcc-multilib \\
    g++-multilib gettext git libncurses-dev libssl-dev python3-setuptools \\
    rsync swig unzip zlib1g-dev file wget bc"
[ "$(id -u)" -ne 0 ] || die "do not build OpenWrt as root"

# ------------------------------------------------------------------- source --
if [ ! -d "$SRC/.git" ]; then
	say "Cloning $REPO_BRANCH"
	git clone --single-branch -b "$REPO_BRANCH" "$REPO_URL" "$SRC"
fi
cd "$SRC"
say "Pinning to $REPO_COMMIT"
git fetch origin "$REPO_BRANCH"
git checkout -q --detach "$REPO_COMMIT"
git reset -q --hard "$REPO_COMMIT"
git clean -qfd target/linux/siflower

# ------------------------------------------------------------------ patches --
say "Applying local patches"
for p in "$HERE"/patches/*.patch; do
	[ -e "$p" ] || continue
	echo "  $(basename "$p")"
	git apply "$p" || die "patch failed: $p"
done

if [ "$FLASH_MB" = 16 ]; then
	say "Switching to 16 MiB NOR layout"
	sed -i 's|reg = <0xa0000 0x760000>;.*|reg = <0xa0000 0xf60000>; /* 16 MiB NOR */|' \
		target/linux/siflower/dts/sf19a2890_bananapi-wifi5.dts
	sed -i 's|IMAGE_SIZE := 7552k|IMAGE_SIZE := 15744k|' \
		target/linux/siflower/image/sf19a2890.mk
	grep -q 0xf60000 target/linux/siflower/dts/sf19a2890_bananapi-wifi5.dts \
		|| die "16 MiB rewrite did not take"
fi

# -------------------------------------------------------------------- feeds --
say "Updating feeds (slow the first time)"
./scripts/feeds update -a
./scripts/feeds install -a

# ------------------------------------------------------------------- config --
say "Writing .config"
cat > .config <<'EOF'
CONFIG_TARGET_siflower=y
CONFIG_TARGET_siflower_sf19a2890=y
CONFIG_TARGET_siflower_sf19a2890_DEVICE_bananapi_wifi5=y
# 6.18 is where the AN8855 switch support lives; 6.12 will NOT give you ethernet
CONFIG_TESTING_KERNEL=y
CONFIG_TARGET_ROOTFS_INITRAMFS=y
CONFIG_TARGET_ROOTFS_SQUASHFS=y
CONFIG_PACKAGE_kmod-gpio-button-hotplug=y
# --- diagnostics: reading hardware registers and sniffing the wire ---
CONFIG_BUSYBOX_CUSTOM=y
CONFIG_BUSYBOX_CONFIG_DEVMEM=y
# /dev/mem itself, which OpenWrt disables by default - without this the
# devmem applet exists but has nothing to open.
CONFIG_KERNEL_DEVMEM=y
CONFIG_PACKAGE_ethtool=y
CONFIG_PACKAGE_tcpdump-mini=y
CONFIG_PACKAGE_ip-full=y
# read/write the AN8855 switch registers over MDIO (its regs are NOT
# memory-mapped, so devmem cannot reach them)
CONFIG_PACKAGE_mdio-tools=y
CONFIG_PACKAGE_kmod-mdio-netlink=y
EOF
if [ "$WITH_LUCI" = 1 ]; then
	cat >> .config <<'EOF'
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-ssl=y
EOF
fi
make defconfig >/dev/null

grep -q 'CONFIG_TARGET_siflower_sf19a2890_DEVICE_bananapi_wifi5=y' .config \
	|| die "profile did not survive defconfig - the device recipe may have been renamed"
grep -q 'CONFIG_TESTING_KERNEL=y' .config \
	|| die "testing kernel (6.18) not selected"

# -------------------------------------------------------------------- build --
[ "$CLEAN" = 1 ] && { say "Cleaning"; make clean; }

say "Building (first run pulls the toolchain; expect 30-90 min)"
if [ "$VERBOSE" = 1 ]; then
	make -j1 V=s
else
	make -j"$(nproc)" || {
		echo
		echo "Build failed. Re-run the failing step verbosely with:"
		echo "  cd $SRC && make -j1 V=s"
		exit 1
	}
fi

# ------------------------------------------------------------------ results --
OUT="$SRC/bin/targets/siflower/sf19a2890"
say "Images in $OUT"
ls -lh "$OUT"/*bananapi* 2>/dev/null || die "no images produced"

echo
echo "Flash budget check (${FLASH_MB} MiB NOR):"
for f in "$OUT"/*bananapi*sysupgrade.bin; do
	[ -e "$f" ] || continue
	sz=$(stat -c%s "$f")
	if [ "$FLASH_MB" = 8 ]; then lim=$((7552*1024)); else lim=$((15744*1024)); fi
	printf '  %-60s %8s / %s bytes\n' "$(basename "$f")" "$sz" "$lim"
	[ "$sz" -le "$lim" ] || echo "  ^^ TOO BIG - drop packages or confirm a larger flash chip"
done

cat <<EOF

Next step is NOT flashing. Boot the initramfs over TFTP first:
  see README.md, section "First boot (no risk)"
EOF
