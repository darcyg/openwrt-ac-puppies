#
# Copyright (C) 2008-2010 OpenWrt.org
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=tbq
PKG_RELEASE:=3

include $(INCLUDE_DIR)/package.mk

define KernelPackage/tbq
  CATEGORY:=Puppies
  SUBMENU:=Nos kernel modules
  TITLE:=tbq qos driver
  FILES:=$(PKG_BUILD_DIR)/tbq.ko
  DEPENDS:=+nos
  AUTOLOAD:=$(call AutoProbe,tbq)
  KCONFIG:=
endef

define KernelPackage/tbq/description
  Kernel module to traffic control subsystem events.
endef

EXTRA_KCONFIG:= \
	CONFIG_TBQ=m

EXTRA_CFLAGS:= \
	$(patsubst CONFIG_%, -DCONFIG_%=1, $(patsubst %=m,%,$(filter %=m,$(EXTRA_KCONFIG)))) \
	$(patsubst CONFIG_%, -DCONFIG_%=1, $(patsubst %=y,%,$(filter %=y,$(EXTRA_KCONFIG)))) \
	-I $(TOOLCHAIN_DIR)/include/ \
	-Wall

MAKE_OPTS:= \
	ARCH="$(LINUX_KARCH)" \
	CROSS_COMPILE="$(TARGET_CROSS)" \
	SUBDIRS="$(PKG_BUILD_DIR)" \
	EXTRA_CFLAGS="$(EXTRA_CFLAGS)" \
	$(EXTRA_KCONFIG)

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(MAKE) -C "$(LINUX_DIR)" \
		$(MAKE_OPTS) \
		modules
endef

$(eval $(call KernelPackage,tbq))
