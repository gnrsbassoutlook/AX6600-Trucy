# OAF（应用过滤）界面"白花花、数据全空"修复记录

- 日期：2026-09-28
- 对象：新主机 `192.168.1.1`（AX6600 魔改 4G+128G，bleachwrt 20260916 / R26.05.20）
- 组件：`appfilter 7.0.1-1` + `luci-app-oaf 7.0-1` + `luci-i18n-oaf-zh-cn` + `kmod-oaf`；LuCI 底座 `git-26.159.06565`
- 结论：**服务端路由缺陷，与主题、浏览器、手机/电脑无关**。已修复并全量验证。

---

## 一、症状

- `LuCI → 服务 → 应用过滤` 各标签页**框架能渲染**（标签栏、"过滤规则"标题、弹窗都不缺），但**内容全空**：
  - 仪表盘：图表区、用户列表、流量区一片空白；
  - 应用过滤 → 点"添加规则"：弹窗能弹出，"**选择应用**"下拉永远是空的；
  - 其他标签页同样"白花花，什么都读不出来"。
- 用**手机**访问看着正常（同一套页面、同一批接口，只是窄屏布局分支不同，让人误以为是电脑/主题问题）。

## 二、根因（已用证据锁定）

### 1. 页面数据全靠异步接口

OAF 的 htm 页面自身是静态骨架，所有数据由 JS 通过 XHR 拉取，例如：

```
/cgi-bin/luci/admin/services/oaf/api/dashboard/get_dashboard_common
/cgi-bin/luci/admin/services/oaf/api/dashboard/get_app_type_stats?type=day
/cgi-bin/luci/admin/services/oaf/api/app_filter/class_list      ← "选择应用"的列表
```

### 2. 这些接口**全部**返回 HTTP 500

```
/usr/lib/lua/luci/dispatcher.lua:358: Access Violation
The page at 'admin/services/oaf/api/dashboard/get_app_type_stats/' has no parent node
so the access to this location has been denied.
```

而同一控制器里注册的**页面**路由却正常（HTTP 200）—— 所以"页面能开、数据没有"。

### 3. 为什么只有 `api/*` 被拒

LuCI 新版 dispatcher 的路径遍历：

```lua
-- dispatcher.lua  ~255
for i, s in ipairs(request) do
    c = c.nodes[s]
    if not c then break end
    util.update(track, c)          -- 沿途每个节点的字段合并进 track
    if c.leaf then break end
end
...
track.dependent = (track.dependent ~= false)
assert(not track.dependent or not track.auto, "...has no parent node...")   -- 第 358 行
```

而 `node()`（注册路由时用）是这样清标记的：

```lua
function node(...)
    local c = _create_node({...})
    c.auto = nil                   -- ← 把键"删掉"，而不是置成 false
    return c
end
```

`util.update` 内部是 `for k, v in pairs(a) do t[k] = v end` —— **`pairs()` 永远不会返回值为 nil 的键**，所以一旦某个中间节点把 `track.auto` 置成 `true`，后面即使是正式注册的叶子节点也**清不掉**它。

再看 OAF 的注册方式：

```lua
-- oaf_dashboard.lua
entry({"admin", "services", "oaf", "dashboard"}, cbi(...))            -- 页面：这一级被注册 → 能开
entry({"admin", "services", "oaf", "api", "dashboard", "get_xxx"},
      call("get_xxx")).leaf = true                                    -- 接口：只注册叶子
```

`admin / services / oaf` 三级都有正式 `entry()`；但 **`api` 和 `api/<子模块>` 这两级从来没有任何 `entry()` 注册过**，只能由 `_create_node` 隐式创建：

```lua
c = {nodes={}, auto=true, inreq=true}     -- dispatcher.lua ~660
```

于是请求 `/oaf/api/...` 时，`track.auto` 被中途的 `api`（以及 `api/dashboard`）染成 `true`，一路带到第 358 行的断言 → **整棵 `api` 子树全灭**。

> 对照：`app_filter`、`users`、`mac_filter` 等**页面**节点是用 `entry({...,"app_filter"}, alias(...))` 显式注册的，所以页面 200、接口 500 —— 这个"页面 vs 接口"的差异正是根因的指纹。

## 三、修复（两处补丁，均已部署）

