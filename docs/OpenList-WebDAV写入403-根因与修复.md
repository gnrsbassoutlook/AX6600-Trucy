# OpenList「WebDAV 能读不能写（403）」——根因与修复

> 主机 `192.168.1.1` / 副机 `192.168.3.1`（AX6600 · bleachwrt · OpenList v4.2.6）· 2026-09-30
>
> 一句话：**不是客户端的锅，是 OpenList admin 账号的权限位缺 `bit9`（512 = WebDAV 写入）。
> 而上游默认值恰好就缺这一位 —— 任何一台新装的 OpenList，WebDAV 写入天生 403。**

---

## 一、现象

- 网页里上传文件**正常**（走 `bit3`）
- WebDAV 能列目录、能读文件下来（走 `bit8`）
- 唯独**写不进去**：PUT / 新建文件夹 / 改名 / 删除 全部 **403 Forbidden**
- RaiDrive、Finder 挂载、Windows 映射、owlfiles —— **换哪个客户端都一样**，`curl` 直接 PUT 也是 403

## 二、根因：权限位缺 `bit9`

OpenList 的权限是**按位开关**（源码注释：`internal/model/user.go`）。WebDAV 的读和写**是分开两位**：

| bit | 值 | 权限 | 上游默认 `0x71FF` |
|---|---|---|---|
| 0 | 1 | 查看隐藏文件 | √ |
| 1 | 2 | 无需密码访问 | √ |
| 2 | 4 | 添加离线下载任务 | √ |
| 3 | 8 | 创建目录 / 上传（**网页上传走这句**） | √ |
| 4 | 16 | 重命名 | √ |
| 5 | 32 | 移动 | √ |
| 6 | 64 | 复制 | √ |
| 7 | 128 | 删除 | √ |
| 8 | 256 | **WebDAV 读取** | √ |
| **9** | **512** | **WebDAV 写入 / 改名 / 删除** | **✗ 缺的就是它** |
| 10 | 1024 | FTP/SFTP 读取 | ✗ |
| 11 | 2048 | FTP/SFTP 写入 | ✗ |
| 12 | 4096 | 读取压缩包 | √ |
| 13 | 8192 | 解压压缩包 | √ |
| 14 | 16384 | 分享 | √ |

- **坏状态**：`permission = 29183` = `0x71FF` = `0b111000111111111`
- **好状态**：`permission = 29695` = `0x73FF` = 上面 **加一个 512**
- 全开参考值：`32767` = `0x7FFF`（bits 0–14 全置位，含 FTP）

于是症状完全对得上：**网页上传靠 bit3 所以能用，WebDAV 读靠 bit8 所以能列能拉，WebDAV 写靠 bit9 所以被拒。**

## 三、这是上游默认值，不是我们配错了

`internal/bootstrap/data/user.go` 里新建 admin 的那段（**v4.2.6 与 `main` 分支逐字相同**）：

```go
// 0(can see hidden) - 8(webdav read) & 12(can read archives) - 14(can share)
Permission: 0x71FF,
```

`0x71FF` 就是 **29183** —— 作者写注释时明明白白停在「8(webdav read)」，**没有带上 9(webdav write)**。
所以这是「**开箱即坏**」：装好 OpenList、配好存储、WebDAV 一连，能读不能写。

**结论：长久以来的上游默认值问题，至今（v4.2.6 = 最新 release，`main` 也一样）未修。**
不是我们的配置失误 —— 两台机器（主机 + 副机，各自独立安装）实测**都是 29183**，就是这条默认值的指纹。

> 已向用户确认过：这是「自己的仓库做个补丁」的场景，所以有本文 + `scripts/openlist-fix-webdav-write.sh`。

## 四、三种修法

### 法 1：网页上点一下（最直观）

OpenList 面板 → **管理 → 用户 → admin → 编辑** → 把 **「WebDAV 写入」** 勾上 → 保存。
（同一页里 `FTP/SFTP 写入` 如果也用得上可以一起勾；用不上就别勾。）

### 法 2：API（适合脚本化）

```bash
# 1) 登录拿 token
TOK=$(curl -s -X POST http://<IP>:5244/api/auth/login \
      -H 'Content-Type: application/json' \
      -d '{"username":"admin","password":"<密码>"}' \
      | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')

# 2) 看当前权限位（admin 是 id=1）
curl -s http://<IP>:5244/api/admin/user/list -H "Authorization: $TOK"

# 3) 回写（⚠️ 必须给完整对象，只把 permission 从 29183 改成 29695）
curl -s -X POST http://<IP>:5244/api/admin/user/update \
  -H "Authorization: $TOK" -H 'Content-Type: application/json' \
  -d '{"id":1,"username":"admin","password":"","base_path":"/","role":2,
       "disabled":false,"permission":29695,"sso_id":"","allow_ldap":true}'
```

### 法 3：用补丁脚本（推荐，自带体检 + 复验 + 实测）

```bash
cd AX6600/openlist
OL_PASS=<OpenList密码> sh ./openlist-fix-webdav-write.sh -d THW-4T http://192.168.1.1:5244 admin
```

脚本做的事，一步不多：

1. 登录 → 读 admin 的 `permission`
2. 打印**完整的 15 位权限对照表**（哪一位有、哪一位缺，一眼看到）
3. 缺 bit9 就 `permission | 512` 回写（**其他字段原样带回，一个都不改**）
4. 重新登录**复验**新值
5. `-d <存储名>` 再顺手用 WebDAV 真写一把（PUT / GET / MKCOL / MOVE / DELETE），设成不留东西

