# OpenList + 4T 实体硬盘 —— 挂载操作说明

> 主机 `192.168.1.1`（AX6600 / bleachwrt）· OpenList **v4.2.6** · 2026-09-29 配置

---

## 一、当前状态（一句话）

**4T 硬盘已挂到 `/mnt/sda2`，OpenList 里已建好「本机存储」→ 挂载路径 `/THW-4T`，WebDAV 也通了。断电重启会自动挂回来。**

| 项目 | 值 |
|---|---|
| 硬盘 | 希捷 ST4000VX005（监控盘）3.64 TiB，GPT 分区 |
| 设备节点 | **`/dev/sda2`**（数据区，NTFS） |
| `sda1` | ⚠️ 只有 16MB 的「Microsoft 保留分区」，**不是数据区**，别挂它 |
| UUID | `8CB8C15FB8C14902` |
| 挂载点 | `/mnt/sda2` |
| 挂载参数 | `ntfs3 rw,relatime,uid=0,gid=0,iocharset=utf8` |
| 容量 | 3.6T，已用 2.5T，**剩 1.1T** |
| OpenList | `/root/openlist_run/openlist`，监听 `0.0.0.0:5244` |
| 后台 | `http://192.168.1.1:5244` · 账号 `admin` / 同路由器口令 |
| WebDAV | `http://192.168.1.1:5244/dav`（账号同上） |
| 挂载路径名 | `/THW-4T`（OpenList 里显示的目录名） |

---

## 二、新装的三个文件（都是新增，没删任何东西）

| 文件 | 作用 |
|---|---|
| `/root/mount-data-disk.sh` | **挂载主体**。幂等，可反复跑；自带等设备、脏标记 force 兜底、日志 |
| `/root/umount-data-disk.sh` | **安全弹出**。拔线/拿去电脑修之前跑它 |
| `/etc/hotplug.d/block/99-mount-data-disk` | **热插拔自动挂载**。硬盘拔了再插，不用重启路由器 |

`/etc/rc.local` 加了一行（**原文件已备份到 `/root/rc.local.bak.20260929-022909`**）：

```sh
# === 4T 数据盘挂载 -> /mnt/sda2（OpenList「本机存储」要用）===  added 2026-09-29
[ -x /root/mount-data-disk.sh ] && /root/mount-data-disk.sh
```

位置在 `sleep 20` 之后、启动 OpenList 之前 —— 保证 OpenList 起来时盘已经在了。

---

## 三、日常命令（复制就能用）

```sh
# 看盘挂上没有 / 剩多少
df -h /mnt/sda2

# 手动挂（一般不用，除非刚装好或出问题）
/root/mount-data-disk.sh

# 看挂载脚本自己的日志（挂没挂上、有没有用 force）
cat /tmp/data-disk.log

# 安全弹出（拔线前必做）
/root/umount-data-disk.sh

# 有文件被占用时（OpenList 正在传文件），先停服务再弹出
/root/umount-data-disk.sh --stop
# 再重新起来：
cd /root/openlist_run && ./openlist server > /tmp/openlist.log 2>&1 &

# 列出盘里的东西
ls -la /mnt/sda2
```

---

## 四、⚠️ 三个必须知道的坑

### 1. `mount` 命令在这台机器上是坏的 —— **一律用 `busybox mount`**

本机装了 `mount-utils`（util-linux）包，它的 `/usr/bin/mount` 与固件自带的
`libmount.so.1` ABI 不匹配，一执行就报：

```
Error relocating /usr/bin/mount: mnt_context_enable_onlyonce: symbol not found
```

而 `PATH` 里 `/usr/bin` 排在 `/bin` 前面（`/bin/mount` 其实是 busybox 的软链），
所以**裸敲 `mount` 命中的是那个坏的**。同一包的 `umount` / `findmnt` 同理。

