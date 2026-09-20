# OpenWrt for the Banana Pi BPI-WiFi5

The Banana Pi BPI-WiFi5 (SINOVOIP, Siflower SF19A2890) is a four-port dual-band
wireless router with no official OpenWrt support. This repository builds OpenWrt
for it. It contains the build scripts, the device tree and platform patches, and
a port of the vendor WiFi driver to a mainline kernel.

Prebuilt images are attached to the releases. Everything needed to reproduce
them is in this repository. None of it is official OpenWrt, and it is not
affiliated with or endorsed by OpenWrt, Banana Pi/SINOVOIP, Airoha or Siflower.

## Images

| | [v1.0](../../releases/tag/v1.0) | [v2.0](../../releases/tag/v2.0) | [v3.0](../../releases/tag/v3.0) |
|---|---|---|---|
| Base | vendor OpenWrt 18.06 | mainline snapshot | mainline snapshot |
| Kernel | 4.14.90 (vendor fork) | 6.18.35 | 6.18.35 |
| WiFi | 2.4 + 5 GHz, vendor driver | none | 2.4 + 5 GHz, ported driver |
| Ethernet | 4 ports, vendor driver | 4 ports, DSA | 4 ports, DSA |
| LuCI | standard | standard | standard |
| Security updates | none, base is end of life | current | current |
| Free overlay | ~1.0 MB | ~784 KB | ~380 KB |
| Build script | `build-vendor.sh` | (v2.0 tag) | `build.sh` |

v3.0 is the image to use. v1.0 exists as a fallback for anyone who needs the
vendor kernel. v2.0 is superseded and kept for reference.

## What v3.0 is

A current OpenWrt snapshot on Linux 6.18.35, with LuCI, all four gigabit ports
through DSA, and both radios driven by the Siflower FullMAC driver ported to
mainline. Image size is 7,340,309 bytes of the 7,733,248-byte firmware
partition.

Measured on the flashed image with a 12 V supply and a USB client:

| | 2.4 GHz, ch 6 HT20 | 5 GHz, ch 36 VHT80 |
|---|---|---|
| TCP download | 98-102 Mbit/s | 170-207 Mbit/s |
| TCP upload | 51 Mbit/s | 87 Mbit/s |
| Sustained download | 101 Mbit/s over 10 min | 193 Mbit/s over 5 min |
| RF die temperature under that load | 60-64 °C | 53-65 °C |
| CPU idle | 89 % | 65 % |
| MemAvailable, minimum | 14.2 MB | 14.1 MB |

Idle, with both radios up: RF die 46-52 °C, MemAvailable about 15 MB, CPU 99 %
idle. The full test record, including association, power-save and thermal
results, is in [`driver/README.md`](driver/README.md).

These figures were taken with the client about 10 cm from the board, which is
too close for 5 GHz and understates what normal range performance looks like.

## Before you start

- **Use a 12 V / 1 A supply** (5.5/2.1 mm barrel, centre positive). Underpowered
  adapters brown the board out under sustained 5 GHz transmit, which presents as
  a spontaneous reset with nothing in the kernel log. Check the adapter label
  before investigating any reset, noise or heat on this board.
- Images ship with no root password. Set one on first boot, before the router is
  connected to anything untrusted.
- These images are for the BPI-WiFi5 only. Flashing them on another Siflower
  board will brick it.
- An 8 MiB SPI-NOR chip is assumed. Units carry a ZB25VQ64A (8 MiB) even though
  the vendor device tree asks for a 16 MiB W25Q128. Confirm with
  `dmesg | grep m25p80`. Use `build.sh --flash 16` only for a confirmed 16 MiB
  chip.
- Back up the flash before writing anything. One of the partitions holds
  per-unit data that cannot be regenerated.
- A serial console is strongly recommended. The header is inside the case:
  3.3 V, 115200 8N1.

## Backing up the flash

From the installed firmware, over SSH. Old dropbear needs legacy crypto flags:

```sh
for i in 0 1 2 3 4; do
  ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
      -o KexAlgorithms=+diffie-hellman-group14-sha1 \
      root@192.168.4.1 "cat /dev/mtd${i}ro" > mtd${i}.bin
done
ls -l mtd*.bin
```

