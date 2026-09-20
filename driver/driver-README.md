# WiFi driver port: Siflower sf_smac on Linux 6.18

This directory reproduces the ported WiFi driver package inside a fresh OpenWrt
tree. The driver sources themselves are not committed, since the upstream
repository carries no redistribution grant; only the diff against the upstream
release is here.

| file | what it is |
|---|---|
| `0001-sf_wifi-port-to-linux-6.18.patch` | the port, as a diff against `github.com/Siflower/sf_wifi` `sf_smac/src` at the commit named below. 30 files, 686 lines added, 248 removed |
| `sf_smac.Makefile` | the OpenWrt package Makefile, installed as `package/kernel/sf_smac/Makefile` |
| `sf_factory_read.c` | reads the board's `factory` MTD partition, compiled into `startcore` |
| `siflower_include/*.h` | three headers the driver includes but the upstream repository does not ship |
| `files/` | the `sf-thermal` service: script, init file, config |

## What the driver is

A cfg80211 FullMAC driver of roughly 60,000 lines, descended from
RivieraWaves/Ceva IP. The host driver splits into three modules loaded in order:
`startcore` (platform glue and factory data), `sf16a18_rf` (the RF front end)
and `sf16a18_fmac` (the MAC and the cfg80211 interface). Most of the MAC runs on
the radio's own processor, loaded at probe from two LMAC firmware blobs, one per
band, which the host talks to over IPC rings in shared memory.

The released sources target the cfg80211 API of Linux 4.19.7. That is not a
guess: the vendor firmware loads `backports.git v4.19.7-1`. The release also
pins `MY_LINUX_VERSION_CODE` to 4.14.90, so every `>= 4.19` branch in the tree
had never been compiled. Pointing that macro at the real kernel version is part
of the port and turns on a substantial body of previously unbuilt code.

## Sources and pinning

| what | where |
|---|---|
| driver | `github.com/Siflower/sf_wifi`, commit `da991faf` ("Initial release for open-source wifi driver") |
| LMAC firmware blobs | `github.com/BPI-SINOVOIP/BPI-WiFi5-Siflower`, commit `a685325`, `openwrt-18.06/package/kernel/sf_smac/config/a28fullmask/memory-opt/` |
| headers | `Siflower/1806_SDK`, vendor kernel tree |

`build.sh` fetches the blobs by URL and verifies them by MD5
(`fdb7c5dfb665e0cb4cf30d4987fabb44` for the 5 GHz image,
`5842b583b20d7a8711d54209d2fbcc0d` for 2.4 GHz), and aborts on a mismatch. The
blob pair matters: the pair shipped in the `sf_wifi` repository leaves every
fresh 5 GHz station without unicast traffic for 2 to 25 seconds after
association. The pinned older pair does not.

## Rebuilding it by hand

```sh
cd openwrt
mkdir -p package/kernel/sf_smac
git clone --depth 1 https://github.com/Siflower/sf_wifi.git /tmp/sf_wifi
cp -a /tmp/sf_wifi/sf_smac/src    package/kernel/sf_smac/src
cp -a /tmp/sf_wifi/sf_smac/config package/kernel/sf_smac/config
cp -a ../driver/siflower_include  package/kernel/sf_smac/
cp ../driver/sf_smac.Makefile     package/kernel/sf_smac/Makefile
patch -p1 -d package/kernel/sf_smac/src < ../driver/0001-sf_wifi-port-to-linux-6.18.patch
echo 'CONFIG_PACKAGE_kmod-sf_smac=y' >> .config && make defconfig
make package/kernel/sf_smac/compile -j4
```

The patch uses `a/` and `b/` prefixes relative to `sf_smac/src`, so it applies
with `-p1` inside that directory. If you regenerate it, apply it to a fresh
clone and diff the result against your working tree before committing.

The device tree half of this lives in `../patches/0005-*.patch`. The driver will
not probe without it.

## What was changed

### Kernel API

The bulk of the patch is the 4.19 to 6.18 move: cfg80211 and mac80211 callback
signatures, the `wireless_dev` and `cfg80211_ops` reshuffles, `netif_napi_add`
and NAPI polling, timer and work APIs, DMA and `dma_alloc_coherent` flags,
`proc`/`debugfs` creation, `strscpy` and `kstrtox` conversions, the
`platform_driver` and `of` accessors, and the `channel_def` and rate-info
structure changes.