### 补丁 1：把中间节点显式登记为 `auto=false`

文件 `/usr/lib/lua/luci/controller/oaf.lua`，在 `index()` 内追加（挂在此文件是因为它**必然被加载、必然执行**，且与加载先后无关：先跑则后续 `_create_node` 复用同一对象；后跑则 `node()` 已把 auto 置 nil，再显式置 false）：

```lua
local subs = {"system", "app_filter", "app_record", "dashboard",
              "internet_audit", "mac_filter", "record_whitelist"}
entry({"admin", "services", "oaf", "api"}, nil).auto = false
for _, s in ipairs(subs) do
    entry({"admin", "services", "oaf", "api", s}, nil).auto = false
end
```

> 这 8 个节点是用脚本扫全部 96 条 `entry()` 路由、算出"被依赖但从未注册"的中间前缀得到的（`admin` / `admin/services` 由 LuCI 自带，无需处理）。
> `auto` 在本版 dispatcher 里**只被那一处断言读取**，`dependent` / `sysauth`（鉴权）完全不受影响。

### 补丁 2：补上插件自己漏写的函数

`/usr/lib/lua/luci/controller/oaf_user.lua` 里注册了

```lua
entry({..., "api", "get_online_offline_records"}, call("get_online_offline_records"), nil).leaf = true
```

但**这个函数从未定义**，dispatcher 报 `Cannot resolve function "get_online_offline_records"` → 恒 500，用户详情页的"在线/离线记录"永远空白并在控制台报错。补一个空实现：

```lua
function get_online_offline_records()
    luci.http.prepare_content("application/json")
    luci.http.write_json({ records = {} })
end
```

## 四、验证结果

清掉索引缓存（`rm -rf /tmp/luci-indexcache /tmp/luci-modulecache`）后，把从控制器源码里提取出的**全部 72 条 `/oaf/api/*` 接口**逐条打了一遍：

| 项目 | 修复前 | 修复后 |
|---|---|---|
| `api/*` 接口（72 条） | **全部 500**（has no parent node） | **69 条 200**；余 3 条为需要 POST 参数的写接口，参数给对后同样 200 |
| 仪表盘 9 个接口 | 全 500 | 全 200，返回真实数据 |
| `app_filter/class_list`（"选择应用"列表） | 500 | 200，**10,740 字节应用清单** |
| `mac_filter/*` 写接口 | 500 | `data=<json>` 或 `mac=` 正确传参后 200 |
| 页面路由（10 个子页） | 200 | 200（未受影响） |

抽样实测（经 Mac 有线网卡 192.168.1.112）：
- `api/dashboard/get_dashboard_common` → 200，8.4KB（含 WAN 状态、活跃应用）
- `api/app_filter/class_list` → 200，10.7KB
- `api/dashboard/get_active_users?count=8` → 200，2.5KB（能看到在线设备的 IP/主机名）

## 五、回滚方式

```sh
# 恢复原控制器
cp /root/oaf.lua.bak.<时间戳>      /usr/lib/lua/luci/controller/oaf.lua
cp /root/oaf_user.lua.bak.<时间戳> /usr/lib/lua/luci/controller/oaf_user.lua
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
```

本地副本：`oaf.lua`（已打补丁的控制器文件，可直接覆盖部署）。

## 六、注意事项

1. **升级/重装 `luci-app-oaf` 会覆盖这两个文件，补丁需重打。**
2. LuCI 的 `luci-indexcache` / `luci-modulecache` 需清掉才生效（**后者是目录，用 `rm -rf`**）。
3. 遗留项（**不是**本次白屏的原因，不影响使用）：主题 `luci-theme-argon 1.8.4`（19.07 时代）与底座 `git-26.159` 错配，同一页面会加载两份 `cbi.js`（`?v=1.8.4` + `?v=git-26.159`）和两个 jQuery。属隐患，想换主题可换 Bootstrap / Design，**不换也能用**。
4. 打包垃圾 `/usr/lib/lua/luci/view/oaf/.dashboard.htm.swp`（176KB vim 交换文件）可删。
5. 通用经验：**老式 Lua 插件 + 新版 LuCI 出现"页面能开、数据全空"，先去 `logread` 找 `has no parent node`**，那是路由注册缺中间节点，不是前端/主题问题。
