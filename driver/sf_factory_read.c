// SPDX-License-Identifier: GPL-2.0
/*
 * sf_factory_read.c - sf_get_value_from_factory() for the 6.18 port.
 *
 * The vendor's sfax8-factory-read module read the "factory" MTD partition at
 * offsets given by its device-tree node (sf19a28_fullmask.dtsi). The port
 * had left the whole thing out on the premise that this board carries no RF
 * calibration; it does: a "V4" tx-power calibration table at 0x800, which is
 * why the vendor firmware transmits 32 dB louder on 2.4 GHz. Same offsets,
 * same partition, read on demand, no DT node needed.
 *
 *   mtd-mac-address    = <&factory 0>      6 bytes
 *   mtd-cooling-temp   = <&factory 174>    2 bytes
 *   mtd-gmac-delay     = <&factory 178>    4 bytes
 *   mtd-wifi-version   = <&factory 2048>   2 bytes  ("V4" on this unit)
 *   mtd-wifi-info      = <&factory 2050>   up to WIFI_INFO_SIZE_V4
 *
 * The vendor derived the per-band WiFi MACs from the base MAC in this module;
 * the fmac already does that itself from the nvmem cell, so those actions
 * return -2 ("not present") and the fmac keeps its working path.
 */
#include <linux/module.h>
#include <linux/mtd/mtd.h>
#include <linux/string.h>
#include <sfax8_factory_read.h>

#define FACTORY_PART		"factory"
#define OFF_MAC			0
#define OFF_COOLING_TEMP	174
#define OFF_GMAC_DELAY		178
#define OFF_WIFI_VERSION	2048
#define OFF_WIFI_INFO		2050

static int factory_read(loff_t off, size_t len, void *buf)
{
	struct mtd_info *mtd;
	size_t retlen = 0;
	int ret;

	mtd = get_mtd_device_nm(FACTORY_PART);
	if (IS_ERR(mtd))
		return PTR_ERR(mtd);
	ret = mtd_read(mtd, off, len, &retlen, buf);
	put_mtd_device(mtd);
	if (ret)
		return ret;
	return retlen == len ? 0 : -EIO;
}

/* "V2"/"V3"/"V4"/"XO" mean a calibration block is present; 0xff means erased */
static bool wifi_version_valid(void)
{
	char v[WIFI_VERSION_SIZE];

	if (factory_read(OFF_WIFI_VERSION, sizeof(v), v))
		return false;
	return (v[0] == 'V' && v[1] >= '2' && v[1] <= '4') ||
	       (v[0] == 'X' && v[1] == 'O');
}

int sf_get_value_from_factory(enum sfax8_factory_read_action action,
			      void *buffer, int len)
{
	if (!buffer || len <= 0)
		return -1;

	switch (action) {
	case READ_MAC_ADDRESS:
		if (len > MACADDR_SIZE)
			len = MACADDR_SIZE;
		return factory_read(OFF_MAC, len, buffer);
	case READ_COOLING_TEMP:
		if (len > COOLING_TEMP_SIZE)
			len = COOLING_TEMP_SIZE;
		return factory_read(OFF_COOLING_TEMP, len, buffer);
	case READ_GMAC_DELAY:
		if (len > GMAC_DELAY_SIZE)
			len = GMAC_DELAY_SIZE;
		return factory_read(OFF_GMAC_DELAY, len, buffer);
	case READ_WIFI_VERSION:
		if (len > WIFI_VERSION_SIZE)
			len = WIFI_VERSION_SIZE;
		return factory_read(OFF_WIFI_VERSION, len, buffer);
	case READ_WIFI_INFO:
		if (!wifi_version_valid())
			return -2;
		if (len > WIFI_INFO_SIZE_V4)
			len = WIFI_INFO_SIZE_V4;
		return factory_read(OFF_WIFI_INFO, len, buffer);
	case READ_RF_XO_CONFIG:
		/* the vendor served this from the start of the wifi-info block */
		if (!wifi_version_valid())
			return -2;
		if (len > XO_CONFIG_SIZE)
			len = XO_CONFIG_SIZE;
		return factory_read(OFF_WIFI_INFO, len, buffer);
	default:
		return -2;
	}
}
EXPORT_SYMBOL(sf_get_value_from_factory);