### Defects in the driver, fixed against hardware

1. **Message numbering disagreed with the firmware.** The LMAC's dispatch table
   carries two "insert info" entries where the driver's header declares one, so
   every message from `ME_TX_CREDITS_UPDATE_IND` upward was off by one. The
   consequences were that the firmware's transmit-credit updates arrived with an
   id the driver had no handler for, leaving aggregates capped at five frames;
   that the driver's traffic indication went out one low, so a sleeping
   station's TIM bit was never set in the beacon and buffered traffic was never
   announced; and that the rate-control statistics request went out as a
   confirmation id, which stalled the command queue for six seconds and left
   that radio unable to accept further commands. Fixed by
   `-DSIWIFI_LMAC_ME_SECOND_INSERT_INFO`, which adds the missing enum entry.
   This is tied to the firmware blobs: if the blobs change, re-derive the
   numbering from the new blob's dispatch table.
2. **Receive went deaf under memory pressure.** The refill path refuses to
   replace a receive buffer while free memory is below 5 MB. The vendor kernel
   never executes that branch, because it has a private skb pool compiled in
   that mainline does not have. On this port the branch ran, and the buffer ring
   emptied out until the radio stopped receiving. The test is removed: the ring
   is a fixed 192 buffers replaced one for one, so there was nothing to bound,
   and the allocator's own watermarks decide.
3. **Module unload deadlocked with an interface up.** Module exit took RTNL and
   the wiphy lock, then unregistered each virtual interface without closing it
   first, and cfg80211's netdev notifier takes the wiphy lock again on the
   implied close. Every interface is now closed under RTNL before the wiphy lock
   is taken.
4. **The RF driver could not be loaded twice.** It requested its interrupt with
   `IRQF_TRIGGER_LOW` against a device tree declaring the line active high. The
   flag wins on the first load and the mapping keeps that type after the
   interrupt is freed, so the next probe is refused. The driver now passes no
   trigger flag and the polarity comes only from the device tree.
5. **A failed probe reprobed itself without limit.** Each round loaded the
   firmware image, allocated the IPC rings and spawned a usermode helper, so a
   single failure exhausted memory within seconds. A failed probe now fails, and
   the runtime recovery reprobe is capped.
6. **The RF block could not be reset through the mainline reset and clock
   model.** Both orderings of the generic model hang the bus during the default
   register write that follows the firmware copy. The vendor's own sequence is
   used instead, through `sf_reset_compat.c`.
7. **The transmit-power gain table parser overran its destination.** A four-byte
   copy per element into a byte array runs past the end of the 2.4 GHz table
   into the 5 GHz one on the last entry. Caught by fortify, which the vendor
   kernel does not enable.
8. **`siwifi_send_me_config_req` dereferenced a NULL band.** It reads the 5 GHz
   band's `iftype_data` unconditionally, including on the 2.4 GHz phy where that
   pointer is NULL. In a branch that had never been compiled.
9. **`siwifi_ipc_init` did not check its allocation** before dereferencing it.
10. Smaller fixes made in passing: a NULL dereference where `ht_capa->mcs` was
    read before the `if (ht_capa)` test; four `if (mac == NULL)` tests on a
    local array, which are always false and were meant to check that `sscanf`
    succeeded; a 4,000-byte stack buffer in a debugfs read on a platform with
    small kernel stacks; and `cfg80211_chandef_create()` handed an
    `nl80211_chan_width` where it wants an `nl80211_channel_type`, which worked
    only because both constants happen to be 1.

### Board integration

- **Factory calibration.** The vendor's `sfax8_factory_read` module is replaced
  by `sf_factory_read.c`, which reads the `factory` MTD partition directly at
  the vendor's offsets and provides `sf_get_value_from_factory()`. This board
  carries a per-unit `"V4"` transmit-power calibration table at 0x800 in that
  partition. Without it the driver falls back to a generic table and transmits
  about 32 dB low on 2.4 GHz and 11 dB low on 5 GHz. All reads are read-only and
  length-clamped.
- **Dual-antenna calibration** is enabled to match the table's format, in both
  the build (`CONFIG_DUAL_ANTENNA_CALIBRATE`) and the device tree.
