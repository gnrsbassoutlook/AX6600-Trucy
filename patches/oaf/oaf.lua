module("luci.controller.oaf", package.seeall)

function index()
    entry({"admin", "services", "oaf"}, firstchild(), _("Parental Control"), 20).dependent = true

    -- ===== 兼容补丁 2026-09-28 =====
    -- 背景：LuCI 底座升到 git-26.159 后，dispatcher.lua 新增了
    --   assert(not track.dependent or not track.auto,
    --          "...has no parent node so the access to this location has been denied...")
    -- dispatch 遍历请求路径时用 util.update(track, c) 把沿途每个节点的字段
    -- 合并进 track，而 util.update 基于 pairs()，拷贝不了值为 nil 的键 ——
    -- 所以中间节点残留的 auto=true 会一直带到底。
    -- OAF 只注册了 admin/services/oaf/api/<子模块>/<叶子>，"api" 和
    -- "api/<子模块>" 这两级从未注册，被 _create_node 建成 auto=true，
    -- 结果 /oaf/api/* 全部 500（页面框架正常、数据全空）。
    -- 显式把中间节点登记为 auto=false 即可修复；sysauth 等鉴权字段不受影响。
    local subs = {"system", "app_filter", "app_record", "dashboard",
                  "internet_audit", "mac_filter", "record_whitelist"}
    local s
    entry({"admin", "services", "oaf", "api"}, nil).auto = false
    for _, s in ipairs(subs) do
        entry({"admin", "services", "oaf", "api", s}, nil).auto = false
    end
    -- ===== 补丁结束 =====
end
