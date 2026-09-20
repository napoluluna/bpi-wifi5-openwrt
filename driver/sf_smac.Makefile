#
# Siflower SF19A2890 WiFi (sf_smac) - ported to Linux 6.18 / OpenWrt backports.
#
# Differences from the vendor package (github.com/Siflower/sf_wifi):
#  - no sfax8_factory_read module. sf_get_value_from_factory() is provided by
#    startcore (sf_factory_read.c): it reads the "factory" MTD partition at the
#    vendor's offsets. This board DOES carry a per-unit "V4" tx-power calibration
#    table there (0x800); without it the driver fell back to the generic table
#    and transmitted ~32 dB low on 2.4 GHz / ~11 dB low on 5 GHz.
#  - MY_LINUX_VERSION_CODE is defined here. The driver tests it everywhere but
#    never defines it; in the vendor SDK it came from the build system.
#  - optional features (ATE tools, LED, thermal, HNAT, LA, repeater) are left
#    off for now, so build errors are API churn rather than vendor extras.
#
include $(TOPDIR)/rules.mk

PKG_NAME:=sf_smac
PKG_RELEASE:=1

include $(INCLUDE_DIR)/kernel.mk
include $(INCLUDE_DIR)/package.mk

define KernelPackage/sf_smac
  SUBMENU:=Wireless Drivers
  TITLE:=Siflower SF19A2890 WiFi (siwifi FullMAC)
  DEPENDS:=+kmod-cfg80211 +@DRIVER_11N_SUPPORT +@DRIVER_11AC_SUPPORT
  FILES:= \
	$(PKG_BUILD_DIR)/startcore/startcore.ko \
	$(PKG_BUILD_DIR)/rf/sf16a18_rf.ko \
	$(PKG_BUILD_DIR)/fmac/sf16a18_fmac.ko
  AUTOLOAD:=$(call AutoLoad,50,startcore sf16a18_rf sf16a18_fmac)
endef

define KernelPackage/sf_smac/description
 cfg80211 FullMAC driver for the on-SoC RivieraWaves radio of the Siflower
 SF19A2890, with the RF front-end module and the DSP boot helper.
endef

# CONFIG_WIFI_LITE_MEMORY must match the LMAC blobs installed below. The
# memory-opt firmware is a lite-memory build, and the driver's IPC layout is
# compiled from the same switch:
#   IPC_RXBUF_CNT        192  (vs 704 with CFG_DEAGG)
#   NX_TXDESC_CNT4         4  (vs 32) - the beacon TX queue
# Without it the LMAC starts and then rejects the driver:
#   "Different number of host buffers ... (704 != 192)"
#   "different sizes of BCN TX queue (32 != 4)"
#   "Different sizes of IPC shared ... (30112 != 23776)"
# It is also the right setting for 64 MiB of RAM. If the full-size LMAC blobs
# are ever used instead, this has to come back off.
#
# TXDESC2_CNT / VIRT_DEV_MAX describe the IPC layout of the LMAC blobs that
# build.sh installs (BPI SDK commit a685325, see there): VI TX queue of 64 and
# 3 virtual interfaces per band. The driver refuses a mismatched LMAC with
# "Different sizes of VI TX queue" / "Different number of supported virtual
# interfaces". The sf_wifi repo's own memory-opt blobs need 32 / 8 - and have
# the post-association blackout (CLAUDE.md, 5 GHz blackout root cause).
EXTRA_KCONFIG := \
	CONFIG_SF16A18_WIFI_MAC_HOST_OFFLOAD=m \
	CONFIG_SF16A18_WIFI_RF=m \
	CONFIG_SF16A18_WIFI_FULL_MAC=m \
	CONFIG_SFA28_FULLMASK=y \
	CONFIG_WIFI_LITE_MEMORY=y \
	CONFIG_SIWIFI_ACS_INTERNAL=y \
	CONFIG_SIWIFI_TXDESC2_CNT=64 \
	CONFIG_SIWIFI_VIRT_DEV_MAX=3 \
	CONFIG_DUAL_ANTENNA_CALIBRATE=y

