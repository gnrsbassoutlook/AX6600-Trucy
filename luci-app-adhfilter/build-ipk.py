#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build-ipk.py —— 离线把 luci-app-adhfilter 打成 .ipk，**不需要 OpenWrt SDK**。

用法：
    python3 build-ipk.py                # 生成 dist/luci-app-adhfilter_<ver>_all.ipk
    python3 build-ipk.py --outdir /tmp  # 换输出目录
    python3 build-ipk.py --legacy-ar    # 额外生成一个老式 ar 格式的副本（给很旧的 opkg）

────────────────────────────────────────────────────────────────────────
★ .ipk 到底是什么？—— 实测结论（2026-09-28 拉真实包 + 在路由器上跑
  `opkg install --noaction` 验证出来的，不是猜的）：

  现代 OpenWrt（24.10 及以后）的 .ipk 是 **gzip 外壳的 tar**：

      gzip( tar(
          ./debian-binary      内容固定为 "2.0\\n"
          ./data.tar.gz        真实文件树（路径形如 ./usr/lib/...）
          ./control.tar.gz     元数据（./control, ./conffiles, ./postinst, ...）
      ) )

  注意层次：**外面一层 gzip**，里面是未压缩 tar，再里面 data/control 各自
  又是 gzip。三层，别搞混。

  ⚠️ 两个踩过的坑：
   1. 不是 ar 归档了（老的 deb 风格 ar 归档只有旧 opkg 才要，留了 --legacy-ar）。
   2. **外面那层 gzip 不能省**。裸 tar 会被 opkg 判
      `pkg_init_from_file: Malformed package file`，而不是给个更友好的提示。

  复现方式：
      curl -s -D - -o p.ipk https://downloads.openwrt.org/releases/24.10.0/\\
          packages/x86_64/base/6in4_29_all.ipk
      # 响应头里 content-type: application/octet-stream 且**没有** Content-Encoding，
      # 但存下来的字节是 gzip  -> 说明 gzip 是文件自身格式，不是传输编码
      file p.ipk                       # -> gzip compressed data, original size 10240
      gunzip -c p.ipk > p.tar && file p.tar    # -> POSIX tar archive
      tar tvf p.tar                    # -> ./debian-binary ./data.tar.gz ./control.tar.gz
      # 路由器上验证：
      opkg install --noaction p.ipk    # 通过 = 格式对
