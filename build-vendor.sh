#!/usr/bin/env bash
# Build the Banana Pi vendor OpenWrt 18.06 SDK for the BPI-WiFi5, with
# STANDARD LuCI instead of the vendor's LuCI2 skin.
#
# Kernel 4.14.90, vendor WiFi + ethernet drivers - everything that works on
# your stock firmware keeps working. Nothing is ported.
#
# Builds inside an Ubuntu 18.04 container because OpenWrt 18.06's host tools
# do not compile against a modern GCC/glibc.
#
# SECURITY: by default this removes two hardcoded vendor accounts before
# building (see harden_accounts below). Use --keep-vendor-accounts to skip.
#
# Usage:
#   ./build-vendor.sh                    # standard LuCI (target a28_bpi)
#   ./build-vendor.sh a28_bpi_luci2      # vendor skin, for comparison
#   ./build-vendor.sh --audit-only       # run the account audit, do not build
#   ./build-vendor.sh --shell            # container shell, to poke around
set -euo pipefail

REPO_URL="https://github.com/BPI-SINOVOIP/BPI-WiFi5-Siflower.git"
BRANCH="${BRANCH:-main}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/vendor-sdk"
TARGET="a28_bpi"
SHELL_ONLY=0
AUDIT_ONLY=0
HARDEN=1

while [ $# -gt 0 ]; do
	case "$1" in
		--shell)                 SHELL_ONLY=1 ;;
		--audit-only)            AUDIT_ONLY=1 ;;
		--keep-vendor-accounts)  HARDEN=0 ;;
		-h|--help)               sed -n '2,20p' "$0"; exit 0 ;;
		-*)                      echo "unknown option: $1" >&2; exit 1 ;;
		*)                       TARGET="$1" ;;
	esac
	shift
done

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  + %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

# =============================================================== hardening ==
# The vendor tree ships /etc/shadow with real password hashes baked in:
#
#   root:$1$wEehtjxj$YBu4quNfVUjzfv8p/PBo5.:...   MD5-crypt, same on every unit
#   sfroot:gDsCJlw5I2WPw:...                      legacy DES, trivially cracked
#
# plus an undocumented sfroot account (uid 1000) in /etc/passwd. Official
# OpenWrt ships an empty root password and prompts on first boot. We restore
# that behaviour and delete sfroot entirely.
harden_accounts() {
	local base="$SRC/openwrt-18.06/package/base-files/files/etc"
	local pw="$base/passwd" sh="$base/shadow"

	[ -f "$pw" ] || die "$pw not found - unexpected tree layout"
	[ -f "$sh" ] || die "$sh not found - unexpected tree layout"

	# Keep pristine copies once, so re-runs stay idempotent and you can diff.
	[ -f "$pw.vendor-orig" ] || cp "$pw" "$pw.vendor-orig"
	[ -f "$sh.vendor-orig" ] || cp "$sh" "$sh.vendor-orig"

	say "Auditing shipped accounts"
	echo "  --- as shipped by the vendor ---"
	sed 's/^/    /' "$sh.vendor-orig"

	if [ "$HARDEN" = 0 ]; then
		warn "--keep-vendor-accounts given: leaving hardcoded credentials in place"
		warn "the image will ship a known root password and an sfroot account"
		return
	fi

	# 1. Blank root's password -> OpenWrt prompts you to set one on first boot.
	sed -i 's|^root:[^:]*:|root::|' "$sh"
	# 2. Remove the sfroot service account from both files.
	sed -i '/^sfroot:/d' "$pw" "$sh"

	# ---- verify, and fail the build if anything did not take ----
	grep -q '^root::' "$sh" || die "failed to blank the root password"
	! grep -q '^sfroot:' "$sh" || die "failed to remove sfroot from shadow"
	! grep -q '^sfroot:' "$pw" || die "failed to remove sfroot from passwd"
	ok "root password blanked (you will set it on first boot)"
	ok "sfroot account removed from passwd and shadow"

	# ---- generic catch-all: flag ANY remaining account with a real hash.
	# Valid entries have an empty field or '*' (login disabled). Anything
	# else is a preset credential, including ones added after this was written.
	local leftover
	leftover=$(awk -F: '$2 != "" && $2 != "*" && $2 != "!" {print $1}' "$sh" || true)
	if [ -n "$leftover" ]; then
		warn "accounts still carrying a password hash: $leftover"
		warn "inspect $sh before flashing"
	else
		ok "no account ships with a preset password hash"
	fi

	echo "  --- after hardening ---"
	sed 's/^/    /' "$sh"
}

# ============================================================ prerequisites ==
if command -v docker >/dev/null 2>&1; then
	ENGINE=docker
elif command -v podman >/dev/null 2>&1; then
	ENGINE=podman
else
	die "install docker or podman first:
  sudo apt install docker.io
  sudo usermod -aG docker \$USER    # then log out and back in"
fi
$ENGINE info >/dev/null 2>&1 || die "$ENGINE is installed but not usable.
If you just added yourself to the docker group, log out and back in."

# --------------------------------------------------------------- get source --
# Full clone, not shallow: make.sh reads git branch/tag metadata for the
# version string and fails on a shallow or detached checkout.
if [ ! -d "$SRC/.git" ]; then
	say "Cloning the vendor SDK (large - several GB, allow plenty of time)"
	git clone --single-branch -b "$BRANCH" "$REPO_URL" "$SRC"
else
	say "Reusing existing $SRC"
fi
[ -d "$SRC/openwrt-18.06" ] || die "openwrt-18.06/ not found - wrong branch?"