- **Antenna count.** The firmware boots believing it has one antenna, and the
  only code that tells it otherwise sits in a temperature-control path that this
  build does not compile. The count is now sent after `MM_START` on both bands.
  Without it the best rate is two-stream, two-stream transmissions never
  succeed, and every fresh 5 GHz association spends seconds without unicast.
- **External PA on 5 GHz only.** The board has an external PA on the 5 GHz front
  end and none on 2.4 GHz, so `force_expa` is set in the device tree and only
  the 5 GHz external-PA build flag is set.

### `sf-thermal`

The only temperature sensor on this SoC is inside the RF block, and nothing in a
mainline build acts on it. `files/sf-thermal` is a procd shell service, written
from scratch, that polls the RF die temperature every 30 seconds and throttles
transmit duty cycle through the driver's own `tx_ctrl` knob, which withholds
transmit descriptors from the hardware queues. It uses the vendor daemon's
thresholds: throttle from 100 °C, release at 95 °C, and at 110 °C drop to a
single antenna. Settings live in `/etc/config/sf_thermal`, and it re-applies
itself after a WiFi restart.

The throttle steps are 48, 56, 60, 62 and 63 descriptors withheld of 64.
Measured effect, as a share of unthrottled speed:

| value | 32 | 48 | 56 | 60 | 62 | 63 | 64 |
|---|---|---|---|---|---|---|---|
| 2.4 GHz | 97 % | 83 % | 65 % | 50 % | 36 % | 20 % | 20 % |
| 5 GHz | 80 % | 59 % | 48 % | 33 % | 20 % | 10 % | 10 % |

These depend on aggregation depth, so re-measure them if the firmware blobs or
the credit handling change.

The vendor kernel's thermal zone is gain compensation rather than protection: it
turns die temperature into a transmit gain offset around the calibration
temperature. It is not built here. The vendor's userspace daemon does the
throttling, and on the vendor firmware it exits on its first temperature read
and is restarted in a loop by procd.

## Package configuration

Set in `sf_smac.Makefile`:

| setting | value | why |
|---|---|---|
| `CONFIG_WIFI_LITE_MEMORY` | y | 64 MiB board with 4 MiB reserved for the DSP |
| `CONFIG_SIWIFI_TXDESC2_CNT` | 64 | must match the LMAC blobs installed |
| `CONFIG_SIWIFI_VIRT_DEV_MAX` | 3 | likewise; this is the SSID limit per band |
| `CONFIG_DUAL_ANTENNA_CALIBRATE` | y | matches the factory table format |
| `CONFIG_SFAX8_FACTORY_READ` | on | enables the factory-calibration reads |
| `CONFIG_SF16A18_WIFI_HB_EXT_PA_ENABLE` | on | external PA is 5 GHz only |
| `SIWIFI_LMAC_ME_SECOND_INSERT_INFO` | on | message numbering, above |
| `MY_LINUX_VERSION_CODE` | `LINUX_VERSION_CODE` | compile against the real kernel |

One OpenWrt build-system note applies to any out-of-tree kernel module.
`Build/Compile` is never re-entered once a package's `.built` stamp exists, so a
module silently keeps the struct layouts of whatever kernel configuration it was
first built against. Dropping firewall4 from an image, for instance, removes
`CONFIG_NETFILTER`, which removes `_nfct` from `struct sk_buff` and moves
`skb->data` by four bytes; a stale module then reads the wrong field as the data
pointer and oopses on the first received buffer. The package declares
`STAMP_CONFIGURED_DEPENDS` on the kernel's generated `autoconf.h`, which is the
same hook mt76 uses.

## Test results

All from flashed squashfs images, not from a RAM boot, with a 12 V supply unless
noted.

### Association

| | result |
|---|---|
| 5 GHz | 8/8 runs associated, first reply 0.0 s, 100/100 pings |
| 2.4 GHz | 4/4 runs associated, first reply 0.0 s, 100/100 pings |
| WPA2, repeated connect and disconnect churn | clean |
| `wifi reload` | clean |

### Throughput

USB client about 10 cm from the board, iperf3 run from the board's RAM. The
close range is too short for 5 GHz and understates normal performance.