> 你那份 Gemini 备忘里写的「必须用 busybox mount」是对的，原因就是上面这个。
>
> **想彻底修好**（可选，一条命令）：
> ```sh
> opkg remove mount-utils
> ```
> 删掉后 `mount` / `umount` 自动退回 busybox 版本，就正常了。
> 目前挂载脚本不依赖裸 `mount`，所以**删不删都不影响现有功能**。

### 2. `sda1` 不是数据区

`fdisk -l /dev/sda` 显示：

```
/dev/sda1     34       32767     16M    Microsoft reserved     ← 保留分区，别挂
/dev/sda2     32768   7814033407  3.6T   Microsoft basic data   ← 真正的数据区
```

`/mnt/sda1` 那个空目录是早先建的，可以留着也可以删（`rmdir /mnt/sda1`），**别往里挂东西**。

### 3. 非正常卸载 → NTFS 脏标记 → 要 `force` 才挂得上

直接拔线或断电，NTFS 会被写脏标记，ntfs3 出于保护会拒绝挂载（报 `Invalid argument`）。
这时候用你备忘里的那条即可：

```sh
busybox mount -t ntfs3 -o force,iocharset=utf8 /dev/sda2 /mnt/sda2
```

**本机现在会自动兜底**：`mount-data-disk.sh` 先试干净挂，失败了自动加 `force` 再试一次，
并把这件事写进 `/tmp/data-disk.log`。所以断电重启后**一般自己就好了**，
但看到日志里出现 `mounted FORCED` 就意味着该找机会在 Windows 上 `chkdsk /f` 修一次。

---

## 五、OpenList 里那块盘是怎么加的（等效于网页操作）

网页：**管理后台 → 存储 → 添加**，参数如下（也是我用 API 建好的那份，id=1）：

| 字段 | 值 |
|---|---|
| 驱动 | **本机存储（Local）** |
| 挂载路径 | `/THW-4T` |
| 根文件夹路径 | `/mnt/sda2` |
| WebDAV 策略 | **本地代理（native_proxy）** |
| 显示隐藏文件 | 关（`.Trashes` 之类不显示） |
| 目录权限 | `777` |
| 缓存过期 | 30 秒 |

> 如果网页上看不到刷新后的内容：**浏览器强刷 `Cmd+Shift+R`**，
> 或到「存储」页把该存储 `禁用 → 启用` 一次。

---

## 六、和旧备忘（Alist 版）的对应关系

| 旧备忘（Alist） | 现在（OpenList） |
|---|---|
| `/root/alist_run` | **`/root/openlist_run`**（旧的 alist 目录已不存在） |
| `killall -9 alist` | `killall openlist` |
| `./alist admin set <pwd>` | `./openlist admin set <pwd>` |
| `/mnt/sda1`（小U盘） | 本机没有小U盘，`sda1` 是保留分区 |
| `/mnt/sda2`（4T） | ✅ 就是它，没变 |
| 5244 端口 / `/dav` | ✅ 没变，Kodi、Documents、VidHub 配置**不用改** |
| rc.local 里手写 mount | 已抽成 `mount-data-disk.sh`，并加了脏标记兜底 + 热插拔 |

**Kodi / Mac 访达 / 手机播放器那边一个字都不用改**，因为 IP、端口、账号、`/dav` 路径全没变。

---

## 七、还没做 / 下一步

1. **夸克网盘 Cookie 更新**（用户下一步要调）—— 网页端：存储 → 夸克 → 编辑 → 换 Cookie → 保存。
2. 可选：给 OpenList 建一个正式服务脚本 `/etc/init.d/openlist`，
   这样就能 `service openlist restart`，不用再 `killall` + 手敲启动命令。
3. 可选：`opkg remove mount-utils` 彻底修好 `mount` / `umount`。
4. 可选：家人账号与权限分发（管理后台 → 用户 → 添加，基本路径填 `/THW-4T` 就只看到这块盘）。
5. 可选：重启一次路由器做「真实断电测试」（本次是用「卸载 + 跑 rc.local」模拟的，已通过）。
