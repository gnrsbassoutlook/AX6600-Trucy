-- luci-app-adhfilter / CBI 外壳
-- 页面主体由 view/adhfilter/main.htm 渲染（OAF 用的是同一套机制：
--   m:section(SimpleSection).template = "<view 路径>"）。

local m, s

m = Map("adhfilter", translate("ADH设备过滤助手"),
	translate("按设备决定谁走 AdGuard Home 的 NSFW 过滤。未列入名单的设备正常上网；列入的设备多一层 93 万条黑名单拦截。"))

s = m:section(SimpleSection)
s.template = "adhfilter/main"

return m
