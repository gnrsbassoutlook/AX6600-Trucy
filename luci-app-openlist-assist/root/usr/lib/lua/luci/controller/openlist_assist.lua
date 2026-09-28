-- luci-app-openlist-assist
-- 「OpenList 助手」：给 /usr/bin/diskctl 套一个图形界面 —— 看盘、挂载、卸载、
-- 强力挂载/卸载、清 NTFS 脏标记、安全弹出、格式化、启停 OpenList。
--
-- ★ 路由设计（照抄 luci-app-adhfilter 踩出来的经验，别改）
--   1) **一级扁平**：接口是 /openlist-assist/devices、/openlist-assist/action，
--      绝不套 `api/` 之类的中间层。原因：entry() 只给路径最后一段清 auto，
--      中间节点会残留 auto=true；而 dispatch() 是 util.update(track, c)
--      （pairs 裸合并），把沿途节点并进同一个 track → 撞 dispatcher 的
--      "has no parent node" 断言 → 该子系统所有接口一起 500。
--   2) 主页节点**绝不能**带 .leaf = true：dispatch 的遍历里是
--      `if c.leaf then break end`，带了 leaf 会把 /devices、/action 一起吃掉，
--      接口退化成返回整页 HTML（前端 JSON 解析失败 → 界面全空）。
--   3) ★ 用 template() 而不是 cbi()：CBI 页面会把我们的内容包进 LuCI
--      自己的 <form onsubmit=...>，而 <button> 不写 type 时默认是 submit ——
--      点一下按钮就顺手提交表单、整页重载，把刚发出的 XHR 掐断。
--      （adhfilter 就是踩了这个坑：点封禁"闪一下"、多选只搬第一台。）
--      走 template() 则整页没有 form，从根上没这个问题。
--      代价是 view 里要自己写 <%+header%> / <%+footer%>。
--
-- 依赖 luci-compat（老式 Lua 体系）。

module("luci.controller.openlist_assist", package.seeall)

local http = require "luci.http"
local sys  = require "luci.sys"

local DISKCTL = "/usr/bin/diskctl"

function index()
	-- 主页：不带 leaf
	-- order = 12：本固件「服务」菜单里 AdGuard Home 是 10、ADH设备过滤助手 是 11、
	-- 应用过滤(OAF) 是 20 —— 取 12 正好排在自己的过滤助手后面。
	entry({"admin", "services", "openlist-assist"},
		template("openlist_assist/main"), _("OpenList 助手"), 12)

	-- 接口：一级扁平、各自 leaf
	entry({"admin", "services", "openlist-assist", "devices"},
		call("api_devices")).leaf = true
	entry({"admin", "services", "openlist-assist", "action"},
		call("api_action")).leaf = true
end

-- ============================ 参数校验 ============================

-- 设备名：USB 的 sda / sda2，或内置白名单的 mmcblk0p27。
-- 只放小写字母和数字 —— 没有斜杠、点号、短横、空格、引号，
-- 路径穿越和命令注入都无从谈起（真正的安全闸门在 diskctl 里）。
local function valid_dev(d)
	if type(d) ~= "string" or #d > 16 then return false end
	return d:match("^[a-z0-9]+$") ~= nil
end

local function valid_fs(f)
	return f == "exfat" or f == "vfat" or f == "ext4"
end

-- 动作白名单：分两类，避免写一长串 if-else 还漏判
local NEED_TARGET = {
	mount = true, umount = true, clean = true, dirty = true,
	eject = true, format = true,
}
local NO_TARGET = {
	mountall = true, umountall = true,
	openlist_start = true, openlist_stop = true,
	tools = true, tools_install = true, log = true,
}
-- 纯「报告」类动作：它们的输出里出现 ❌ 只表示"查出某样东西缺失"，
-- 不代表这次操作本身失败。（工具自检就是这么被误判成失败的。）
local REPORT_ONLY = { tools = true, tools_install = true, log = true }