# HB_EXT_PA marks the board's 5 GHz external front-end module as present; the
# vendor BPI DTS says "only support ext pa for 5G" and its boot log loads the
# non-expa tx-power table on 2.4 GHz. The DT's force_expa on wlan_rf switches
# it on at probe. Without it 5 GHz ran ~35 dB down both ways.
# CONFIG_SFAX8_FACTORY_READ enables the factory-calibration reads; the provider
# is startcore's sf_factory_read.c. DUAL_ANTENNA_CALIBRATE matches the vendor
# build and the DT's dual-antenna-calibrate; it also changes the IPC layout of
# the phy config the LMAC expects (lmac_msg.h).
# The driver's version guards test MY_LINUX_VERSION_CODE, which the vendor SDK
# supplied externally. Point it at the running kernel so the newest branch of
# every guard is taken; the newest one present is 4.19.
NOSTDINC_FLAGS := \
	$(KERNEL_NOSTDINC_FLAGS) \
	-I$(PKG_BUILD_DIR) \
	-I$(STAGING_DIR)/usr/include/mac80211-backport/uapi \
	-I$(STAGING_DIR)/usr/include/mac80211-backport \
	-I$(STAGING_DIR)/usr/include/mac80211/uapi \
	-I$(STAGING_DIR)/usr/include/mac80211 \
	-include backport/autoconf.h \
	-include backport/backport.h \
	-DMY_LINUX_VERSION_CODE=LINUX_VERSION_CODE \
	-DCONFIG_COMPILE_TIME=$(SOURCE_DATE_EPOCH) \
	-DCONFIG_FIRMWARE_SIZE=768 \
	-DCONFIG_FIRMWARE_LOAD_BASE=0x1f00000 \
	-DCONFIG_SF16A18_WIFI_RF \
	-DCONFIG_SF16A18_LMAC_USE_M_SFDSP \
	-DCONFIG_SFA28_FULLMASK \
	-DCONFIG_SF16A18_WIFI_HB_EXT_PA_ENABLE \
	-DCONFIG_SFAX8_FACTORY_READ \
	-DSIWIFI_LMAC_ME_SECOND_INSERT_INFO

# Appended after kbuild's own warning flags, so it can turn them off.
# TODO: the driver has ~200 non-static functions with no prototype, which 6.x
# makes an error. Silenced to get the port compiling and measurable; the real
# fix is to make them static or declare them, and it may expose signature
# mismatches the compiler currently cannot see.
SF_KCFLAGS := -Wno-missing-prototypes -Wno-missing-declarations

