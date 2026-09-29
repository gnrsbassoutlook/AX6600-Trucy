/* 离线仿真：验证「OpenList 存储 · 改指向 / 新建存储」这一套交互。
   把真机 main.htm 的 <script> 段抠出来，桩掉 DOM/XHR，然后：
     ① 渲染存储表格 —— 看每行有没有「改指向…」按钮、路径没挂上时是不是主按钮
     ② 模拟点击「改指向…」 —— 看选择器列出了哪些盘、eMMC 在不在里面
     ③ 模拟点「确定」 —— 看真正发出去的 POST 参数对不对
   目的：不开浏览器、不碰真机，就能验证这套交互。

   用法：
     node tools/render-olsim.js <main.htm 路径> [repoint|new|cold]
       repoint（默认） 改指向，且目标盘【已挂载】
       new             新建存储
       cold            改指向，但原来那块盘【已拔】、且只有一块盘可选
*/
const fs = require("fs");

const HTM = process.argv[2];
const CASE = process.argv[3] || "repoint";
if (!HTM) { console.error("用法: node tools/render-olsim.js <main.htm> [repoint|new|cold]"); process.exit(1); }

/* ---------- 1. 抠出 script 段 ---------- */
const raw = fs.readFileSync(HTM, "utf8");
const m = raw.match(/<script>([\s\S]*?)<\/script>/);
if (!m) { console.error("找不到 <script> 段"); process.exit(1); }
let js = m[1];
js = js.replace(/<%=\s*url\('([^']+)'\)\s*%>/g, "/cgi-bin/luci/$1");
if (/<%/.test(js)) { console.error("还有未替换的模板标签"); process.exit(1); }

/* ---------- 2. 合成数据 ---------- */
const DEV = {
  /* 一块 1.8G 的 exfat 小盘（已挂载）+ 内置 eMMC（未挂载）—— 副机的真实样子 */
  small: [
    { name:"sda", kind:"disk", parent:"sda", size_h:"1.8G", fstype:"", model:"Generic- SD/MMC" },
    { name:"sda1", kind:"part", parent:"sda", size_h:"1.8G", fstype:"exfat", mount:"/mnt/sda1",
      mounted:true, label:"SD", uuid:"1234-ABCD", used_kb:723000, total_kb:1929148 },
    { name:"mmcblk0p27", kind:"ipart", parent:"mmcblk0", size_h:"111.5G", fstype:"ext4",
      model:"SLD128", uuid:"ec444341-4596-4d00-b0c9-36ca8ca223e4" }
  ],
  /* 换盘现场：4T NTFS 插着（sda2），存储却还指着上一块盘的 /mnt/sdb1 */
  swapped: [
    { name:"sda", kind:"disk", parent:"sda", size_h:"3.6T", fstype:"", model:"ATA ST4000VX005-2LY1" },
    { name:"sda1", kind:"part", parent:"sda", size_h:"16.0M", fstype:"" },
    { name:"sda2", kind:"part", parent:"sda", size_h:"3.6T", fstype:"ntfs", mount:"/mnt/sda2",
      mounted:true, uuid:"8CB8C15FB8C14902", used_kb:2684258840, total_kb:3907000316 },
    { name:"mmcblk0p27", kind:"ipart", parent:"mmcblk0", size_h:"111.5G", fstype:"ext4", model:"SLD128" }
  ],
  /* 一块盘都没有（只有 eMMC，且没挂） */
  nothing: [
    { name:"mmcblk0p27", kind:"ipart", parent:"mmcblk0", size_h:"111.5G", fstype:"ext4", model:"SLD128" }
  ]
};

const CASES = {
  repoint: { devs: DEV.small,
             storage: [{ id:1, mount_path:"/TWS-SD", driver:"Local", status:"work", disabled:false, root:"/mnt/sda1" }] },
  new:     { devs: DEV.small, storage: [] },
  cold:    { devs: DEV.swapped,
             storage: [{ id:1, mount_path:"/THW-4T", driver:"Local", status:"work", disabled:false, root:"/mnt/sdb1" }] }
};
const C = CASES[CASE] || CASES.repoint;

const PAYLOAD = {
  devs: C.devs,
  tools: { ntfs3:true, exfat:true, vfat:true, mkfs_exfat:true, mkfs_vfat:true, mkfs_ext4:true,
           mkfs_ntfs:false, ntfsfix:false, fsck_exfat:true, fsck_vfat:true },
  openlist: { running:true, pid:"4860" },
  kernel: "6.12.93", log_file:"/tmp/diskctl.log",
  internal_devs: "mmcblk0p27 ", internal_mount: "/mnt/emmc",
  storages: { ok:true, err:"", storage: C.storage }
};

