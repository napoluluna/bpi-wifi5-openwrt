#!/usr/bin/env bash
# Build OpenWrt for the Banana Pi BPI-WiFi5 (Siflower SF19A2890, MIPS interAptiv).
#
# Base:  ulli-kroll/openwrt, branch openwrt-siflower/v6.18/sf19/master
#        (ethernet + AN8855 DSA switch working; no WiFi driver)
# Adds:  patches/0001-bananapi-wifi5-make-it-flashable.patch
#
# Usage:
#   ./build.sh                  # initramfs + sysupgrade, no LuCI, 8 MiB layout
#                               # (always includes the ported WiFi driver;
#                               # no diagnostic tools any more - CLAUDE.md section 8)
#   ./build.sh --luci           # add LuCI (check the image still fits!)
#   ./build.sh --slabinfo       # debug build: CONFIG_SLUB_DEBUG so /proc/slabinfo exists
#   ./build.sh --flash 16       # ONLY if you confirmed a 16 MiB NOR chip
#   ./build.sh --verbose        # make V=s, single job (for debugging failures)
#   ./build.sh --clean          # wipe bin/ and build_dir before building
set -euo pipefail

REPO_URL="https://github.com/ulli-kroll/openwrt.git"
REPO_BRANCH="openwrt-siflower/v6.18/sf19/master"
REPO_COMMIT="3dcbd9274bc1b065f9490645bae89c025b174e14"   # "add board support for banana pi wifi5"

# The WiFi driver. Sources are NOT committed to this repo (no redistribution
# grant - see CLAUDE.md section 4); they are cloned here and the port is applied
# as driver/0001-*.patch. Pinned, because the patch is a context diff.
DRIVER_URL="https://github.com/Siflower/sf_wifi.git"
DRIVER_COMMIT="da991fafab179a2ed495c2925a0bf219ef38e22e"  # "Initial release for open-source wifi driver"

# The LMAC firmware blobs come from an OLDER commit of the Banana Pi SDK, not
# from sf_wifi: the memory-opt blobs in sf_wifi (and in the SDK's current
# main) leave every fresh 5 GHz station without unicast for 2-25 s after
# association; the build in this commit does not (measured 8/8 at 0.0 s,
# same as the vendor firmware). Pinned by md5. See CLAUDE.md, "5 GHz
# post-association blackout".
LMAC_REPO_RAW="https://raw.githubusercontent.com/BPI-SINOVOIP/BPI-WiFi5-Siflower"
LMAC_COMMIT="a685325502c3348690572ba64e18d2be65fe544a"
LMAC_DIR="openwrt-18.06/package/kernel/sf_smac/config/a28fullmask/memory-opt"
LMAC_HB_MD5="fdb7c5dfb665e0cb4cf30d4987fabb44"
LMAC_LB_MD5="5842b583b20d7a8711d54209d2fbcc0d"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/openwrt"
FLASH_MB=8
WITH_LUCI=0
WITH_SLABINFO=0
VERBOSE=0
CLEAN=0

while [ $# -gt 0 ]; do
	case "$1" in
		--luci)    WITH_LUCI=1 ;;
		--slabinfo) WITH_SLABINFO=1 ;;
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

# ------------------------------------------------------------- wifi driver --
# Rebuilds package/kernel/sf_smac from scratch every run: upstream sources at
# the pinned commit, the port applied on top, plus the three headers the sf_wifi
# repo does not ship and the OpenWrt package Makefile.
say "Setting up the WiFi driver package"
DRV_SRC="$HERE/sf_wifi"
if [ ! -d "$DRV_SRC/.git" ]; then
	git clone --single-branch "$DRIVER_URL" "$DRV_SRC"
fi
( cd "$DRV_SRC" && git fetch -q origin && git checkout -q --detach "$DRIVER_COMMIT" \
	&& git reset -q --hard "$DRIVER_COMMIT" && git clean -qfd ) \
	|| die "could not pin $DRIVER_URL to $DRIVER_COMMIT"

PKG="$SRC/package/kernel/sf_smac"
rm -rf "$PKG"
mkdir -p "$PKG"
cp -a "$DRV_SRC/sf_smac/src"    "$PKG/src"
cp -a "$DRV_SRC/sf_smac/config" "$PKG/config"
cp -a "$HERE/driver/siflower_include" "$PKG/"
cp "$HERE/driver/sf_smac.Makefile" "$PKG/Makefile"
cp "$HERE/driver/sf_factory_read.c" "$PKG/"
cp -a "$HERE/driver/files" "$PKG/files"
patch -p1 -s -d "$PKG/src" < "$HERE/driver/0001-sf_wifi-port-to-linux-6.18.patch" \
	|| die "driver port patch failed"
# the port must be there, or the build silently produces a 4.14 driver
grep -q "timer_container_of" "$PKG/src/bb_src/umac/siwifi_utils.c" \
	|| die "driver port did not apply cleanly"

say "Fetching the LMAC firmware blobs (BPI SDK $LMAC_COMMIT)"
mkdir -p "$HERE/dl"
for f in sf1688_hb_fmac.bin sf1688_lb_fmac.bin; do
	want=$LMAC_LB_MD5; [ "$f" = sf1688_hb_fmac.bin ] && want=$LMAC_HB_MD5
	dst="$HERE/dl/lmac-${LMAC_COMMIT:0:7}-$f"
	if [ ! -e "$dst" ] || [ "$(md5sum "$dst" | cut -d' ' -f1)" != "$want" ]; then
		wget -q -O "$dst" "$LMAC_REPO_RAW/$LMAC_COMMIT/$LMAC_DIR/$f" || die "could not fetch $f"
	fi
	[ "$(md5sum "$dst" | cut -d' ' -f1)" = "$want" ] || die "$f: md5 mismatch"
	cp "$dst" "$PKG/config/a28fullmask/memory-opt/$f"
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
# --- WiFi ---
# hostapd-basic-mbedtls, not wpad: this board is only ever an access point, and
# the AP-only binary is 159,744 bytes smaller in the image (measured).
CONFIG_PACKAGE_kmod-sf_smac=y
CONFIG_PACKAGE_kmod-cfg80211=y
CONFIG_PACKAGE_hostapd-basic-mbedtls=y
CONFIG_PACKAGE_iw=y
EOF
if [ "$WITH_LUCI" = 1 ]; then
	cat >> .config <<'EOF'
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-ssl=y
EOF
fi
if [ "$WITH_SLABINFO" = 1 ]; then
	# Debug only. On 6.18 /proc/slabinfo is gated by CONFIG_SLUB_DEBUG; the
	# runtime checks stay off unless slab_debug= is on the kernel command line.
	# It changes the kernel config, so out-of-tree modules must be rebuilt
	# against it (CLAUDE.md section 12, "Stale out-of-tree modules").
	echo "CONFIG_KERNEL_SLUB_DEBUG=y" >> .config
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
