# OpenWrt for Banana Pi BPI-WiFi5

Two prebuilt firmware images for the **Banana Pi BPI-WiFi5** (Siflower
SF19A2890), a board with no official OpenWrt support, and the patches that make
the second one work.

| | [v1.0](../../releases/tag/v1.0) | [v2.0](../../releases/tag/v2.0) |
|---|---|---|
| Base | vendor OpenWrt 18.06 | mainline OpenWrt snapshot |
| Kernel | 4.14.90 (vendor fork) | 6.18.35 |
| WiFi | 2.4 GHz + 5 GHz | **none** |
| Ethernet | 4 ports, vendor driver | 4 ports, DSA |
| LuCI | standard | standard |
| Free overlay space | ~1.0 MB | ~784 KB |
| Security updates | none, EOL since 2020 | current |
| Build script | `build-vendor.sh` | `build.sh` |

v1.0 is the image to use for a working access point. v2.0 is the image to use
for a modern kernel on a wired router. Neither is official OpenWrt.

---

## Read this before flashing either image

- **Both images ship with NO root password.** That is intentional — the vendor
  ships a preset one (see below). Set your own immediately on first boot,
  before connecting the router to anything untrusted.
- **BPI-WiFi5 only.** Flashing either on another Siflower board will brick it.
- **Assumes 8 MiB SPI-NOR.** This unit has a ZB25VQ64A (8 MiB) even though the
  vendor device tree asks for a W25Q128 (16 MiB). Check first:
  `dmesg | grep m25p80`.
- **Back up the flash first.** Instructions below. Not optional.
- **v2.0 has no WiFi at all.** Both radios are absent, not degraded.

---

## Back up the flash first

From the firmware currently installed, over SSH. Old dropbear needs the legacy
crypto flags:

```sh
for i in 0 1 2 3 4; do
  ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
      -o KexAlgorithms=+diffie-hellman-group14-sha1 \
      root@192.168.4.1 "cat /dev/mtd${i}ro" > mtd${i}.bin
done
ls -l mtd*.bin
```

Stock vendor defaults: `192.168.4.1`, user `root`, password `admin`.

| file | partition | bytes |
|---|---|---|
| mtd0.bin | spl-loader | 131072 |
| mtd1.bin | u-boot | 393216 |
| mtd2.bin | u-boot-env | 65536 |
| mtd3.bin | factory | 65536 |
| mtd4.bin | firmware | 7733248 |

`mtd3.bin` holds the MAC address and the RGMII delay calibration for this
specific board. `mtd4.bin` is the complete current firmware — that is what gets
restored if a build does not work out. Copy them off the machine.

---

## Hardware notes

- **8 MiB SPI-NOR** (ZB25VQ64A), where the vendor device tree specifies a
  16 MiB W25Q128. The firmware partition is 7,733,248 bytes.
- **64 MiB DDR2**, not the 128 MiB the mainline device tree declared.
- Partition layout: `spl-loader`, `u-boot`, `u-boot-env`, `factory` at
  0x90000, `firmware` at 0xa0000.
- Serial console header inside the case: 3.3 V, 115200 8N1.
- U-Boot runs `preboot=btn_httpd_detect 192.168.4.1`. Holding reset at power-on
  starts a web recovery server, so the board is difficult to brick permanently.

---

## v1.0 — vendor OpenWrt 18.06 with standard LuCI

Replaces the vendor's LuCI2 skin with standard LuCI and removes two hardcoded
credentials. WiFi and all four ethernet ports work, because this uses the
vendor's own kernel and drivers. Nothing was ported.

### What it changes vs stock

| | Stock | v1.0 |
|---|---|---|
| Web UI | vendor LuCI2 skin | standard LuCI |
| `root` password | preset MD5 hash, same on every unit | **blank** |
| `sfroot` account | present, uid 1000, legacy DES hash | **removed** |
| Kernel, WiFi driver, ethernet | vendor 4.14.90 | identical, untouched |
| Free overlay space | ~576 KB | ~1.0 MB |

### About those accounts

Banana Pi's published SDK ships `package/base-files/files/etc/shadow`
containing:

```
root:$1$wEehtjxj$YBu4quNfVUjzfv8p/PBo5.:0:0:99999:7:::
sfroot:gDsCJlw5I2WPw:18372:0:99999:7:::
```

plus an undocumented `sfroot` account (uid 1000) in `/etc/passwd`. The root hash
is MD5-crypt and identical across every unit; `sfroot` uses legacy DES, which is
brute-forceable in minutes. Official OpenWrt ships an empty password field and
prompts for one on first login.

This build blanks root and deletes `sfroot`, and fails the build rather than
producing an image if either edit does not take. Verify after flashing:

```sh
cat /etc/shadow      # root:: and no sfroot line
```

### Other things worth knowing about the stock firmware

- **OTA auto-update is enabled by default**, pointing at the vendor's servers.
  This build does not include the OTA client.