/* ---------- 3. DOM / XHR 桩 ---------- */
const ELS = {};
function El(id) {
  this.id = id; this.innerHTML = ""; this.textContent = ""; this.value = "";
  this.style = {}; this.children = []; this.className = ""; this.checked = false;
  this.disabled = false; this.scrollTop = 0; this.scrollHeight = 0; this.lastElementChild = null;
  const noop = function () {};
  this.classList = { add:noop, remove:noop, toggle:noop, contains:function(){return false;} };
  this.appendChild = function (c) { this.children.push(c); };
  this.removeChild = function () {};
  this.getAttribute = function () { return null; };
  this.setAttribute = noop; this.focus = noop;
}
/* 选择器桩：把「已勾中的目标」固定成 sda1，让 olPickOk 走得下去 */
const PICKED = { value: "sda1" };
const docHandlers = {};
global.document = {
  readyState: "complete",
  getElementById: function (id) { return ELS[id] || (ELS[id] = new El(id)); },
  createElement: function (tag) { return new El(tag); },
  addEventListener: function (ev, fn) { (docHandlers[ev] = docHandlers[ev] || []).push(fn); },
  querySelector: function (sel) {
    if (sel === 'input[name="oa-olp-t"]:checked') { return PICKED; }
    if (sel === 'input[name="oa-olp-t"]:not([disabled])') { return { checked: false }; }
    return null;              /* input[name="token"] 也走这里 → token() 拿到空串 */
  }
};
global.window = global;
global.confirm = function () { return true; };
global.setTimeout = function () { return 0; };
global.clearTimeout = function () {};

let LAST_REQ = null;
global.XMLHttpRequest = function () {
  const self = this;
  this.readyState = 0; this.status = 0; this.responseText = ""; this.timeout = 0;
  this.open = function (method, url) { self._m = method; self._u = url; };
  this.setRequestHeader = function () {};
  this.send = function (data) {
    LAST_REQ = { method: self._m, url: self._u, data: data };
    self.readyState = 4; self.status = 200;
    self.responseText = JSON.stringify(PAYLOAD);
    if (self.onreadystatechange) { self.onreadystatechange(); }
  };
};

/* ---------- 4. 跑 ---------- */
eval(js);

/* ---------- 5. 输出 ---------- */
function textOf(html) {
  return String(html || "")
    .replace(/<[^>]+>/g, " ")
    .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&#8943;/g, "…")
    .replace(/[ \t]+/g, " ").trim();
}

console.log("### 用例: " + CASE + "\n");

console.log("===== 存储表 oa-ol-body =====");
const bodyHtml = ELS["oa-ol-body"] ? ELS["oa-ol-body"].innerHTML : "";
console.log(textOf(bodyHtml).replace(/\s*改指向…/g, "\n   [改指向…]") + "\n");

console.log("===== 模拟点击入口 =====");
let clicked;
if (CASE === "new") {
  ELS["oa-ol-new"].onclick();
  document.getElementById("oa-olp-name").value = "/TWS-SD";
  clicked = { desc: "点「新建存储」", sel: "oa-ol-new" };
} else {
  /* 点第一个「改指向…」按钮 */
  const fake = {
    getAttribute: function (k) {
      if (k === "data-olmap") { return String(C.storage[0].id); }
      return null;
    },
    classList: { toggle: function () {}, add: function () {}, remove: function () {} }
  };
  (docHandlers.click || []).forEach(function (fn) {
    fn({ target: fake, preventDefault: function () {} });
  });
  clicked = { desc: "点「改指向…」", sel: 'data-olmap="' + C.storage[0].id + '"' };
}
console.log(clicked.desc + "  [" + clicked.sel + "]");

console.log("\n===== 选择器 oa-ol-pick =====");
const pickHtml = ELS["oa-ol-pick"] ? ELS["oa-ol-pick"].innerHTML : "";
console.log(textOf(pickHtml) || "（空 —— 没有可选目标或者选择器没打开）");

/* 选择器里列了几个目标？ */
const radioN = (pickHtml.match(/name="oa-olp-t"/g) || []).length;
const disN   = (pickHtml.match(/ disabled/g) || []).length;
const nameIn = pickHtml.indexOf("oa-olp-name") >= 0;

/* ★ 从渲染出来的 HTML 里推断「实际会被勾中的那个」：
   桩里的 querySelector 认不出节点，所以直接读 HTML 更准 ——
   有 checked 的用它，否则用第一个没 disabled 的（与页面里的兜底逻辑一致）。 */
const reRadio = /<input type="radio" name="oa-olp-t" value="([^"]*)"([^>]*)>/g;
let mr, firstEnabled = null, checkedOne = null;
while ((mr = reRadio.exec(pickHtml)) !== null) {
  const val = mr[1], attrs = mr[2];
  if (attrs.indexOf("disabled") < 0 && firstEnabled === null) { firstEnabled = val; }
  if (attrs.indexOf("checked") >= 0) { checkedOne = val; }
}
const EFFECTIVE = checkedOne || firstEnabled;
if (EFFECTIVE) { PICKED.value = EFFECTIVE; }
console.log("  实际会提交的目标: " + (EFFECTIVE || "（无）")
            + (checkedOne ? "（默认勾中的那个）" : "（自动勾第一个可用的）"));

