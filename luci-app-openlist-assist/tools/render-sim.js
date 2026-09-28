/* 离线渲染仿真：把真机 main.htm 的 <script> 段抠出来，桩掉 DOM/XHR，
   喂进合成的「多块 USB 盘 / 盘柜 / RAID 逻辑盘」数据，dump 渲染结果。
   目的：不开浏览器验证「多盘怎么显示」。 */
const fs = require("fs");
const path = require("path");

const HTM = process.argv[2];
const CASE = process.argv[3] || "multi";

/* ---------- 1. 抠出 script 段 ---------- */
const raw = fs.readFileSync(HTM, "utf8");
const m = raw.match(/<script>([\s\S]*?)<\/script>/);
if (!m) { console.error("找不到 <script> 段"); process.exit(1); }
let js = m[1];
js = js.replace(/<%=\s*url\('([^']+)'\)\s*%>/g, "/cgi-bin/luci/$1");
if (/<%/.test(js)) { console.error("还有未替换的模板标签"); process.exit(1); }

/* ---------- 2. 测试数据 ---------- */
const CASES = {
  /* 现状：单块 4T 盘 + 内置分区 */
  single: [
    { name:"sda", kind:"disk", parent:"sda", size_h:"3.6T", fstype:"", model:"ATA ST4000VX005-2LY1" },
    { name:"sda1", kind:"part", parent:"sda", size_h:"16.0M", fstype:"" },
    { name:"sda2", kind:"part", parent:"sda", size_h:"3.6T", fstype:"ntfs", mount:"/mnt/sda2",
      mounted:true, uuid:"8CB8C15FB8C14902", used_kb:2684258840, total_kb:3907000316 },
    { name:"mmcblk0p27", kind:"ipart", parent:"mmcblk0", size_h:"111.5G", fstype:"ext4",
      model:"SLD128", uuid:"ec444341-4596-4d00-b0c9-36ca8ca223e4" }
  ],
  /* 盘柜：4 块盘同时插着 */
  multi: [
    { name:"sda", kind:"disk", parent:"sda", size_h:"3.6T", fstype:"", model:"ATA ST4000VX005-2LY1" },
    { name:"sda1", kind:"part", parent:"sda", size_h:"16.0M", fstype:"" },
    { name:"sda2", kind:"part", parent:"sda", size_h:"3.6T", fstype:"ntfs", mount:"/mnt/sda2",
      mounted:true, uuid:"8CB8C15FB8C14902", used_kb:2684258840, total_kb:3907000316 },
    { name:"sdb", kind:"disk", parent:"sdb", size_h:"1.8T", fstype:"", model:"ATA WDC WD20EFRX-68E" },
    { name:"sdb1", kind:"part", parent:"sdb", size_h:"1.8T", fstype:"ext4", uuid:"3f2a1b0c-1111-2222-3333-444455556666" },
    { name:"sdc", kind:"disk", parent:"sdc", size_h:"931.5G", fstype:"", model:"ATA ST1000DM003-1CH1" },
    { name:"sdc1", kind:"part", parent:"sdc", size_h:"931.5G", fstype:"ntfs", mount:"/mnt/sdc1",
      mounted:true, uuid:"A1B2C3D4E5F60718", used_kb:120000000, total_kb:976762584 },
    { name:"sdd", kind:"disk", parent:"sdd", size_h:"7.3T", fstype:"exfat", mount:"/mnt/sdd",
      mounted:true, used_kb:500000000, total_kb:8000000000 },   /* 无分区表的小/大 U 盘式整盘 */
    { name:"mmcblk0p27", kind:"ipart", parent:"mmcblk0", size_h:"111.5G", fstype:"ext4",
      model:"SLD128", uuid:"ec444341-4596-4d00-b0c9-36ca8ca223e4" }
  ],
  /* 硬件 RAID 柜：柜子合成 1 个逻辑盘 */
  raid: [
    { name:"sda", kind:"disk", parent:"sda", size_h:"3.6T", fstype:"", model:"ATA ST4000VX005-2LY1" },
    { name:"sda1", kind:"part", parent:"sda", size_h:"16.0M", fstype:"" },
    { name:"sda2", kind:"part", parent:"sda", size_h:"3.6T", fstype:"ntfs", mount:"/mnt/sda2",
      mounted:true, uuid:"8CB8C15FB8C14902", used_kb:2684258840, total_kb:3907000316 },
    { name:"sdb", kind:"disk", parent:"sdb", size_h:"10.9T", fstype:"", model:"RAID5_VOLUME" },
    { name:"sdb1", kind:"part", parent:"sdb", size_h:"10.9T", fstype:"ext4", mount:"/mnt/sdb1",
      mounted:true, uuid:"99887766-5544-3322-1100-aabbccddeeff", used_kb:1000000, total_kb:11700000000 },
    { name:"mmcblk0p27", kind:"ipart", parent:"mmcblk0", size_h:"111.5G", fstype:"ext4", model:"SLD128" }
  ]
};
const devs = CASES[CASE];