Stock vendor defaults are `192.168.4.1`, user `root`, password `admin`.

| file | partition | bytes |
|---|---|---|
| mtd0.bin | spl-loader | 131072 |
| mtd1.bin | u-boot | 393216 |
| mtd2.bin | u-boot-env | 65536 |
| mtd3.bin | factory | 65536 |
| mtd4.bin | firmware | 7733248 |

`mtd3.bin` is the critical one. It holds the MAC address, the RGMII delay
calibration, and a per-unit RF transmit-power calibration table that cannot be
regenerated. `mtd4.bin` is the complete current firmware and the way back. Copy
both off the machine before flashing.

## Installing

The LuCI upload does not work on this board. `cgi-io` has no session to
authorise against when no root password is set, and staging a 7 MB image in
`/tmp` competes for the memory the driver needs. Stream the image to flash
instead, from whatever firmware is currently installed:

```sh
ssh root@<board-ip> "mtd -r write - firmware" < <image>-squashfs-sysupgrade.bin
```

`mtd write -` reads from stdin, so nothing is buffered. `-r` reboots when the
write completes. Watch it on the serial console and do not interrupt it.

Afterwards, confirm the JFFS2 overlay formatted:

```sh
df -h /overlay      # expect /dev/mtdblock7, not a tmpfs
```

If it shows a tmpfs, run `firstboot` then `reboot`, otherwise settings are lost
on every restart.

A healthy boot log contains `dual antenna calibration is on`,
`txpower calibration table use factory info`, `lmac init complete(0)` and `(1)`,
and two `New interface create wlan` lines.

Configuration has to be re-applied after flashing. See *Known issues*.

## Trying it without flashing

The initramfs image boots entirely from RAM and leaves the installed firmware
untouched. Place it in a TFTP root, interrupt U-Boot on the serial console,
then:

```
setenv ipaddr 192.168.4.2
setenv serverip 192.168.4.100
ping 192.168.4.100
tftpboot 0x82000000 <image>-initramfs-kernel.bin
bootm 0x82000000
```

Two details matter. The load address is 0x82000000, not the 0x81000000 that
works for a WiFi-less image, because an initramfs carrying the driver and
firmware blobs decompresses over its own compressed image at the lower address.
And send a bare newline after interrupting autoboot, or leftover keystrokes in
U-Boot's line buffer corrupt the first command.

Power-cycling returns the board to whatever is in flash.

## Building from source

```sh
./build.sh --luci
```