| | 2.4 GHz ch 6 HT20 | 5 GHz ch 36 VHT80 |
|---|---|---|
| TCP down | 98-102 Mbit/s, 101 over 10 minutes | 170-207 Mbit/s, 193 over 5 minutes |
| TCP up | 51 Mbit/s | 87 Mbit/s |
| RF die temperature under load | 60 to 64 °C | 53 to 65 °C over 5 minutes |
| load average, CPU idle | 0.28, 89 % | 0.93, 65 % |
| MemAvailable, minimum | 14.2 MB | 14.1 MB |
| warnings, resets | 0 | 0 |

Earlier runs with a 2x2 RT5372 client on a shared channel measured 29 to 40
Mbit/s on 2.4 GHz, which is the client and the air rather than the board.

Aggregates reach 17 frames on 2.4 GHz. On 5 GHz they stay at four or fewer
because each frame already carries an aggregated payload.

The one direct comparison against the vendor firmware, same client and position,
ten minutes of HTTP download, was taken before the message-numbering fix: 34.4
Mbit/s for this driver against 43.0 for the vendor, with 5.0 % transmit retries
against the vendor's 13.4 %, and the same thermal behaviour. It has not been
repeated since.

### Power-save clients

Client with power save enabled, 60 pings per run originated by the access point,
beacons captured on a monitor interface and the TIM element parsed.

| | delivered | round trip, min/avg/max | TCP down while dozing |
|---|---|---|---|
| 2.4 GHz | 59/60 | 5 / 58 / 112 ms | 17-38 Mbit/s |
| 5 GHz | 60/60 | 8 / 106 / 209 ms | 159 Mbit/s |

For reference, the vendor firmware on the same client and test delivered 60/60
at 13 / 124 / 304 ms.

### Stability

| | result |
|---|---|
| `wifi down` then `wifi up`, 10 cycles | 10/10 clean, 0 warnings |
| module unload and reload with both APs up, 8 cycles | 8/8, all return 0, both APs back, 0 warnings |
| 5 minutes sustained TCP on 5 GHz at full power | 0 resets, peak RF die 59 °C |
| 10 minutes sustained TCP on 2.4 GHz | no process kills, memory flat |
| receive with free memory held under 5 MB for 70 s | 0 buffer deficit, 0 refill failures, receive counters climbing throughout |
| `sf-thermal` with the threshold set below idle temperature | 5 levels applied and released on both radios, APs stay up |

### Reproducibility

Building from the code directory alone produces a 7,340,309-byte image whose
`sf16a18_fmac.ko` has the same MD5 as the module running on the board. Package
feeds are not pinned, so the surrounding image is functionally equivalent rather
than byte-identical.

## Limitations

- **The status LED is blue.** The vendor firmware drives it red. The driver's
  LED support (`CONFIG_SF19A28_WIFI_LED`, `siwifi_led.c`) is not built here.
- **Three SSIDs per band**, fixed by the firmware blob layout the package is
  built against.
- **No hardware NAT offload.** The vendor's `sfhnat` needs the vendor kernel.
- **Airtime fairness and the vendor's token-based transmit scheduler are off.**
  The vendor build enables `CONFIG_SFFMAC_ENABLE_TOKEN`; this one does not.
- **The RF gain tables are the chip defaults.** The vendor build reprograms them
  at probe and pairs that with a lower-power 5 GHz table.
- **Kernel-side thermal compensation is not built.** It would need
  `CONFIG_THERMAL_OF`, the vendor glue rewritten for the 6.18 thermal API, and
  the thermal-zone device tree.
- `-Wno-missing-prototypes` and `-Wno-missing-declarations` are passed
  package-wide to get past roughly 200 non-static functions with no prototype.
  This could hide a real signature mismatch. Declaring them, or making them
  static, is the proper fix.

## Working with the driver's debugfs

- The radios are not always `phy0` and `phy1`. After a module reload they come
  back with new indices. Identify a radio by reading `siwifi/band_type`, which
  is `lb` for 2.4 GHz and `hb` for 5 GHz.
- Do not read every file in the driver's debugfs directory at once. Several of
  them trigger firmware dumps when read.
- `stats`, `txq`, `hwq` and `trx_stats` are safe to read at any time.
  `rc/<sta>/stats` needs `enable_rc=1` set and the station re-associated first.