const PAYLOAD = {
  devs: devs,
  tools: { ntfs3:true, exfat:true, vfat:true, mkfs_exfat:true, mkfs_vfat:true, mkfs_ext4:true,
           mkfs_ntfs:false, ntfsfix:false, fsck_exfat:true, fsck_vfat:true },
  openlist: { running:true, pid:"19629" },
  kernel: "6.12.93", log_file:"/tmp/diskctl.log",
  internal_devs: "mmcblk0p27 ", internal_mount: "/mnt/emmc",
  storages: { ok:true, err:"", storage:[
    { id:1, mount_path:"/THW-4T", driver:"Local", status:"work", disabled:false, root:"/mnt/sda2" }
  ]}
};

/* ---------- 3. DOM / XHR 桩 ---------- */
const ELS = {};
function El(id) {
  this.id = id; this.innerHTML = ""; this.textContent = ""; this.value = "";
  this.style = {}; this.children = []; this.className = ""; this.checked = false;
  this.scrollTop = 0; this.scrollHeight = 0; this.lastElementChild = null;
  const noop = function () {};
  this.classList = { add:noop, remove:noop, toggle:noop, contains:function(){return false;} };
  this.appendChild = function (c) { this.children.push(c); };
  this.removeChild = function () {};
  this.getAttribute = function () { return null; };
  this.querySelector = function () { return null; };
  this.setAttribute = noop;
}
const docHandlers = {};
global.document = {
  readyState: "complete",
  getElementById: function (id) { return ELS[id] || (ELS[id] = new El(id)); },
  createElement: function (tag) { return new El(tag); },
  addEventListener: function (ev, fn) { (docHandlers[ev] = docHandlers[ev] || []).push(fn); },
  querySelector: function () { return null; }
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

/* ---------- 4. 跑起来 ---------- */
eval(js);

/* ---------- 5. 输出 ---------- */
const dump = {};
Object.keys(ELS).forEach(function (k) {
  if (ELS[k].innerHTML) { dump[k] = ELS[k].innerHTML; }
});

function textOf(html) {
  return String(html || "")
    .replace(/<div class="oa-bar">[\s\S]*?<\/div>/g, "")
    .replace(/<[^>]+>/g, " ")
    .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&#8943;/g, "…")
    .replace(/[ \t]+/g, " ").trim();
}

console.log("### 用例: " + CASE + "  (共 " + devs.length + " 条设备记录)\n");

console.log("===== 顶部状态条 oa-strip =====");
console.log(textOf(dump["oa-strip"]));

console.log("\n===== USB 硬盘面板 oa-devs =====");
console.log(textOf(dump["oa-devs"]).replace(/\s*\/dev\//g, "\n/dev/"));

console.log("\n===== 内置存储面板 oa-int-devs =====");
console.log(textOf(dump["oa-int-devs"]).replace(/\s*\/dev\//g, "\n/dev/"));

console.log("\n===== 批量操作面板 oa-batch-list =====");
console.log(textOf(dump["oa-batch-list"]).replace(/\s*已挂载/g, " [已挂载]"));
console.log("汇总文字: " + (ELS["oa-batch-sum"] || {}).textContent);
console.log("OpenList 面板副标题: " + (ELS["oa-ol-sub"] || {}).textContent);

/* ---- 断言 ---- */
const devsHtml = dump["oa-devs"] || "";
const cards = (devsHtml.match(/class="oa-disk"/g) || []).length;
const rows = (devsHtml.match(/class="oa-row"/g) || []).length;
const heads = (devsHtml.match(/class="oa-disk-hd"/g) || []).length;
const swOn = (devsHtml.match(/class="oa-sw on"/g) || []).length;
const swOff = (devsHtml.match(/class="oa-sw" data-act="mount"/g) || []).length;
const swDis = (devsHtml.match(/class="oa-sw" disabled/g) || []).length;
const eject = (devsHtml.match(/data-act="eject"/g) || []).length;
const forms = (devsHtml.match(/<form/g) || []).length;
const untyped = (devsHtml.match(/<button(?![^>]*type=)/g) || []).length;

console.log("\n===== 断言 =====");
console.log("USB 卡片数 (期望 " + (CASE === "single" ? 1 : CASE === "multi" ? 4 : 2) + "): " + cards);
console.log("整盘标题数: " + heads);
console.log("分区行数: " + rows);
console.log("开关 已挂载(on)=%d  未挂载= %d  无文件系统(禁用)=%d", swOn, swOff, swDis);
console.log("安全弹出按钮数 (每块 USB 整盘 1 个): " + eject);
console.log("<form> 数 (必须 0): " + forms);
console.log("未显式写 type 的 button (必须 0): " + untyped);

const okAll = cards === (CASE === "single" ? 1 : CASE === "multi" ? 4 : 2)
  && forms === 0 && untyped === 0 && eject === cards;
console.log("\n>>> " + (okAll ? "全部通过 ✅" : "有断言失败 ❌"));
process.exit(okAll ? 0 : 1);
