-- luci-app-adhfilter
-- 给 /usr/bin/adhfilter 套一个图形界面：看设备、固定 IP、加入/移出 NSFW 过滤、改名、自检。
--
-- 设计要点：
--   1) 不解析 `adhfilter devices` 的定宽文本输出 —— printf 对 UTF-8 中文不认宽度，
--      列会错位导致解析失败。这里直接读数据源（dhcp.leases / uci / ip neigh）出 JSON。
--   2) 所有传给 shell 的参数先做字面校验（IP 四段 0-255；名字仅 [A-Za-z0-9_-]，≤20 字符），
--      再套单引号拼接，避免命令注入。
--   3) ★ 路由必须 **一级扁平**（/adhfilter/devices），绝不能套 `api/` 中间层：
--      entry() 只给路径最后一段清 auto，中间节点会残留 auto=true；
--      而 dispatch() 是 `util.update(track, c)`（pairs 裸合并，值为 nil 的键拷不过来）
--      把沿途节点并进**同一个** track → 撞 dispatcher 的
--      “has no parent node” 断言 → 该子系统所有接口一起 500。
--      （luci-app-oaf 就是踩了这个坑，靠给中间节点显式 .auto=false 补救。）
--   4) ★ 主页节点 **绝不能** 带 `.leaf = true`：dispatch 的遍历里是
--      `if c.leaf then break end`，带了 leaf 就会把 /devices 也一起吃掉，
--      接口退化成返回整页 HTML（前端 json 解析失败 → 界面全空）。
--      参照 luci-app-adguardhome：主页只挂 alias/cbi，子接口各自 leaf。
--   5) 依赖 luci-compat（老式 Lua CBI 体系：controller/model/cbi/view）。

module("luci.controller.adhfilter", package.seeall)

local http = require "luci.http"
local sys  = require "luci.sys"
local uci  = require "luci.model.uci"
local fs   = require "nixio.fs"

local FILTER  = "/usr/bin/adhfilter"
local LEASES  = "/tmp/dhcp.leases"
local PIP     = "KidADH"      -- IP 锚段名前缀
local PMAC    = "KidADHM"     -- MAC 锚段名前缀（比 PIP 长，判断时先判它）
local HOSTPFX = "KidHost_"    -- 静态绑定段名前缀

function index()
	-- 主页：只渲染 CBI，不带 leaf（否则子接口全被它截胡）
	--
	-- 菜单排序号 = 11：本固件的「服务」菜单里 AdGuard Home 是 10、OAF(Parental Control) 是 20，
	-- 取 11 就正好插在 AdGuard Home 后面、顶着它显示（数字越小越靠前）。
	entry({"admin", "services", "adhfilter"},
		cbi("adhfilter/main"), _("ADH设备过滤助手"), 11)

	-- 接口：一级扁平，紧跟主页之下
	entry({"admin", "services", "adhfilter", "devices"},
		call("api_devices")).leaf = true
	entry({"admin", "services", "adhfilter", "action"},
		call("api_action")).leaf = true
	entry({"admin", "services", "adhfilter", "check"},
		call("api_check")).leaf = true
end

-- ============================ 工具函数 ============================

local function exec(cmd)
	return sys.exec(cmd .. " 2>&1") or ""
end

-- 严格校验 IPv4 字面量
local function valid_ip(ip)
	if type(ip) ~= "string" or ip == "" then return false end
	if not ip:match("^%d+%.%d+%.%d+%.%d+$") then return false end
	local n = 0
	for seg in ip:gmatch("%d+") do
		n = n + 1
		if tonumber(seg) > 255 then return false end
	end
	return n == 4
end

-- 严格校验设备名：只允许字母/数字/下划线/连字符，≤20 字符
-- （dnsmasq 的 dhcp-host name 出现中文/空格/括号会崩溃循环 → 全屋断网）
local function valid_name(nm)
	if type(nm) ~= "string" or nm == "" or #nm > 20 then return false end
	return nm:match("^[%w_%-]+$") ~= nil
end

