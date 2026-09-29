#
# Copyright (C) 2026 gnrsbassoutlook
#
# This is free software, licensed under the MIT License.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-openlist-assist
PKG_VERSION:=1.2.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=gnrsbassoutlook

LUCI_TITLE:=OpenList 助手 - 硬盘挂载 / 卸载 / 脏标记清理 / 存储映射
LUCI_DESCRIPTION:=Give /usr/bin/diskctl a web UI for OpenList users: \
 mount and force-mount USB disks, unmount and force-unmount, clear the \
 NTFS dirty flag, check filesystem health, eject safely, format a new \
 disk as exFAT/FAT32/ext4, start/stop OpenList, and re-point an existing \
 OpenList storage at another disk (or create a new one) after swapping disks.
LUCI_DEPENDS:=+blkid
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# $(call BuildPackage,$(PKG_NAME))