-- 所有外部命令都走这里：参数先过白名单正则，再单引号包裹 —— 没有注入余地。
-- 注意点号允许（--force 等选项要用），但绝不允许引号/分号/空格/反引号。
local function run(args)
	local parts = {}
	for _, a in ipairs(args) do
		if a and a ~= "" then
			if not a:match("^[%w%-%./]+$") then
				return "❌ 内部错误：参数不合法（" .. tostring(a) .. "）"
			end
			parts[#parts + 1] = "'" .. a .. "'"
		end
	end
	return sys.exec(table.concat(parts, " ") .. " 2>&1") or ""
end

-- ============================ 接口 ============================

-- GET /devices  → 直接透传 diskctl json 的输出
-- （diskctl 自己生成合法 JSON；这里不重复解析，省一层出错机会）
function api_devices()
	http.prepare_content("application/json")

	local j = sys.exec(DISKCTL .. " json 2>/dev/null") or ""
	j = j:gsub("^%s+", ""):gsub("%s+$", "")

	if j == "" or j:sub(1, 1) ~= "{" then
		http.write_json({
			devs = {}, tools = {}, kernel = "",
			openlist = { running = false, pid = "" },
			err = "读不到设备列表（diskctl 可能没装好）",
		})
		return
	end

	http.write(j)
end

-- POST /action  { action, target, fs, force, ro, stop }  → { ok, msg, action }
function api_action()
	http.prepare_content("application/json")

	local act    = http.formvalue("action") or ""
	local target = http.formvalue("target") or ""
	local fsname = http.formvalue("fs") or ""
	local bforce = http.formvalue("force") == "1"
	local bro    = http.formvalue("ro") == "1"
	local bstop  = http.formvalue("stop") == "1"

	local function reply(ok, msg)
		http.write_json({ ok = ok, msg = msg, action = act, target = target })
	end

	local out

	-- 先过白名单：不在表里的一律拒，不往下走（比"设备在不在"更根本）
	if not (NEED_TARGET[act] or NO_TARGET[act]) then
		reply(false, "❌ 未知操作：" .. act)
		return
	end

	-- 格式化类型也要先校验（同样比"设备在不在"更根本）
	if act == "format" and not valid_fs(fsname) then
		reply(false, "❌ 不支持的格式化类型（只能 exfat / vfat / ext4）")
		return
	end

	-- ---------- 不需要 target 的动作 ----------
	if act == "mountall" then
		out = run({ DISKCTL, "mount", "all", bforce and "--force" or nil })
	elseif act == "umountall" then
		out = run({ DISKCTL, "umount", "all", bforce and "--force" or nil,
			bstop and "--stop" or nil })
	elseif act == "openlist_start" then
		out = run({ DISKCTL, "openlist", "start" })
	elseif act == "openlist_stop" then
		out = run({ DISKCTL, "openlist", "stop" })
	elseif act == "tools" then
		out = run({ DISKCTL, "tools" })
	elseif act == "tools_install" then
		out = run({ DISKCTL, "tools", "--install" })
	elseif act == "log" then
		out = run({ DISKCTL, "log", "60" })

	-- ---------- 需要 target 的动作 ----------
	else
		if not valid_dev(target) then
			reply(false, "❌ 目标不合法：设备名只能是 sda / sda2 / mmcblk0p27 这种形式")
			return
		end
		-- 设备必须真的存在，避免对空气操作
		if sys.call("test -b '/dev/" .. target .. "'") ~= 0 then
			reply(false, "❌ /dev/" .. target .. " 不存在（盘是不是被拔了？）")
			return
		end

		if act == "mount" then
			out = run({ DISKCTL, "mount", target,
				bforce and "--force" or nil, bro and "--ro" or nil })
		elseif act == "umount" then
			out = run({ DISKCTL, "umount", target,
				bforce and "--force" or nil, bstop and "--stop" or nil })
		elseif act == "clean" then
			out = run({ DISKCTL, "clean", target, bstop and "--stop" or nil })
		elseif act == "dirty" then
			out = run({ DISKCTL, "dirty", target })
		elseif act == "eject" then
			out = run({ DISKCTL, "eject", target, bstop and "--stop" or nil })
		elseif act == "format" then
			-- 类型已在校验区确认过，这里直接执行
			out = run({ DISKCTL, "format", target, fsname, "--yes" })
		else
			reply(false, "❌ 未知操作：" .. act)
			return
		end
	end

	-- 成败判据：执行类动作看输出里有没有 "❌"（diskctl 的约定）；
	-- 报告类动作（工具自检 / 看日志）恒为成功 —— 它们报的是"状态"不是"失败"。
	local ok = REPORT_ONLY[act] or (out:find("❌") == nil)
	reply(ok, out)
end