-- 读 DHCP 租约：<过期时间> <MAC> <IP> <主机名> <clientid>
local function read_leases()
	local t = {}
	local f = io.open(LEASES, "r")
	if not f then return t end
	for line in f:lines() do
		local mac, ip, name = line:match("^%S+%s+(%S+)%s+(%S+)%s+(%S+)")
		if ip and ip ~= "*" then
			if name == "*" then name = "" end
			t[#t + 1] = { mac = mac or "", ip = ip, name = name or "" }
		end
	end
	f:close()
	return t
end

-- 读 ARP/邻居表：ip -> { mac = ..., state = ... }
--
-- ⚠️ 这里有三个坑，缺一个列表就会出问题：
--   ① BusyBox 的 `ip neigh show` 行尾**带一个空格**（`... STALE `），
--      早先的正则 `%s(%u+)$` 因此一颗都匹配不上（表现为设备全部标"离线"）。
--   ② **必须按接口名过滤，不能只按 IP 前缀**：主机的 LAN 与 WAN 是**同一网段**
--      （都是 192.168.1.0/24，光猫重叠问题），只看前缀会把 `dev wan` 的邻居
--      （光猫 192.168.1.254）当成 LAN 设备列出来。LAN 侧邻居的 dev 是 **`br-lan`**。
--   ③ **没有 `lladdr` 的行一律不要**：那是 `FAILED`（对方根本没应答，例如早已下线的
--      旧 IP）。收进来就会在界面上多出一串"空名字、空 MAC、离线"的行。
local function read_neigh(landev)
	local t = {}
	for line in exec("ip neigh show"):gmatch("[^\r\n]+") do
		local ip, dev, mac, st =
			line:match("^(%d+%.%d+%.%d+%.%d+)%s+dev%s+(%S+)%s+.*lladdr%s+(%S+)%s+([%u_]+)")
		if ip and dev == landev then
			t[ip] = { mac = mac, state = st }
		end
	end
	return t
end

-- 从 uci 读静态绑定与两类锚点
local function load_uci()
	local c = uci.cursor()
	local binds, aip, amac = {}, {}, {}

	c:foreach("dhcp", "host", function(s)
		local n = s[".name"] or ""
		if n:sub(1, #HOSTPFX) == HOSTPFX and s.ip then
			binds[s.ip] = { name = s.name or "", mac = s.mac or "", sec = n }
		end
	end)

	c:foreach("firewall", "redirect", function(s)
		local n = s[".name"] or ""
		-- 必须先判更长前缀 PMAC，否则 KidADHM_x 会被当成 IP 锚
		if n:sub(1, #PMAC + 1) == PMAC .. "_" then
			if s.src_mac then amac[s.src_mac] = n end
		elseif n:sub(1, #PIP + 1) == PIP .. "_" then
			if s.src_ip then aip[s.src_ip] = n end
		end
	end)

	return binds, aip, amac, c
end

local function adh_running()
	local p = exec("pgrep -f AdGuardHome 2>/dev/null | head -1")
	return p:match("%d+") ~= nil
end

-- 注意：sys.exec 返回的字符串带尾部换行，不能直接 == "1"，要用 match
local function adh_port_up()
	return exec("netstat -ln 2>/dev/null | grep -q ':5335' && echo AFYES"):match("AFYES") ~= nil
end

-- 判断是否「随机化 MAC」（iOS 的"私有 Wi-Fi 地址"、安卓的"随机 MAC"）
-- 规则：MAC 首字节的 bit1（值 2）为 1 → 本地管理地址 = 软件随机生成
-- 例：62:f6:02:72:42:9e… 都是随机；f8:dc:a6:3c… 是真实硬件 MAC
local function is_random_mac(m)
	if not m or m == "" then return false end
	local b = m:match("^(%x%x)")
	if not b then return false end
	local n = tonumber(b, 16)
	if not n then return false end
	return (math.floor(n / 2) % 2) == 1
end

-- 把 IP 转成可排序的数值
local function ip_key(s)
	local a, b, c, d = tostring(s or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then return 0 end
	return (tonumber(a) * 16777216) + (tonumber(b) * 65536) + (tonumber(c) * 256) + tonumber(d)
end

-- ============================ API ============================

-- GET /devices  → { devices[], filtered[], status{} }
function api_devices()
	http.prepare_content("application/json")

	local leases           = read_leases()
	local binds, aip, amac, cur = load_uci()

	local lan_ip     = cur:get("network", "lan", "ipaddr") or "192.168.1.1"
	local lan_prefix = lan_ip:gsub("%d+$", "")   -- "192.168.3.1" -> "192.168.3."

	-- LAN 桥的网卡名：本固件是 `br-lan`。注意 `network.lan.device` 常为空、
	-- `network.lan.ifname` 填的是端口列表（"lan1 lan2 lan3 lan4"），都拿不到桥名，
	-- 所以取不到时直接兜底 "br-lan"。
	local landev = cur:get("network", "lan", "device")
	if not landev or landev == "" then landev = "br-lan" end

	local neigh = read_neigh(landev)

	local devs, seen = {}, {}

	local function mk(ip, mac, name, bindname, bound)
		local b = binds[ip]
		return {
			ip       = ip,
			mac      = mac or "",
			name     = name or "",
			bindname = bindname or (b and b.name) or "",
			bound    = bound ~= nil and bound or (b ~= nil),
			filtered = (aip[ip] ~= nil) or ((mac or "") ~= "" and amac[mac] ~= nil),
			online   = neigh[ip] ~= nil and neigh[ip].state ~= "FAILED",
			randmac  = is_random_mac(mac),
		}
	end

	-- 1) 有租约的设备（当前在网的）
	for _, l in ipairs(leases) do
		devs[#devs + 1] = mk(l.ip, l.mac, l.name)
		seen[l.ip] = true
	end

	-- 2) 有静态绑定但当前没租约的（离线设备，也要能操作）
	for ip, b in pairs(binds) do
		if not seen[ip] then
			devs[#devs + 1] = mk(ip, b.mac, "", b.name, true)
			seen[ip] = true
		end
	end

	-- 3) 只在邻居表里、既无租约也无绑定的（例如自己设了静态 IP 的设备）
	--    read_neigh 已保证：只收 LAN 桥(br-lan)上、且真有 MAC 的邻居
	for ip, n in pairs(neigh) do
		if not seen[ip] and ip:sub(1, #lan_prefix) == lan_prefix then
			devs[#devs + 1] = mk(ip, n.mac, "", "", false)
			seen[ip] = true
		end
	end

	table.sort(devs, function(x, y) return ip_key(x.ip) < ip_key(y.ip) end)

	-- 名单（已过滤的设备）
	local flist = {}
	local n_ip, n_mac = 0, 0
	for ip, _ in pairs(aip) do
		n_ip = n_ip + 1
		local b = binds[ip]
		flist[#flist + 1] = {
			ip         = ip,
			name       = (b and b.name ~= "" and b.name) or ip,
			mac        = (b and b.mac) or "",
			mac_anchor = (b and b.mac ~= "" and amac[b.mac] ~= nil) and true or false,
		}
	end
	for _ in pairs(amac) do n_mac = n_mac + 1 end
	table.sort(flist, function(x, y) return ip_key(x.ip) < ip_key(y.ip) end)

	http.write_json({
		devices  = devs,
		filtered = flist,
		status   = {
			has_tool    = fs.access(FILTER) and true or false,
			adh_running = adh_running(),
			adh_port    = adh_port_up(),
			lan_ip      = lan_ip,
			anchor_ip   = n_ip,
			anchor_mac  = n_mac,
			rules_total = n_ip + n_mac,
		},
	})
end

-- 是否已有静态绑定（固定 IP）
local function is_bound(ip)
	local sec = HOSTPFX .. (ip:gsub("%.", "_"))
	return uci.cursor():get("dhcp", sec) ~= nil
end

local function run_ok(out)
	return not (out:find("!!", 1, true) or out:find("失败", 1, true)
		or out:find("已回滚", 1, true) or out:find("找不到", 1, true))
end

-- 复合动作（界面主用它）：
--   block   = 先固定 IP（若还没固定）+ 加入过滤   ← 一步到位，防止设备换 IP 后漏过滤
--   unblock = 移出过滤（规则与静态绑定一起删）
local ACTIONS = {
	bind = true, add = true, del = true, resync = true, rename = true,
	block = true, unblock = true,
}

-- POST /action  { action, target, newname }  → { ok, msg }
function api_action()
	http.prepare_content("application/json")

	local act     = http.formvalue("action") or ""
	local target  = http.formvalue("target") or ""
	local newname = http.formvalue("newname") or ""

	if not ACTIONS[act] then
		http.write_json({ ok = false, msg = "未知操作: " .. act })
		return
	end
	if not (valid_ip(target) or valid_name(target)) then
		http.write_json({ ok = false, msg = "目标不合法：只接受 IP 地址或 字母/数字/下划线/连字符 组成的名字" })
		return
	end

	-- ---------- 复合动作 ----------
	if act == "unblock" then
		local out = exec(string.format("%s del '%s'", FILTER, target))
		http.write_json({ ok = run_ok(out), msg = out, action = act, target = target })
		return
	end

	if act == "block" then
		local parts = {}
		if valid_ip(target) and not is_bound(target) then
			parts[#parts + 1] = exec(string.format("%s bind '%s'", FILTER, target))
		end
		parts[#parts + 1] = exec(string.format("%s add '%s'", FILTER, target))
		local out = table.concat(parts, "\n")
		http.write_json({ ok = run_ok(out), msg = out, action = act, target = target })
		return
	end

	-- ---------- 细粒度动作 ----------
	local cmd
	if act == "rename" then
		if not valid_name(newname) then
			http.write_json({ ok = false, msg = "新名字只能用 字母/数字/下划线/连字符，且不超过 20 字符（中文会让 dnsmasq 崩溃）" })
			return
		end
		cmd = string.format("%s rename '%s' '%s'", FILTER, target, newname)
	else
		cmd = string.format("%s %s '%s'", FILTER, act, target)
	end

	local out = exec(cmd)

	http.write_json({ ok = run_ok(out), msg = out, action = act, target = target })
end

-- GET /check  → { ok, text }
function api_check()
	http.prepare_content("application/json")
	http.write_json({ ok = true, text = exec(FILTER .. " check") })
end