harden_accounts

if [ "$AUDIT_ONLY" = 1 ]; then
	say "Audit complete (--audit-only). Nothing was built."
	exit 0
fi

# ------------------------------------------------------------ builder image --
# 18.04 is in ESM, so bionic is STILL on archive.ubuntu.com - it has not moved
# to old-releases (which 404s for bionic). Override if your region needs it:
#   UBUNTU_MIRROR=mirror.example.org/ubuntu ./build-vendor.sh
UBUNTU_MIRROR="${UBUNTU_MIRROR:-archive.ubuntu.com/ubuntu}"

# IMPORTANT: build the image from a throwaway directory holding ONLY the
# Dockerfile. Using $HERE would ship the whole multi-GB vendor-sdk/ tree to the
# daemon as build context on every run.
CTX="$(mktemp -d)"
trap 'rm -rf "$CTX"' EXIT

cat > "$CTX/Dockerfile" <<DOCKERFILE
FROM ubuntu:18.04
ENV DEBIAN_FRONTEND=noninteractive
RUN printf '%s\n' \\
      "deb http://${UBUNTU_MIRROR} bionic main universe" \\
      "deb http://${UBUNTU_MIRROR} bionic-updates main universe" \\
      > /etc/apt/sources.list && \\
    apt-get update && apt-get install -y --no-install-recommends \\
      build-essential make gcc g++ device-tree-compiler bc libncurses5-dev \\
      perl-modules-5.26 patch gawk unzip python python3 git wget curl file \\
      rsync subversion gettext libssl-dev zlib1g-dev xsltproc \\
      swig time ca-certificates sudo && \\
    rm -rf /var/lib/apt/lists/*
ARG UID=1000
ARG GID=1000
RUN groupadd -g \$GID builder 2>/dev/null || true && \\
    useradd -m -u \$UID -g \$GID builder 2>/dev/null || true
USER builder
WORKDIR /src
DOCKERFILE

say "Checking the container can reach $UBUNTU_MIRROR"
if ! $ENGINE run --rm --network=host ubuntu:18.04 \
	sh -c "cat /etc/resolv.conf >/dev/null; exit 0" >/dev/null 2>&1; then
	warn "could not start a test container; continuing anyway"
fi

say "Building the Ubuntu 18.04 builder image"
# --network=host makes the build use the host's networking and DNS, which
# avoids the container resolver landing on a proxy's fake-IP range.
if ! $ENGINE build --network=host \
	--build-arg UID="$(id -u)" --build-arg GID="$(id -g)" \
	-t bpi-vendor-builder "$CTX"; then
	die "builder image failed.

If apt printed 404s, the mirror does not carry bionic. Find one that does:

  for m in archive.ubuntu.com/ubuntu \\
           mirror.seas.harvard.edu/ubuntu \\
           old-releases.ubuntu.com/ubuntu ; do
    printf '%-45s ' \"\$m\"
    curl -s -o /dev/null -w '%{http_code}\\n' \"http://\$m/dists/bionic/Release\"
  done

then re-run with the one that returned 200:
  UBUNTU_MIRROR=<that/path> ./build-vendor.sh

If instead the failing IP was in 198.18.x.x, a VPN or proxy client (Clash,
Surge and similar use 198.18.0.0/16 for fake-IP DNS) is hijacking lookups:
turn it off, or point Docker at a real resolver:
  sudo mkdir -p /etc/docker
  echo '{\"dns\": [\"1.1.1.1\"]}' | sudo tee /etc/docker/daemon.json
  sudo systemctl restart docker"
fi

# -------------------------------------------------------------------- build --
RUN_ARGS=(--rm -it -v "$SRC:/src:z" -w /src bpi-vendor-builder)

if [ "$SHELL_ONLY" = 1 ]; then
	say "Container shell. Source is at /src. Build with:"
	echo "  cd /src/openwrt-18.06 && ./make.sh $TARGET"
	exec $ENGINE run "${RUN_ARGS[@]}" /bin/bash
fi

say "Building target: $TARGET  (first run downloads a lot; 1-3 hours)"
$ENGINE run "${RUN_ARGS[@]}" /bin/bash -c "
	set -e
	cd /src/openwrt-18.06
	./make.sh $TARGET
" 2>&1 | tee "$HERE/build-vendor.log"

# ------------------------------------------------------------------ results --
say "Output images"
find "$SRC/openwrt-18.06" -maxdepth 2 -name '*.bin' -newermt '-6 hours' \
	-printf '%10s  %p\n' 2>/dev/null | sort -rn | head -20
find "$SRC/openwrt-18.06/bin" -name '*sysupgrade*' -o -name '*.bin' 2>/dev/null | head -20

cat <<'EOF'

------------------------------------------------------------------------
Image must be <= 7733248 bytes to fit the firmware partition (8 MiB NOR).

Accounts: root has NO password in this image. Set one immediately on
first boot, over serial or via the LuCI first-login prompt, before the
router is reachable from anywhere untrusted.

STILL UNAUDITED: the closed WiFi firmware blobs (sf1688_hb_fmac.bin,
sf1688_lb_fmac.bin, rf_pmem.bin) and the compiled thermal daemon. Static
review cannot clear binaries. This is true of the stock firmware too.

To flash: stock web UI at http://192.168.4.1 (password admin)
  More -> System -> Backup/Upgrade -> Flash image
  UNCHECK "keep settings", then Continue.

Do not flash until mtd0-mtd4 backups are saved and size-checked.
------------------------------------------------------------------------
EOF