- The default config defines `guest` (10.0.0.1) and `lease` (10.2.0.1)
  networks, and a Chinese-language "租赁" (rental) SSID — leftovers from the
  vendor's rental-property deployment model. Harmless, removable with
  `uci delete`.
- An audit of every script and readable C source in the vendor tree found **no**
  phone-home URLs, no telemetry, no suspicious cron jobs or init scripts. The
  closed WiFi firmware blobs and one compiled thermal daemon were **not**
  audited — static review cannot clear binaries. This is equally true of the
  stock firmware.
- OpenWrt 18.06 reached end of life in 2020. No security updates. Not suitable
  for an internet edge; reasonable behind another firewall or as a pure access
  point.

### Flashing v1.0

Through the stock web UI. No serial console needed.

1. Wire the PC to a **LAN** port (not WAN). Not over WiFi.
2. `http://192.168.4.1`, log in with `admin`.
3. **System → Backup/Upgrade → Flash new firmware image → Flash image…**
   - Not "OTA upgrade" (fetches vendor firmware)
   - Not "Upload factory" (writes the factory partition)
4. **UNCHECK "Keep settings."** The vendor config format will not survive.
5. Upload the `.bin`, confirm the checksum, then leave it alone for 5 minutes.
6. Reconnect to `http://192.168.4.1` — same address as stock.
7. **Set a root password immediately**: System → Administration.
8. Set WiFi encryption: Network → Wireless. Both radios come up **open** by
   default. Set WPA2-PSK on each, then confirm with `iwinfo` that
   `Encryption:` no longer reads `none`.

LuCI needs **Save & Apply** — pressing Enter in a field does not commit.

### Building v1.0

```sh
./build-vendor.sh --audit-only   # show the shipped accounts, build nothing
./build-vendor.sh                # full build, 2-4 hours, ~30 GB disk
```

Builds inside an Ubuntu 18.04 container, because OpenWrt 18.06's host tools do
not compile against a modern GCC. Requires Docker or Podman. Must not run as
root — OpenWrt refuses to build as root, and the script mirrors the caller's
UID into the container.

Source: <https://github.com/BPI-SINOVOIP/BPI-WiFi5-Siflower>, branch `main`.

---

## v2.0 — mainline OpenWrt, Linux 6.18

Current OpenWrt snapshot and current LuCI, with all four gigabit ports working
through DSA. **No WiFi.** No mainline driver exists for the Siflower radio.

Also absent: hardware NAT offload. The vendor's `sfhnat` has no mainline
equivalent, so routing is CPU-bound on four 530 BogoMIPS MIPS cores.

### Building v2.0

```sh
./build.sh --luci
```