"""

import argparse
import gzip
import io
import os
import sys
import tarfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.join(HERE, "root")

PKG_NAME = "luci-app-adhfilter"
PKG_VERSION = "1.1.0"
PKG_RELEASE = "1"
PKG_ARCH = "all"
PKG_LICENSE = "MIT"
PKG_MAINTAINER = "gnrsbassoutlook"
PKG_DESCRIPTION = (
    "ADH Filter - LuCI UI for /usr/bin/adhfilter. "
    "Pick which devices go through AdGuard Home's NSFW filtering."
)
# 依赖：libc 是 ipkg-build 对 arch=all 包的惯例；luci-base 提供框架；
# luci-compat + luci-lua-runtime 提供老式 Lua controller / CBI / luci.model.uci。
# 这三个名字都已对照 OpenWrt 24.10 官方 Packages 索引确认存在。
PKG_DEPENDS = ["libc", "luci-base", "luci-compat", "luci-lua-runtime"]

# 安装为配置文件（opkg 不会覆盖用户已改过的同名文件）
PKG_CONFFILES = ["/etc/config/adhfilter"]

VERSION_FULL = f"{PKG_VERSION}-{PKG_RELEASE}"


# ────────────────────────────── 小工具 ──────────────────────────────
def log(msg):
    print(msg, flush=True)


def read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def dir_mode():
    return 0o755


def file_mode(path):
    """可执行位跟着源文件走，其余 644。"""
    try:
        if os.access(path, os.X_OK):
            return 0o755
    except OSError:
        pass
    return 0o644


def make_tar_gz(entries, mtime):
    """
    entries: [(arcname, mode, data)]，data=None 表示目录
    返回 gzip 压缩后的 bytes
    """
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tf:
        for arc, mode, data in entries:
            ti = tarfile.TarInfo(arc)
            ti.mode = mode
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            ti.mtime = mtime
            if data is None:
                ti.type = tarfile.DIRTYPE
                ti.size = 0
                tf.addfile(ti)
            else:
                ti.type = tarfile.REGTYPE
                ti.size = len(data)
                tf.addfile(ti, io.BytesIO(data))
    return gzip.compress(raw.getvalue(), compresslevel=9, mtime=int(mtime))


def make_tar(entries, mtime):
    """未压缩 POSIX tar，返回 bytes。"""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tf:
        for arc, mode, data in entries:
            ti = tarfile.TarInfo(arc)
            ti.mode = mode
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            ti.mtime = mtime
            if data is None:
                ti.type = tarfile.DIRTYPE
                ti.size = 0
                tf.addfile(ti)
            else:
                ti.type = tarfile.REGTYPE
                ti.size = len(data)
                tf.addfile(ti, io.BytesIO(data))
    return raw.getvalue()


def ar_archive(members):
    """老式 deb/ar 归档（BSD/common 变体，名字不带斜杠）。"""
    out = bytearray(b"!<arch>\n")
    for name, data in members:
        n = name.encode()
        if len(n) > 15:
            raise ValueError(f"ar 成员名过长: {name}")
        hdr = n.ljust(16, b" ")
        hdr += b"0".ljust(12, b" ")           # mtime
        hdr += b"0".ljust(6, b" ")            # uid
        hdr += b"0".ljust(6, b" ")            # gid
        hdr += b"100644".ljust(8, b" ")       # mode
        hdr += str(len(data)).encode().ljust(10, b" ")
        hdr += b"\x60\n"                      # magic "`\n"
        assert len(hdr) == 60, len(hdr)
        out += hdr
        out += data
        if len(data) % 2:
            out += b"\n"
    return bytes(out)


# ────────────────────────────── 收集文件树 ──────────────────────────────

# 🔴 macOS 会在你翻过的每个目录里自动撒垃圾文件，**绝不能打进包**：
# 装到路由器上会凭空多出一个 /.DS_Store（毫无用处），而且会暴露打包机的系统。
# （实测踩过：ipk 里混进了 ./.DS_Store 6148 字节。Finder 一浏览目录就会重新生成，
#   所以只在打包时过滤、不靠手工删除。）
JUNK_NAMES = {".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd", ".AppleDouble"}


def is_junk(name):
    return name in JUNK_NAMES or name.startswith("._")


def collect_data_entries():
    if not os.path.isdir(ROOT_DIR):
        sys.exit(f"!! 找不到 {ROOT_DIR}（应该在插件目录里运行本脚本）")

    entries = [("./", dir_mode(), None)]
    seen_dirs = {"./"}
    total_bytes = 0

    for dirpath, dirnames, filenames in os.walk(ROOT_DIR):
        dirnames.sort()
        # 就地裁剪（别用 dirnames = ...），否则 os.walk 会照样递归进垃圾目录
        dirnames[:] = [d for d in dirnames if not is_junk(d)]

        rel = os.path.relpath(dirpath, ROOT_DIR)
        if rel != ".":
            arc = "./" + rel.replace(os.sep, "/") + "/"
            if arc not in seen_dirs:
                seen_dirs.add(arc)
                entries.append((arc, dir_mode(), None))

        for fn in sorted(filenames):
            if is_junk(fn):
                continue
            full = os.path.join(dirpath, fn)
            if rel == ".":
                arc = "./" + fn
            else:
                arc = "./" + rel.replace(os.sep, "/") + "/" + fn
            data = read_bytes(full)
            total_bytes += len(data)
            entries.append((arc, file_mode(full), data))

    return entries, total_bytes


# ────────────────────────────── control ──────────────────────────────
def build_control_text(installed_size_kb):
    # ⚠️ 不要加 `Section-Priority:`。实测（2026-09-28，副机 opkg
    # 38eccbb1 @ 2024-10-16）带这个字段会让 opkg 打印
    #     ERROR: truncating field 4 <0x...> to 5 byte
    # 虽然仍能装，但 DB 里那个字段是被截断的，属于无谓的脏数据。删掉即干净。
    lines = [
        f"Package: {PKG_NAME}",
        f"Version: {VERSION_FULL}",
        f"Depends: {', '.join(PKG_DEPENDS)}",
        f"Source: package/{PKG_NAME}",
        f"SourceName: {PKG_NAME}",
        f"License: {PKG_LICENSE}",
        "Section: luci",
        f"Architecture: {PKG_ARCH}",
        f"Installed-Size: {installed_size_kb}",
        f"Maintainer: {PKG_MAINTAINER}",
        f"Description: {PKG_DESCRIPTION}",
        "",
    ]
    return "\n".join(lines).encode()


POSTINST = """#!/bin/sh
# LuCI 的索引缓存不删，新菜单不会出现。
[ -n "${IPKG_INSTROOT}" ] || {
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
	/etc/init.d/uhttpd restart >/dev/null 2>&1
}
exit 0
""".encode()

PRERM = """#!/bin/sh
exit 0
""".encode()

POSTRM = """#!/bin/sh
# 只清界面缓存。过滤规则（firewall 里的 KidADH_* / KidADHM_* 锚点、
# dhcp 里的 KidHost_* 静态绑定）一律不动 —— 要撤过滤请用 adhfilter del <IP>。
[ -n "${IPKG_INSTROOT}" ] || {
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
	/etc/init.d/uhttpd restart >/dev/null 2>&1
}
exit 0
""".encode()


def build_control_tar_gz(control_text, mtime):
    entries = [
        ("./", dir_mode(), None),
        ("./control", 0o644, control_text),
        ("./conffiles", 0o644, "".join(c + "\n" for c in PKG_CONFFILES).encode()),
        ("./postinst", 0o755, POSTINST),
        ("./prerm", 0o755, PRERM),
        ("./postrm", 0o755, POSTRM),
    ]
    return make_tar_gz(entries, mtime)


# ────────────────────────────── main ──────────────────────────────
def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--outdir", default=os.path.join(HERE, "dist"))
    ap.add_argument("--legacy-ar", action="store_true",
                    help="额外生成一个老式 ar 格式副本（给很旧的 opkg）")
    args = ap.parse_args()

    mtime = int(time.time()) - 60
    os.makedirs(args.outdir, exist_ok=True)

    data_entries, total_bytes = collect_data_entries()
    installed_kb = max(1, (total_bytes + 1023) // 1024)
    control_text = build_control_text(installed_kb)

    data_tgz = make_tar_gz(data_entries, mtime)
    control_tgz = build_control_tar_gz(control_text, mtime)

    log(f"== 打包 {PKG_NAME} {VERSION_FULL} ({PKG_ARCH}) ==")
    log(f"   data.tar.gz     {len(data_tgz):>7} 字节   ({len(data_entries)} 个成员)")
    log(f"   control.tar.gz  {len(control_tgz):>7} 字节")
    log("")

    with tarfile.open(fileobj=io.BytesIO(data_tgz), mode="r:gz") as tf:
        for m in tf.getmembers():
            if m.isfile():
                log(f"     + {m.name}")

    log("")
    log("   control 内容:")
    for line in control_text.decode().rstrip().splitlines():
        log(f"     | {line}")
    log("")

    # ---- 主格式：gzip(tar) —— OpenWrt 24.10+ 的 ipk ----
    ipk_name = f"{PKG_NAME}_{VERSION_FULL}_{PKG_ARCH}.ipk"
    ipk_path = os.path.join(args.outdir, ipk_name)
    inner_tar = make_tar(
        [
            ("./debian-binary", 0o644, b"2.0\n"),
            ("./data.tar.gz", 0o644, data_tgz),
            ("./control.tar.gz", 0o644, control_tgz),
        ],
        mtime,
    )
    ipk_bytes = gzip.compress(inner_tar, compresslevel=9, mtime=0)
    with open(ipk_path, "wb") as f:
        f.write(ipk_bytes)
    log(f"== 产物: {ipk_path}  ({len(ipk_bytes)} 字节) ==")
    log(f"   格式: gzip( tar ) 外壳，内层 data/control 各自 gzip   [tar {len(inner_tar)} 字节]")
    log("   ⚠️ 外面那层 gzip 不能省，裸 tar 会被 opkg 判 Malformed package file")

    # ---- 兼容格式：老式 ar ----
    if args.legacy_ar:
        ar_name = f"{PKG_NAME}_{VERSION_FULL}_{PKG_ARCH}.ar.ipk"
        ar_path = os.path.join(args.outdir, ar_name)
        ar_bytes = ar_archive(
            [
                ("debian-binary", b"2.0\n"),
                ("control.tar.gz", control_tgz),
                ("data.tar.gz", data_tgz),
            ]
        )
        with open(ar_path, "wb") as f:
            f.write(ar_bytes)
        log(f"== 兼容产物: {ar_path}  ({len(ar_bytes)} 字节) ==")
        log("   格式: ar 归档  （老 opkg / deb 风格）")

    log("")
    log("安装: opkg install " + ipk_path)
    log("     依赖报错时: opkg install --force-depends " + ipk_path)
    log("")


if __name__ == "__main__":
    main()