| 参数 | 作用 |
|---|---|
| （不传 IP） | 默认 `http://127.0.0.1:5244`（在路由器上直接跑） |
| `-n` | **只体检，不改**——先看看缺不缺 |
| `-d <存储名>` | 修完顺便 WebDAV 实测（例：`THW-4T` / `TWS-SD`） |
| 密码 | 优先环境变量 `OL_PASS`，没给就交互式输入（不回显） |

依赖只有 `curl` + `sed` + `awk`，**路由器上就能跑**（有 `jq` 会优先用）。

## 五、怎么验证真的好了（三层证据）

```bash
# ① 协议层：直接打 WebDAV
curl -u admin:<密码> -o /dev/null -w 'PUT   -> %{http_code}\n' -T /etc/hosts http://<IP>:5244/dav/<存储>/t.txt   # 想要 201
curl -u admin:<密码> -o /dev/null -w 'MKCOL -> %{http_code}\n' -X MKCOL          http://<IP>:5244/dav/<存储>/d # 想要 201
curl -u admin:<密码> -o /dev/null -w 'MOVE  -> %{http_code}\n' -X MOVE \
     -H "Destination: http://<IP>:5244/dav/<存储>/d/moved.txt" http://<IP>:5244/dav/<存储>/t.txt               # 想要 201
curl -u admin:<密码> -o /dev/null -w 'DEL   -> %{http_code}\n' -X DELETE         http://<IP>:5244/dav/<存储>/d # 想要 204

# ② 挂载点层：macOS 挂上后像本地文件一样操作
cp 一个文件 "/Volumes/dav/THW-4T/" && mkdir "/Volumes/dav/THW-4T/test" && mv ... && rm ...

# ③ 物理盘层（绕开 OpenList）：SSH 直查 /mnt/xxx，确认文件**真的落盘**
ls -la /mnt/sda1/_disk_check.txt
```

## 六、顺带踩到的两个坑

### 坑 1：`/dav` 是**虚拟根目录**，不能往里放文件

| 请求 | 结果 |
|---|---|
| `PUT /dav/x.txt`（往虚拟根丢文件） | **404** |
| `MKCOL /dav/xdir`（往虚拟根建目录） | **405 Method Not Allowed** |
| `PUT /dav/THW-4T/x.txt`（进到存储里） | **201** ✓ |

`/dav` 下面挂的是**存储名**（`/THW-4T`、`/TWS-SD`），本身不是可写目录。
所以客户端地址别填 `.../dav`，直接填到存储：

```
http://192.168.1.1:5244/dav/THW-4T        ← RaiDrive / Windows 映射用这个
http://192.168.3.1:5244/dav/TWS-SD
http://ax6600-thw:5244/dav/THW-4T         ← 走 Tailscale 出门也是这个
```

这样挂出来的盘符根**就是硬盘本身**，不会有「拖到根目录失败」的怪现象。
（owlfiles / CX 之类支持多存储的客户端，填 `.../dav` 当虚拟根、点进存储里操作也行。）

### 坑 2：改完 admin 权限后，**旧 token 立即失效**

`user/update` 会把该用户的已发 token 全部作废 —— 这是正常的（脚本里也是重新登录后再复验）。
表现：正开着的面板网页会突然「未登录」，**重新登录一次**即可。

## 七、回滚

只动过一个数字，回滚就是把它改回去：

```bash
# 回到上游默认（= 重新变成"能读不能写"）
... -d '{"id":1,... ,"permission":29183, ...}'
# 或者只摘掉 bit9：29695 - 512 = 29183
```

也可以用脚本看一眼再决定：`sh ./openlist-fix-webdav-write.sh -n http://<IP>:5244`。

## 八、本次实测记录（2026-09-30）

| 项目 | 主机 `192.168.1.1` | 副机 `192.168.3.1` |
|---|---|---|
| 修复前 `permission` | 29183（缺 bit9，PC 端会话已修） | **29183（缺 bit9）** |
| 修复后 `permission` | 29695 ✓ | 29695 ✓ |
| **坏状态复现** | — | PUT / DELETE 均 **403**（已复现） |
| 修后协议层 | PUT 201 / MKCOL 201 / MOVE 201 / PROPFIND 207 / DELETE 204 | 同上，另加 8 MB 整块上传 201 |
| Mac 原生挂载 | 建文件 ✓ 覆盖 ✓ 建目录 ✓ 子目录写入 ✓ 改名 ✓ 8 MB 写入 + md5 回读 ✓ 删除 ✓ | 未挂载，走 curl 验证 |
| 物理盘直查（绕开 OpenList） | `/mnt/sda2` 上文件/目录真实存在 | `/mnt/sda1` 上文件真实存在、内容一致 |
| 残留检查 | 已清空 | 已清空 |

**验证脚本**：`openlist-fix-webdav-write.sh -d THW-4T` / `-d TWS-SD` 两台复跑全绿。

## 九、附：值速查

| 值 | 十六进制 | 含义 |
|---|---|---|
| 29183 | `0x71FF` | **上游默认**（能读不能写） |
| 29695 | `0x73FF` | **+ WebDAV 写入**（本文采用的修复值） |
| 32767 | `0x7FFF` | + FTP/SFTP 读写（bits 0–14 全开） |

---

相关：`OpenList-4T硬盘挂载-操作说明.md`（把实体盘挂进 OpenList）、
`OpenList助手-界面与联动说明.md`（LuCI 插件管挂载与存储指向）。