Runs natively on a modern distribution. Requires ~25 GB and `gawk` as the
default `awk`. Clones
[ulli-kroll/openwrt](https://github.com/ulli-kroll/openwrt) branch
`openwrt-siflower/v6.18/sf19/master`, pinned to commit `3dcbd927`, and applies
the patches in `patches/`. The SoC and switch support in that branch is his
work; the patches below are the fixes needed on top of it.

### Flashing v2.0

The LuCI upload and `scp` both fail on this board: the initramfs rootfs already
occupies ~18 MB of a 48 MB tmpfs, and staging a 6.6 MB image on top triggers the
OOM killer, which works through every service and ends in a kernel panic. Stream
the image straight to flash instead.

Boot the initramfs over TFTP (see below), then from the build machine:

```sh
ssh root@192.168.9.1 "mtd -r write - firmware" \
  < openwrt-siflower-sf19a2890-bananapi_wifi5-squashfs-sysupgrade.bin
```

`mtd write -` reads from stdin, so nothing is buffered to RAM. `-r` reboots when
the write completes. Expect a couple of minutes of erase and write activity on
the serial console; do not interrupt it.

**Run `firstboot` after the first boot.** The JFFS2 overlay is not formatted
automatically — the first boots fall back to a tmpfs overlay and settings are
lost on reboot:

```sh
firstboot
reboot
```

After that, `mount_root: switching to jffs2 overlay` appears in the boot log and
`df -h /overlay` reports `/dev/mtdblock7`.

### Trying v2.0 without flashing

The initramfs image boots entirely from RAM and leaves the installed firmware
untouched. See `tftp-boot-procedure.pdf` for the full procedure. In short: place
it in a TFTP root, interrupt U-Boot on the serial console, then

```
setenv ipaddr 192.168.4.2
setenv serverip 192.168.4.100
ping 192.168.4.100
tftpboot 0x81000000 openwrt-siflower-sf19a2890-bananapi_wifi5-initramfs-kernel.bin
bootm 0x81000000
```

Power-cycling returns the board to whatever is in flash. This is how v2.0 was
developed and tested.

---

## The four patches

Getting ethernet working required fixing four bugs. Two are in the shared
`an8855` DSA driver and affect any board using that switch in RGMII mode.

### 0001 — make the image flashable

The BPI-WiFi5 device tree lacked `compatible = "denx,uimage"` on the firmware
partition, so mtdsplit never split it into kernel + rootfs and a flashed
squashfs had no rootfs to mount. This is why only initramfs boots had ever been
tested. Also adds the missing `board.d` network configuration, an `IMAGE_SIZE`
check, the correct 64 MiB memory size, and the RGMII delay nvmem cell.

Includes a fix in `dwmac-sf19a2890.c`: the driver passed a 4-byte unterminated
nvmem buffer directly to `kstrtou16()`, which parses past the end of the
allocation and fails. The error was then discarded, so the SoC delay registers
were never written and nothing reported it.

### 0002 — phy-mode and FIFO depth

Adds `tx-fifo-depth` and `rx-fifo-depth` to the gmac node. Note these have no
`snps,` prefix, unlike neighbouring properties. Without them
`plat->tx_fifo_size` stays 0, `stmmac_change_mtu()` falls back to the hardware
capability register — which reports **0** on this SoC — and then rejects every
MTU value, including ones below the current MTU:

```
an8855-switch: nonfatal error -22 setting MTU to 1500 on port 0
sf19a2890-gmac eth0: error -22 setting MTU to 1504 to include DSA overhead
```

DSA could therefore never reserve its 4 tag bytes on the conduit.

### 0003 — optional device tree override for the RGMII delay

For experimentation only; not enabled by default. The factory calibration value
is correct, and the vendor driver uses it identically.

### 0004 — the AN8855 switch fixes

Two bugs in `an8855.c`.

The first corrupts `PMCR` on every link event:

```c
reg = regmap_read(priv->regmap, AN8855_PMCR_P(port), &reg);
```

The return code is assigned over the value just read, so `reg` becomes 0 and the
register is rebuilt from zero, silently discarding `MAC_MODE`, `IFG_XMIT` and
`BACKOFF_EN` that `mac_config()` set moments earlier.

The second is the one that prevented any traffic at all. `RG_FORCE_MAC5_SB` at
`ETHER_SYS_BASE + 0x2c` (`0x1028c82c`) must be forced to the link speed; the
mainline driver leaves it at its reset value of 0. With it at 0, the RGMII link
between switch and SoC comes up, both sides report 1 Gbps full duplex, every
port matrix and forwarding mask is correct, the DMA is armed and interrupts are
enabled — and no frame crosses in either direction, with zero errors, drops or
CRC failures recorded anywhere.

The vendor writes it per link speed in `air_port_setRgmiiMode()`:

| link speed | value |
|---|---|
| 1000 Mbps | `0x00020101` |
| 100 Mbps | `0x00010101` |
| 10 Mbps | `0x00000101` |

This is why "ethernet works" in the upstream branch meant the link comes up, not
that frames pass. Link state looks identical either way, and testing over a
serial console does not exercise the data path.

---

## WiFi on mainline (v3.0)

No date. The vendor driver is roughly 60,000 lines of cfg80211 FullMAC code
derived from RivieraWaves/Ceva IP, targeting the cfg80211 API of Linux 4.19.7 —
confirmed from the running vendor firmware, which loads
`backports.git v4.19.7-1`. The newest kernel version guard anywhere in the
source is `KERNEL_VERSION(4, 19, 0)`, despite the repository advertising
Linux 6.6 support. The LMAC ships only as binary blobs
(`sf1688_hb_fmac.bin`, `sf1688_lb_fmac.bin`) with no licence attached.

Porting means seven years of cfg80211 API churn — the 6.0 multi-link `link_id`
changes, `dev_addr` becoming const in 5.17, procfs and NAPI signature changes —
plus replacing the vendor's custom factory-read module with nvmem.

Flash space is tight but not obviously fatal. As flashed, v2.0 leaves a 860 KB
JFFS2 overlay (784 KB free) and the kernel occupies 3.2 MB of the 7.37 MB
firmware partition. The WiFi stack needs roughly 1.25 MB, so it does not fit
alongside the diagnostic tools: removing `tcpdump`, `ethtool`, `mdio-tools` and
`ip-full` frees about 590 KB, and further trimming (`wpad-basic-mbedtls`,
dropping IPv6 or PPP) would be needed on top of that.

Discussion:
<https://forum.openwrt.org/t/sf19a2890-commit-possible-new-devices/210739>

---

## Licensing

The OpenWrt components are GPL-2.0 and other free licences; corresponding source
is the upstream trees linked above, plus the build scripts and patches in this
repository, which are the complete set of modifications.

The WiFi firmware blobs (`sf1688_hb_fmac.bin`, `sf1688_lb_fmac.bin`,
`rf_pmem.bin`) and the Siflower kernel modules in v1.0 come from Banana Pi's
SDK. **It carries no LICENSE file, no SPDX headers, and no explicit
redistribution grant**, while several modules declare `MODULE_LICENSE("GPL")`.
This unresolved licensing is why v1.0 cannot be upstreamed to OpenWrt.
Redistributed here on the basis that Banana Pi publishes the SDK openly; will be
removed on request from a rights holder.

Not affiliated with or endorsed by OpenWrt, Banana Pi/SINOVOIP, or Siflower.