# Rebuild whenever the KERNEL config changes, not just when this package does.
# OpenWrt never re-enters Build/Compile once .built exists, so an out-of-tree
# module keeps the struct layouts of whatever kernel config it was first built
# against. Dropping firewall4 from the image removed kmod-nf-conntrack and with
# it CONFIG_NETFILTER, which takes the _nfct field out of struct sk_buff and
# moves skb->data from offset 164 to 160; the stale module then read truesize
# (0x320) as the data pointer and oopsed on the first RX buffer it touched.
# include/generated/autoconf.h is regenerated on every kernel config change.
STAMP_CONFIGURED_DEPENDS := \
	$(LINUX_DIR)/include/generated/autoconf.h \
	$(STAGING_DIR)/usr/include/mac80211-backport/backport/autoconf.h

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
	$(CP) -r ./config $(PKG_BUILD_DIR)/
	$(CP) -r ./src/bb_src $(PKG_BUILD_DIR)/fmac/
	$(CP) ./siflower_include/* $(PKG_BUILD_DIR)/fmac/bb_src/umac/fullmac/
	$(CP) ./siflower_include/*.h $(PKG_BUILD_DIR)/
	$(CP) ./sf_factory_read.c $(PKG_BUILD_DIR)/startcore/
endef

define Build/Compile
	+$(KERNEL_MAKE) $(PKG_JOBS) \
		M="$(PKG_BUILD_DIR)" \
		SUBDIRS="$(PKG_BUILD_DIR)" \
		KCFLAGS="$(SF_KCFLAGS)" \
		NOSTDINC_FLAGS="$(NOSTDINC_FLAGS)" \
		$(EXTRA_KCONFIG) \
		modules
endef

define Build/Install
	:
endef

# Firmware the driver requests by name at probe time. Two choices that matter:
#  - the LMAC images come from config/a28fullmask/memory-opt/ (237 KB each), not
#    the top-level ones (348 KB each). The vendor package picks memory-opt when
#    CONFIG_MEMORY_OPTIMIZE is set, and on a 64 MiB board with 4 MiB reserved for
#    the DSP that is the right trade; it also saves ~220 KB of flash.
#  - rf_pmem.bin/rf_default_reg.bin come from 1.12.001, whose rf_pmem.bin is
#    77,880 bytes - the size the vendor boot log reports ("Now copy rf_pmem.bin
#    firmware with size 77880") and matching "rf sw version 1.12".
SF_FW_DIR := $(PKG_BUILD_DIR)/config
SF_ARCH := a28fullmask

define KernelPackage/sf_smac/install
	$(INSTALL_DIR) $(1)/lib/firmware
	$(INSTALL_DATA) \
		$(SF_FW_DIR)/siwifi_aetnensis.ini \
		$(SF_FW_DIR)/siwifi_settings.ini \
		$(SF_FW_DIR)/tx_adjust_gain_table.bin \
		$(SF_FW_DIR)/$(SF_ARCH)/agcram.bin \
		$(SF_FW_DIR)/$(SF_ARCH)/agcram_24g.bin \
		$(SF_FW_DIR)/$(SF_ARCH)/ldpcram.bin \
		$(SF_FW_DIR)/$(SF_ARCH)/dig_gaintable.ini \
		$(SF_FW_DIR)/$(SF_ARCH)/dig_gaintable_expa.ini \
		$(SF_FW_DIR)/$(SF_ARCH)/default_hb_txpower_table.ini \
		$(SF_FW_DIR)/$(SF_ARCH)/default_lb_txpower_table.ini \
		$(SF_FW_DIR)/$(SF_ARCH)/default_hb_txpower_table_expa.ini \
		$(SF_FW_DIR)/$(SF_ARCH)/default_hb_txpower_table_expa_low_power.ini \
		$(SF_FW_DIR)/$(SF_ARCH)/default_lb_txpower_table_expa.ini \
		$(SF_FW_DIR)/$(SF_ARCH)/rf_trx_path.ini \
		$(SF_FW_DIR)/$(SF_ARCH)/sf_rf_expa_config.ini \
		$(SF_FW_DIR)/cali_table/default_txpower_calibrate_table.bin \
		$(SF_FW_DIR)/cali_table/default_txpower_calibrate_expa_table.bin \
		$(SF_FW_DIR)/cali_table/txp_offset_sleepmode_low.ini \
		$(SF_FW_DIR)/cali_table/txp_offset_sleepmode_low_second.ini \
		$(1)/lib/firmware/
	$(INSTALL_DATA) $(SF_FW_DIR)/$(SF_ARCH)/memory-opt/sf1688_lb_fmac.bin $(1)/lib/firmware/
	$(INSTALL_DATA) $(SF_FW_DIR)/$(SF_ARCH)/memory-opt/sf1688_hb_fmac.bin $(1)/lib/firmware/
	$(INSTALL_DATA) $(SF_FW_DIR)/$(SF_ARCH)/1.12.001/rf_pmem.bin $(1)/lib/firmware/
	$(INSTALL_DATA) $(SF_FW_DIR)/$(SF_ARCH)/1.12.001/rf_default_reg.bin $(1)/lib/firmware/
	# RF temperature watchdog (CLAUDE.md section 12, thermal). Plain shell.
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/etc/init.d $(1)/etc/config
	$(INSTALL_BIN) ./files/sf-thermal $(1)/usr/sbin/sf-thermal
	$(INSTALL_BIN) ./files/sf-thermal.init $(1)/etc/init.d/sf-thermal
	$(INSTALL_CONF) ./files/sf_thermal.config $(1)/etc/config/sf_thermal
endef

$(eval $(call KernelPackage,sf_smac))