Builds natively on a modern distribution. Needs roughly 25 GB of disk and
`gawk` as the default `awk`. The script clones
[ulli-kroll/openwrt](https://github.com/ulli-kroll/openwrt) branch
`openwrt-siflower/v6.18/sf19/master` at commit `3dcbd927`, clones
[Siflower/sf_wifi](https://github.com/Siflower/sf_wifi) at `da991faf`, applies
the driver port and the six patches, and fetches the two LMAC firmware blobs
from a pinned public Banana Pi SDK commit, verified by MD5. A mismatch aborts
the build.

Options: `./build.sh` for no LuCI, `--flash 16` for a confirmed 16 MiB chip,
`--slabinfo` for a kernel with `/proc/slabinfo`, `--verbose` for `make -j1 V=s`,
`--clean` to wipe `bin/` and `build_dir`.

## Known issues

- **`sysupgrade` does not keep settings on this board.** The upgrade logs that
  it appended the configuration archive, then boots with a freshly generated
  `/etc/config`. LuCI's "keep settings" is affected the same way. Re-apply
  configuration after flashing, over serial if WiFi was the only link.
- **The status LED is blue where the vendor firmware shows red.** WiFi LED
  support is not part of this build.
- **No hardware NAT offload.** The vendor's `sfhnat` has no mainline
  equivalent, so routing is CPU-bound.
- **Three SSIDs per band.** The driver is built for the LMAC firmware layout
  that this image ships, which allows three virtual interfaces per radio.
- **Memory is tight.** Two radios cost about 14 MB of the roughly 48 MB that
  reaches Linux. Patch 0006 lowers `vm.min_free_kbytes` to 2048 to keep the OOM
  killer away from hostapd under load.
- **Package feeds are not pinned** in `build.sh`, so a rebuild is functionally
  equivalent but not byte-identical.
- Fixed `option txpower` is handled differently by the radio firmware than
  automatic power control, and reports lower values in debugfs. A `country`
  change persists in the driver until reboot.

## The hardware

- SoC: Siflower SF19A2890, 4 MIPS interAptiv VPEs at roughly 530 BogoMIPS.
- 8 MiB SPI-NOR (ZB25VQ64A). The firmware partition is 7,733,248 bytes.
- 64 MiB DDR2. 4 MiB is reserved for the WiFi DSP and roughly 48 MiB reaches
  Linux.
- Switch: Airoha AN8855, 5 ports, RGMII to the SoC, port 5 is the CPU port.
- Radios: two, 2x2 each, with an external PA on 5 GHz only.
- Power: 12 V / 1 A, 5.5/2.1 mm barrel, centre positive.
- Serial console header inside the case: 3.3 V, 115200 8N1.
- U-Boot runs `preboot=btn_httpd_detect 192.168.4.1`. Holding reset at power-on
  starts a web recovery server, so the board is difficult to brick permanently.
- The `factory` partition holds the MAC at 0x0, a cooling-temperature pair at
  0xae, a 4-byte ASCII RGMII delay at 0xb2, and a `"V4"` RF calibration table at
  0x800. Without that table the radios transmit roughly 32 dB low on 2.4 GHz and
  11 dB low on 5 GHz.
- The only temperature sensor is inside the RF block. There is no SoC die
  sensor and no cpufreq support in mainline for this SoC.

## The patches

Applied by `build.sh` in order. Patches 0001 to 0004 are platform and ethernet
work; 0005 and 0006 are what the WiFi driver needs from the system around it.

### 0001: make the image flashable

Adds `compatible = "denx,uimage"` on the firmware partition, the missing
`board.d` network configuration, the correct 64 MiB memory size, an `IMAGE_SIZE`
check, and the RGMII delay nvmem cell.

Also fixes `dwmac-sf19a2890.c`, which passed a 4-byte unterminated nvmem buffer
straight to `kstrtou16()`. That parses past the end of the allocation and fails,
the error is discarded, and the SoC delay registers are never written.

### 0002: phy-mode and FIFO depth

Adds `tx-fifo-depth` and `rx-fifo-depth`, which unlike their neighbours carry no
`snps,` prefix. Without them `plat->tx_fifo_size` stays 0, `stmmac_change_mtu()`
falls back to the hardware capability register, which reports 0 on this SoC, and
then rejects every MTU value including ones below the current one. DSA can never
reserve its 4 tag bytes.

### 0003: optional device tree override for the RGMII delay

Available for experimentation. Not enabled, since the factory value is correct.

### 0004: AN8855 switch fixes

Two bugs in the shared switch driver, affecting any board that uses it in RGMII
mode.

`an8855_phylink_mac_link_up()` contains
`reg = regmap_read(priv->regmap, AN8855_PMCR_P(port), &reg)`. The return code
lands on the value just read, so `reg` becomes 0 and the register is rebuilt
from zero on every link event.

`RG_FORCE_MAC5_SB` at `0x1028c82c` is never programmed. Left at its reset value
of 0, the link between switch and SoC comes up, both sides report 1 Gbps full
duplex, port matrices and forwarding masks are correct, DMA is armed and
interrupts are enabled, and no frame crosses in either direction with zero
errors recorded anywhere. The vendor writes it per link speed in
`air_port_setRgmiiMode()`, as `0x20101` / `0x10101` / `0x101`. This is the
difference between a link that comes up and a link that passes frames; link
state looks identical either way, and testing over a serial console does not
exercise the data path.

### 0005: WiFi device tree nodes

The two per-band MAC nodes the mainline dtsi lacks, without which the driver
cannot probe, plus the RF interrupt polarity, `force_expa` for the 5 GHz front
end, and the dual-antenna calibration flag.

### 0006: memory watermark

Sets `vm.min_free_kbytes = 2048` through `sysctl.d`. The kernel picks 8192 on a
system this size and then refuses to hand out the last 8 MB, killing processes
instead.

## The WiFi driver

The driver is the vendor's cfg80211 FullMAC stack, ported from its Linux 4.19
API target to 6.18 and adapted to this board. The sources are not redistributed
here; `build.sh` clones them at a pinned commit and applies the port as a patch.

[`driver/README.md`](driver/README.md) covers what the driver is, what was
changed in it, how the package is configured, and the test results.

## v1.0: vendor OpenWrt 18.06 with standard LuCI

The vendor kernel and drivers, so everything that works on the stock firmware
keeps working. Nothing is ported. Two things are changed: the vendor's LuCI2
skin is replaced by standard LuCI, and the two hardcoded accounts described
below are removed.

### What this build fixes

Banana Pi's published SDK ships `package/base-files/files/etc/shadow`
containing:

```
root:$1$wEehtjxj$YBu4quNfVUjzfv8p/PBo5.:0:0:99999:7:::
sfroot:gDsCJlw5I2WPw:18372:0:99999:7:::
```

plus an undocumented `sfroot` account (uid 1000) in `/etc/passwd`. The root hash
is MD5-crypt and identical on every unit; `sfroot` uses legacy DES, which is
trivially cracked.

**Both accounts are removed.** The build blanks root's password, so OpenWrt
prompts for one on first boot, and deletes `sfroot` from `passwd` and `shadow`.
It then verifies all three edits and aborts rather than producing an image if
any of them did not take, and warns if any other account is left carrying a
password hash. `--audit-only` prints the shipped accounts and builds nothing;
`--keep-vendor-accounts` skips the hardening and says so loudly.

### What this build does not change

The rest of the vendor firmware is untouched, and the following were read from
the stock image and the SDK rather than tested. An rpcd ACL grants the
unauthenticated ubus session write access to `uci:*` and to a `web.advance cmd`
method that runs `system()` as root, reachable from the LAN. A nightly OTA cron
is enabled by default, fetches from the vendor's servers, and verifies only an
MD5 supplied in the same response. A service listens on UDP 1111 on all
interfaces and builds a `popen()` command from fields in the JSON it receives.
The uhttpd private key ships in the image, with a certificate that expired in
2022. Telnetd is started unless a factory flag says otherwise. A cloud client is
compiled in but has no caller and no init script.

Some of these belong to the vendor's own web UI and may not be present once
LuCI2 is replaced, but that has not been verified. Treat a v1.0 device as
trusted-LAN equipment.

OpenWrt 18.06 is end of life and receives no security updates.

```sh
./build-vendor.sh --audit-only   # show the shipped accounts, build nothing
./build-vendor.sh                # full build, 2-4 hours, ~30 GB disk
```

This build runs inside an Ubuntu 18.04 container, because OpenWrt 18.06's host
tools do not compile against a modern GCC. It requires Docker or Podman and must
not be run as root.

Flashing v1.0 goes through the stock web UI: System, then Backup/Upgrade, then
Flash new firmware image. Not "OTA upgrade" and not "Upload factory". Uncheck
*Keep settings*.

## Credit and discussion

The SF19A2890 SoC and AN8855 switch bring-up that all of this sits on is the
work of [ulli-kroll](https://github.com/ulli-kroll).

Discussion:
<https://forum.openwrt.org/t/sf19a2890-commit-possible-new-devices/210739>

## Licensing

The OpenWrt components are GPL-2.0 and other free licences. Corresponding source
is the upstream trees linked above, plus the build scripts and patches in this
repository, which are the complete set of modifications.

The WiFi driver sources are not redistributed here. `build.sh` clones them from
Siflower's own repository at a pinned commit and applies the port as a patch.
The LMAC firmware blobs are likewise fetched at build time from a pinned public
Banana Pi SDK commit rather than committed. The `sf-thermal` service shipped in
the image is written from scratch rather than derived from the vendor's daemon.

Siflower's SDK and driver repositories carry no LICENSE file, no SPDX headers
and no explicit redistribution grant, while several modules declare
`MODULE_LICENSE("GPL")`. That unresolved licensing is why neither v1.0 nor the
WiFi driver can be submitted upstream to OpenWrt.
