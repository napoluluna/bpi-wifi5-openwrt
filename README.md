# OpenWrt 18.06 with standard LuCI for Banana Pi BPI-WiFi5

A prebuilt firmware image for the **Banana Pi BPI-WiFi5** (Siflower SF19A2890)
that replaces the vendor's LuCI2 skin with **standard LuCI**, and removes two
hardcoded credentials the vendor ships in the stock firmware.

WiFi (2.4 GHz + 5 GHz) and all four ethernet ports work, because this uses the
vendor's own kernel and drivers. Nothing was ported.

**This is not official OpenWrt.** It is a build of Banana Pi's public vendor SDK
with the standard-LuCI target selected and a small security patch applied.

---

## Read this before flashing

- **This image ships with NO root password.** That is intentional — the vendor
  ships a preset one (see below). Set your own immediately on first boot,
  before connecting the router to anything untrusted.
- **BPI-WiFi5 only.** Flashing this on another Siflower board will brick it.
- **Assumes 8 MiB SPI-NOR.** My unit has a ZB25VQ64A (8 MiB) even though the
  vendor device tree asks for a W25Q128 (16 MiB). Check yours first:
  `dmesg | grep m25p80`. The partition layout is the vendor's and unchanged.
- **OpenWrt 18.06 is end of life** (since 2020). No security updates. Do not
  put this on your internet edge. Behind another firewall, or as a pure access
  point, it is reasonable.
- **Back up your flash first.** Instructions below. Not optional.

---

## What this changes vs stock

| | Stock | This build |
|---|---|---|
| Web UI | Vendor LuCI2 skin | Standard LuCI |
| `root` password | preset MD5 hash, same on every unit | **blank** — you set it |
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
prompts you to set one.

This build blanks root and deletes `sfroot`. Verify after flashing:

```sh
cat /etc/shadow      # root:: and no sfroot line
```

### Other things worth knowing about the stock firmware

- **OTA auto-update is enabled by default**, pointing at the vendor's servers.
  This build does not include the OTA client.
- The default config defines `guest` (10.0.0.1) and `lease` (10.2.0.1)
  networks, and a Chinese-language "租赁" (rental) SSID — leftovers from the
  vendor's rental-property deployment model. Harmless, and removable with
  `uci delete`.
- An audit of every script and readable C source in the vendor tree found **no**
  phone-home URLs, no telemetry, no suspicious cron jobs or init scripts. The
  closed WiFi firmware blobs and one compiled thermal daemon were **not**
  audited — static review cannot clear binaries. This is equally true of the
  stock firmware.

---

## Back up your flash first

From the stock firmware, over SSH. Old dropbear needs the legacy crypto flags:

```sh
for i in 0 1 2 3 4; do
  ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
      -o KexAlgorithms=+diffie-hellman-group14-sha1 \
      root@192.168.4.1 "cat /dev/mtd${i}ro" > mtd${i}.bin
done
ls -l mtd*.bin
```

Stock defaults: `192.168.4.1`, user `root`, password `admin`.

Expected sizes:

| file | partition | bytes |
|---|---|---|
| mtd0.bin | spl-loader | 131072 |
| mtd1.bin | u-boot | 393216 |
| mtd2.bin | u-boot-env | 65536 |
| mtd3.bin | factory | 65536 |
| mtd4.bin | firmware | 7733248 |

`mtd3.bin` holds your MAC address. `mtd4.bin` is your complete stock firmware —
that is what you restore if this build does not work out. Copy them off the
machine you are working on.

---

## Flashing

Through the stock web UI. No serial console needed.

1. Wire your PC to a **LAN** port (not WAN). Do not do this over WiFi.
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

### If it does not come back

Failsafe: power cycle, and when the LED flashes, press reset repeatedly. That
boots a minimal system at **192.168.1.1** (different address), no password.
Then `firstboot && reboot`.

If that fails too you need a serial console (3.3 V USB-TTL, 115200 8N1, header
inside the case). Interrupt U-Boot, run `httpd 192.168.4.1`, and upload
`mtd4.bin` through the browser.

---

## Verifying the image

```sh
sha256sum openwrt-siflower-sf19a28-fullmask-squashfs-sysupgrade.bin
```

Compare against `SHA256SUMS` in this release.

Size: 6,553,604 bytes, against a 7,733,248-byte firmware partition.

---

## Building it yourself

`build-vendor.sh` reproduces this image. It clones the vendor SDK, applies the
account hardening, and builds inside an Ubuntu 18.04 container (OpenWrt 18.06's
host tools do not compile against a modern GCC).

```sh
./build-vendor.sh --audit-only   # show the shipped accounts, build nothing
./build-vendor.sh                # full build, 2-4 hours, ~30 GB disk
```

Requires Docker or Podman. Do not run as root — OpenWrt refuses to build as
root, and the script mirrors your UID into the container.

Source: <https://github.com/BPI-SINOVOIP/BPI-WiFi5-Siflower>, branch `main`.

---

## Licensing

The OpenWrt components are GPL-2.0 and other free licenses; corresponding source
is the vendor tree linked above, plus `build-vendor.sh` in this repository,
which is the complete set of modifications.

The WiFi firmware blobs (`sf1688_hb_fmac.bin`, `sf1688_lb_fmac.bin`,
`rf_pmem.bin`) and the Siflower kernel modules come from that SDK. **It carries
no LICENSE file, no SPDX headers, and no explicit redistribution grant**, while
several modules declare `MODULE_LICENSE("GPL")`. This unresolved licensing is
why this cannot be upstreamed to OpenWrt. Redistributed here on the basis that
Banana Pi publishes the SDK openly; will be removed on request from a rights
holder.

Not affiliated with or endorsed by OpenWrt, Banana Pi/SINOVOIP, or Siflower.

---

## Status of mainline OpenWrt on this board

There is no mainline support. The `siflower` target in OpenWrt covers the
RISC-V sf21 subtarget and the SF19A2890 evaluation board, but no BPI-WiFi5
profile and no images.

Ethernet-only work exists in
[ulli-kroll/openwrt](https://github.com/ulli-kroll/openwrt), branch
`openwrt-siflower/v6.18/sf19/master` — GMAC and the AN8855 switch work over
DSA, tested via TFTP initramfs. **No WiFi driver exists at all.** The vendor
driver is a ~60k-line RivieraWaves FullMAC descendant targeting the cfg80211 API
of Linux 4.19.7 (confirmed: the running stock firmware loads
`backports.git v4.19.7-1`), with the LMAC shipped only as a binary blob.
Porting it to a current kernel is unsolved work.

Discussion:
<https://forum.openwrt.org/t/sf19a2890-commit-possible-new-devices/210739>