console.log("\n===== 模拟点「确定」 =====");
const okFake = { getAttribute: function (k) { return k === "data-olp" ? "ok" : null; },
                 classList: { toggle:function(){}, add:function(){}, remove:function(){} } };
(docHandlers.click || []).forEach(function (fn) {
  fn({ target: okFake, preventDefault: function () {} });
});
console.log("  发出去的请求: POST " + (LAST_REQ ? LAST_REQ.url : "(没发)"));
console.log("  body: " + (LAST_REQ ? decodeURIComponent(LAST_REQ.data) : "(空)"));

/* ---------- 6. 断言 ---------- */
console.log("\n===== 断言 =====");
const hasMapBtn = bodyHtml.indexOf("data-olmap") >= 0;
const tableCols  = (bodyHtml.match(/<th>/g) || []).length;
const pickOk     = radioN >= 1;
/* 一个存储都没有时，表格区渲染的是空状态文案 —— 没有按钮/表头是正常的 */
if (CASE !== "new") {
  console.log("  存储表有「改指向…」按钮: " + (hasMapBtn ? "✅" : "❌"));
  console.log("  存储表列数 (期望 5: 名称/类型/根路径/状态/操作): " + tableCols
              + (tableCols === 5 ? " ✅" : " ❌"));
} else {
  console.log("  无存储时表格区是空状态文案: "
              + (bodyHtml.indexOf("还没有配置任何存储") >= 0 ? "✅" : "❌"));
}
console.log("  选择器列出目标数: " + radioN + "（其中禁用 " + disN + " 个）"
            + (pickOk ? " ✅" : " ❌"));

const wantAction = (CASE === "new") ? "action=ol_new" : "action=ol_repoint";
const wantDev    = "target=" + (EFFECTIVE || "sda1");
const sent = LAST_REQ ? decodeURIComponent(LAST_REQ.data) : "";
const sentOk = sent.indexOf(wantAction) >= 0 && sent.indexOf(wantDev) >= 0;
console.log("  提交参数正确 (" + wantAction + " + " + wantDev + "): " + (sentOk ? "✅" : "❌ " + sent));

/* ---------- 7. 各用例的专项检查 ---------- */
console.log("\n===== 专项检查 =====");
if (CASE === "repoint") {
  const isPrimary = /data-olmap="1"[^>]*class|class="oa-btn oa-mini oa-primary"/.test(bodyHtml);
  console.log("  根路径已挂载 → 「改指向」是普通次要按钮（不该抢眼）: "
              + (bodyHtml.indexOf("oa-btn oa-mini oa-primary\" data-olmap") < 0 ? "✅" : "❌"));
  console.log("  eMMC 出现在选择器里: " + (pickHtml.indexOf("mmcblk0p27") >= 0 ? "✅" : "❌"));
  console.log("  未挂载的 eMMC 被标成「未挂载 —— 先把它挂上」: "
              + (pickHtml.indexOf("未挂载") >= 0 ? "✅" : "❌"));
  console.log("  选择器里标出了「当前」指向: " + (pickHtml.indexOf("当前") >= 0 ? "✅" : "❌"));
} else if (CASE === "cold") {
  console.log("  根路径【没挂载】→ 「改指向」升级为主按钮: "
              + (bodyHtml.indexOf('oa-btn oa-mini oa-primary" data-olmap') >= 0 ? "✅" : "❌"));
  console.log("  表格里标出「根路径未挂载」: " + (bodyHtml.indexOf("根路径未挂载") >= 0 ? "✅" : "❌"));
  console.log("  顶部红字提示「存储离线」: " + (ELS["oa-strip"].innerHTML.indexOf("存储离线") >= 0 ? "✅" : "❌"));
  console.log("  原路径那块盘没了 → 自动勾第一个可用目标（不会一个都不勾）: "
              + (EFFECTIVE === "sda2" && sent.indexOf("target=sda2") >= 0 ? "✅" : "❌ " + EFFECTIVE));
} else if (CASE === "new") {
  console.log("  没有存储时，表格区提示去新建: " + (ELS["oa-ol-body"].innerHTML.indexOf("还没有配置任何存储") >= 0 ? "✅" : "❌"));
  console.log("  选择器里有存储名输入框: " + (nameIn ? "✅" : "❌"));
  console.log("  eMMC 也在可选项里: " + (pickHtml.indexOf("mmcblk0p27") >= 0 ? "✅" : "❌"));
}
