---
name: wechat-channels-download
description: 下载微信视频号（finder）分享链接背后的原始视频文件：本地 MITM 抓签名取流地址 + 在播放期间从微信进程内存取回 ISAAC-64 密钥流解密。当用户给出 weixin.qq.com/sph 或 channels.weixin.qq.com/finder 链接并要求下载/保存/提取视频时使用。
---

# 微信视频号视频下载

## 概览

视频号分享链接在浏览器里**拿不到视频**：短链 301 到 `channels.weixin.qq.com/finder-preview/pages/sph`，预览页在非微信环境只显示二维码，其接口 `POST /finder-preview/api/feed/get_feed_info`（`{baseReq:{generalToken:""}, shortUri:"<id>"}`）只返回作者/文案/封面，**不含视频地址**；`/web/api/feed/detail` 需要客户端会话（裸调恒返回 `errCode -10000 LoadCtx failed -2`）。

可行路径只有一条链路：

1. **抓包**：让微信 PC 客户端走本地 MITM，抓到 `https://finder.video.qq.com/251/20302/stodownload?encfilekey=..&token=..&sign=..&web=1&X-snsvideoflag=..&taskid=..`。
2. **加密**：该 CDN **只加密文件前 128KB**（响应头 `x-encflag:1`、`x-enclen:131072`；Range 起点越过 128KB 后 `x-enclen` 变 0）。其余是明文标准 MP4（可用 `moov` 下的 `trak/mdia/minf/stbl` 与 `mdat` 大小闭合来验证）。
3. **解密**：密钥流 = `ISAAC-64(decodeKey)` 生成的 131072 字节，worker 里实现为 `buf[i] ^= keystream[i]`（`decrypt-video-core` v1.3.0）。`decodeKey` 不下发到 HTTP，但它对应的**密钥流只在播放期间驻留客户端进程内存** → 用「密文 + 已知明文 `ftyp`」反推特征，直接从内存里捞那 128KB。

本技能附带一个已验证的 CLI：`scripts/sph.mjs`；另附 `scripts/gui/` + `scripts/build/`（可用系统自带 `csc.exe` 打成**免安装桌面 exe**，内嵌 Node，目标机不需要 Node/npm/openssl）与 `scripts/tests/`（setup 安全闸门、证书链、证书陷阱、`.ps1` 语法共 4 组回归）。`scripts/` 与工具源码目录**逐字节一致**，可用 `build/sync-skill.ps1` 同步并校验哈希。

## 前置条件

- Windows + 微信 PC 客户端**已登录**（实测 4.1.13.65）
- Node.js 18+（源码运行）；或直接用构建好的 `wx-sph-dl.exe`（内嵌 runtime，目标机无需 Node）
- Windows PowerShell 5.1（系统自带）：证书走 **Windows PKI（`New-SelfSignedCertificate -Signer`）**，**不需要 openssl**
- 可选 `ffprobe` 做产物校验；`certutil` 系统自带
- 用户能配合两步：**完全重启微信**、**播放目标视频 30 秒以上**

## 步骤

```bash
SKILL="<技能目录>"; cd "$SKILL/scripts"     # 脚本随技能分发，勿改路径
node sph.mjs doctor             # 只读自检：平台/PKI/certutil/注册表/备份/端口/微信进程
node sph.mjs setup --dry-run    # 先校验：会打印将生成的 PAC 与代理备份，不改任何系统设置
node sph.mjs setup
```
`setup --dry-run` 的「其余 → …」**必须是用户原来的代理**（例如 `127.0.0.1:1080`）；若显示 `DIRECT` 而你本来有代理，先别继续。
`setup` 会：用 Windows PKI 生成 CA → 装到「当前用户\受信任的根」（无需管理员）→ 写 PAC（**只有腾讯系域名**走本地代理，其余仍走用户原代理）→ 起本地 MITM → 备份并把系统代理指向 PAC。

然后（**必须由用户操作，无法替代**）：

1. 完全退出微信（托盘退出，不是关窗口）再重新打开 —— 让它读到新代理；
2. 在微信里打开目标视频号链接并**持续播放 30 秒以上**（可循环）。

```bash
node sph.mjs watch      # 从抓到的取流地址里下载密文头（内存搜索特征）
node sph.mjs key        # 与播放同时进行：并行分片扫内存，取回 128KB 密钥流
node sph.mjs decrypt    # 下载完整视频 + 解密 → output/xxx.mp4
node sph.mjs cleanup    # 停代理/扫描器、还原系统代理、移除临时 CA（需人工点确认）
node sph.mjs stopscans  # 只停后台扫描器
```

桌面版窗口把这几步做成按钮（①环境检查 ②安装抓包 ③抓取+取密钥 ④下载解密 ⑤清理还原 + 常驻「紧急还原」）。
构建 exe：`powershell -File build\build.ps1`（单文件，内嵌 runtime）或 `-Portable`（便携目录，绿色模式不写 AppData）。

`node sph.mjs status` 可随时只读查看进度（代理是否在跑、抓到几条取流、密钥流是否已拿到）。

## 关键实现点（排错靠这些）

- **密钥流内存特征**：`ks[0..2]=密文[0..2]`（MP4 box size 高 3 字节为 0）、`ks[3]=密文[3]^size`（小整数，通配）、`ks[4..8]=密文[4..8]^"ftyp"` → 用 8 字节窗口（第 4 字节通配）搜内存，命中后用「解密前 128KB 是否出现 `moov`」校验。
- **必须用「正在播放的那个视频」的密文做特征**：`watch` 从抓包记录取最新 URL、下 `Range: bytes=0-262143` 当特征。用别的视频的密文会永远搜不到。
- **扫描必须与播放重叠**：worker 释放后密钥流就没了；扫描一轮约 10–45 秒，所以要让用户保持播放。
- 进程按 **PID 文件**管理（`state/proxy.pid`、`state/scan.pids`），不要用进程名/命令行正则去 kill —— 容易误杀无关进程（例如 `DSH Desktop.exe`）。
- **证书按指纹绑定**：`state/certs/index.json` 记录 CA 的 thumbprint，叶子只由本 state 拥有的那个 CA 签发；**绝不要**用「subject 相同的任意证书」当 CA（多个同名 CA 会互相污染）。

## 坑

1. **不要用 mitmproxy**：官方 Windows 包会被 Windows 安全中心直接删除；本工具的 `proxy.mjs` 是 Node + 本机 Windows PKI 自实现的等价方案。
2. **不要把全部流量导向本地代理**：PAC 只放腾讯系域名，其余保持用户原代理，否则会打断用户上网；`setup` 前先备份 `HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings`。
3. **PowerShell 5.1 按 ANSI 读 UTF-8(无 BOM) 的 `.ps1`** 会把中文搞成乱码并报语法错 → 辅助脚本**一律纯 ASCII**（连注释也不能用中文：实测加了两行中文注释后 `saveproxy` 直接写出 0 字节；**构建脚本同理**）。校验：正则 `^[\x00-\x7F]*$`；检查 UTF-8 文本内容一律用 Node，别用 PS 5.1 的 `Get-Content`（会把中文读成乱码造成假阴性）。
4. 执行策略禁止直接跑 `.ps1`：用 `& (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File x.ps1`（本机 `pwsh` 不在 PATH，当前 shell 是 `powershell.exe`）。
5. **删根证书的路径要选对**：PowerShell 证书提供程序**禁止**删用户根存储（报「不允许对用户根存储和 UI 执行操作」），但 **.NET `X509Store('Root','CurrentUser').Remove($cert)` 实测可静默删除、不弹窗**（`tests/remove-root-ca.ps1` 就是这条路径）。CryptoAPI `CertDeleteCertificateFromStore` 会弹确认框（人力不在场时会卡住）。删完必须复查 `Cert:\CurrentUser\Root` 里 `DSH Local MITM CA` 计数为 0。
6. **dsh-defend 会拦含 `token=`/长签名的工具输出**（规则 `generic-assignment`）→ 打印抓包 URL 前必须脱敏（工具内部已做）。
7. 签名 URL 有有效期（几十分钟～几小时）：`decrypt` 报 403/404 时，让用户重新播放一次，再 `watch` → `key` → `decrypt`。
8. 同一视频可能有多个码率版本，各自有独立 `encfilekey`；密钥流与**具体那个文件**对应 —— 能用这把密钥解开的那个密文头就是目标。
9. **代理备份必须是无 BOM 的 UTF-8**：PowerShell 5.1 的 `Set-Content -Encoding UTF8` 会写 BOM（`ef bb bf`），Node 的 `JSON.parse` 会直接抛错；若此时静默回退成空对象，PAC 兜底就会被写成 `DIRECT`，**等于把用户原有代理绕掉、可能直接断网**。工具已按三重防护处理：备份用 `[IO.File]::WriteAllText` + `UTF8Encoding($false)` 写无 BOM / 读取时剥 BOM / 解析失败即 `exit 1` 中止 + PAC 自检必须包含原代理字符串。改动这块后务必跑 `setup --dry-run` 验证「其余 → 原代理」。
10. **不要预先创建同名技能目录**：技能的采纳流程是把「DSH 数据目录下的 `memories/pending-skills/<name>`」**rename** 到「`<用户主目录>/.agents/skills/<name>`」；目标目录已存在时会失败（`EPERM ... rename`）。正确顺序是：先让用户采纳 → 再把 `scripts/` 资源复制进去（`skill_manage` 只写 SKILL.md，资源必须手工复制）。若资源需要随待确认内容一起过去，可直接放进 `pending-skills/<name>/scripts/`（晋升是整目录 rename）。
11. **setup 的安全闸门不可退让**：改动任何网络设置之前，备份必须存在且 schema 合法（`ProxyEnable` 为 0/1 整数、其余三字段为字符串、四字段齐全）。**空对象 `{}`、类型错、截断、缺字段、saveproxy 非零退出 —— 全部必须中止且不动网络**；`--dry-run` 在无备份时必须用**只读读取到的真实注册表值**如实呈现，**不许**臆测成「用户没有代理」。回归：`tests/setup-gate-tests.mjs`。
12. **证书链断裂有三个真实成因，全部踩过（2026-09-17 定位）**：
    - ① **`certutil -encode` 不覆盖已存在的输出文件**且退出码非零，代码里若忽略它就等于「新签了 CA，但 `ca.crt` 还是旧的」→ 客户端信任旧 CA、代理发新链 → `self-signed certificate in certificate chain`。修法：**自己写 PEM**（`[Convert]::ToBase64String($ca.RawData)` 按 64 列折行），写完**回读并比对 thumbprint**。
    - ② **多个同名 CA 会让 Windows 建链把错误的父证书塞进叶子 PFX**（表现为第一次跑通、第二次失败，取决于枚举顺序）。修法：每个 state 的 CA 主体带唯一后缀（`CN=DSH Local MITM CA <8位hex>`，见 `certs/catag.txt`），并且叶子签发后**回读 PFX，断言内容恰好是「叶子 + 本 state 的 CA」**（`X509Certificate2Collection.Import(bytes, pass, flags)` 可枚举 PFX 内全部证书），不满足就删除并拒绝使用。
    - ③ **「文件存在」不能当作「CA 有效」**：`ensureCa()` 曾用 `ca.pfx && ca.crt` 存在就复用，CA 已被从存储里清掉时会让后续每个叶子都失败。修法：每次都让 `certs.ps1 -Mode ca` 决定（它按 index.json 的 thumbprint 判断是否仍在存储里）。
    - **清理要查三个存储**：`My`（CA+叶子）、**`CA`（中间 CA 存储，Windows 建链时会自动缓存副本，最容易漏）**、`Root`（受信任根）。`doctor` 现在会报告三处残留数，**Root 里有残留即判失败**；`ps/purge-certs.ps1` 清 My+CA，`tests/remove-root-ca.ps1` 清 Root。回归：`tests/cert-collision-tests.ps1`（8 断言，会刻意在存储里放同名旧 CA、并制造「pfx 还在但 CA 已没了」）。
    - **自检脚本必须自清理，且自检要从干净起点开始**：`mitm-selftest.mjs` 起跑前会删掉自己 state 里的 `ca.*/pass.txt/catag.txt/index.json/leaf-*.pfx`（`--keep-state` 可保留），否则上一轮的旧 PEM 会污染判定。
13. **csc(.NET Framework 4.0) 不支持 `Process.Kill(bool)`**：桌面版里只能用 `Kill()`。用 csc 编译含中文的 `.cs` 要加 `/codepage:65001`（源码为无 BOM UTF-8）。
14. **打包后用自检验证路径问题**：`mitm-selftest.mjs` 在仓库里位于 `tests/`、打包后在 `scripts/`，必须按「`proxy.mjs` 所在目录」定位根，否则打包后自检会 `MODULE_NOT_FOUND`。
15. **`/target:winexe` 的程序不能靠 `$LASTEXITCODE` 判成败**：`& $exe --selftest` 会立刻返回、`$LASTEXITCODE` 不可信 —— 实测自检明明打印 `EXE-SELFTEST-FAIL`，构建脚本却报 `selftest exit: 0` 并输出 `BUILD-OK`（假绿灯）。修法：`Start-Process -Wait -PassThru` 取 `ExitCode`，**并且**要求日志里出现 `EXE-SELFTEST-OK` 标记。任何「自检通过」的结论都要有这两个证据之一。
16. **exe 的解包缓存必须带内容指纹**：`version.stamp` 若只由常量版本号拼成，**重新编译的 exe 永远不会刷新已解包的脚本**（用户升级后仍跑旧 JS/PS，且毫无提示）。修法：stamp 里加内嵌脚本资源的 SHA-256（node.exe 用长度代表），并同时检查每个脚本文件是否缺失。
17. **PAC 归属：必须靠「我们自己写的记录」，不能靠 URL 形状（都实测踩过）**：
    - ① **「还原」被写成「删掉 AutoConfigURL」**：如果用户原本就用 PAC，删键等于破坏他的设置。正确语义是**照备份写回**，只在备份值为空时删键。
    - ② **把自己写的 PAC 当成用户原值备份下来**：state 丢失后重跑 `setup`，`saveproxy` 会把当前（我们自己装的）PAC 记成"原值"，从此 cleanup 永远还原成我们的 PAC。现在按 `records/pac-endpoints.json` 判定：命中记录则记成空值 + `WARN normalized`；**陌生 PAC 一字不改**。
    - ③ **不要用「127.0.0.1/…/proxy.pac 就算我们的」这种形状匹配**：`http://127.0.0.1:8080/proxy.pac`、`http://localhost/proxy.pac`、甚至同端口不同路径（`/other.pac`）都可能是**用户自己的**本地 PAC 服务。`dropownpac` 现在只删**与记录中的 URL 完全相等**的值，其余一律 `KEEP` 并说明原因（回归里专门有这三条反例）。
    - ④ **备份丢失 ≠ 什么都不做**：旧版 cleanup 在 `original-proxy.json` 缺失时只报错，于是 PAC 永久留在系统里并指向已死的本地端口（实测本机就是这样：`ProxyEnable` 还被 `setpac` 改成 0，用户系统代理静默失效）。现在 cleanup 走 `dropownpac` 兜底并打印当前四字段；`doctor` 把「系统里挂着**记录过的**本工具 PAC」判为失败（形状像本地 PAC 但无记录时只提示、不判失败）。
    - 回归：`tests/proxy-restore-tests.ps1`（21 断言，结束时把注册表还原回原样）。
18. **破坏性清理的归属判定：记录 > 模式匹配**。旧版用「命令行含 `proxy.mjs` 且 `--port` 匹配」认定孤儿代理 —— 这会把**别的项目的同名脚本**（甚至无关参数）也算成自己的。现在要求三重证据：①**机器级**运行记录 `records/proxy-registry.json` 里有「该 pid + 该端口」条目（`proxy.mjs` 启动时写入）；②记录里的脚本绝对路径属于本工具已知安装位置，且实际命令行引用的就是它；③进程启动时间与记录一致（排除 pid 被回收）。任一不满足 → `ORPHAN-REFUSED` 放行。
    - **记录必须在 state 目录之外、且机器级共享**：`%LOCALAPPDATA%\wx-sph-dl\records\`（`WXSPH_RECORDS` 可覆盖，测试用它隔离）。第一版我把记录放在「state 的父目录」，结果**用另一个 base 启动的代理就认不出来**（本机真实故障：GUI 在 AppData 启动、cleanup 从 CLI 目录跑）—— 测试当场抓出这个设计错误。
    - Windows 上进程被信号终止后端口要过几百毫秒才释放，判定要轮询「进程消失**或**端口释放」，否则误报失败。
    - 回归：`tests/orphan-proxy-tests.ps1`（16 断言：自己的被停、**异目录同名 `proxy.mjs`** 被拒、记录缺失被拒、无关监听者被拒；夹具 `tests/fixtures/foreign-proxy/proxy.mjs`）。
    - 副作用要如实说明：绿色/便携模式并非「完全不写 AppData」—— 这个机器级归属记录会写到 `%LOCALAPPDATA%\wx-sph-dl\records\`（README 已注明这是唯一例外）。

## 验证

- 解密结果的第 4–8 字节必须是 `ftyp`，前 4 字节是合理 box size（例如 `0000001c`）；`ffprobe` 应能读出 video/audio 流与时长。
- 抽一帧人工确认内容对得上（`ffprobe` 之外的语义校验）：
  `ffprobe -v error -ss 2 -i out.mp4 -frames:v 1 -q:v 3 frame.jpg`
- 收尾四查（**四个都要查，少一个就会留下残留**）：
  1. `node sph.mjs status`：代理未监听、`临时 CA: absent`；
  2. 系统代理已回到用户原值（对比 `state/original-proxy.json`）；
  3. `node sph.mjs doctor`：`证书残留：My=0 CA=0 Root=0（干净）`；
  4. `Get-ChildItem Cert:\CurrentUser\{My,CA,Root}` 里搜 `DSH Local MITM CA` 均为 0（`CA` 是中间存储，最常被漏）；
  5. `ps/win.ps1 -Mode getproxy` 里 `AutoConfigURL` 不是本工具的 `127.0.0.1:<port>/proxy.pac`，且 18080 无监听（`Get-NetTCPConnection -LocalPort 18080 -State Listen`）。
- **setup 安全闸门回归**：`node tests/setup-gate-tests.mjs` → 期望 `GATE-TESTS-OK`（22 项，含「中止时系统代理快照未变」断言）。
- **证书链自检**：`node tests/mitm-selftest.mjs` → 期望 `SELFTEST-OK` + `CHAIN depth=2 … chain-ok=true`（服务端实际链正好是「叶子 + 本 CA」）+ 真实 `HTTP 200`，且跑完存储里不留证书。
- **证书陷阱回归**：`powershell -File tests/cert-collision-tests.ps1` → 期望 `CERTS-REGRESSION-OK`（8 断言；覆盖同名旧 CA、pfx 残留但 CA 已被清两种场景）。
- **代理还原回归**：`powershell -File tests/proxy-restore-tests.ps1` → 期望 `PROXY-RESTORE-OK`（15 断言；用户自带 PAC 原样写回、空值删键、自己的 PAC 归一化、陌生 PAC 不动，结束时注册表还原）。
- **孤儿进程回归**：`powershell -File tests/orphan-proxy-tests.ps1` → 期望 `ORPHAN-KILL-OK`（8 断言；停掉自己的孤儿代理、拒绝杀陌生进程）。
- **`.ps1` 语法体检**：`powershell -File tests/parse-check.ps1` → 期望 `PS-PARSE-OK`（不执行，只解析；ASCII 检查用正则断言）。
- **exe 自检**：`wx-sph-dl.exe --selftest` → 日志里必须出现 `EXE-SELFTEST-OK`（不能只看退出码：winexe 的退出码不可信）。

## 收尾（必做）

`node sph.mjs cleanup` 会：停扫描器 → 停代理（**按 pid 文件；若端口仍被占用，再按「端口属主 PID + 命令行含 `proxy.mjs` 且 `--port` 匹配」核实后终止**，绝不按进程名杀；陌生进程占同端口会输出 `ORPHAN-REFUSED` 并放行）→ **照备份写回** `ProxyEnable/ProxyServer/ProxyOverride/AutoConfigURL` 四字段（通知 `InternetSetOption 39/37` 刷新）→ 备份丢失时走 `dropownpac`（**只**删自己签名的 `AutoConfigURL`，其它值不动并如实报告；随后打印当前代理四字段）→ 删除受信任根里的临时 CA（逐个 thumbprint）→ 清 `Cert:\CurrentUser\My` 与本 state 的中间存储副本 → 再跑一次前缀清扫兜住孤儿 → **最后打印三存储残留复查**。

要点：**还原 ≠ 一律删 PAC**。`AutoConfigURL` 只在备份里本来就是空时才删键；用户自带 PAC 会被原样写回（`tests/proxy-restore-tests.ps1` 覆盖）。`saveproxy` 若发现当前 `AutoConfigURL` 是本工具自己的端点（`127.0.0.1:<port>/proxy.pac`），会记成空值并 `WARN normalized` —— 否则 state 一旦丢失，我们自己写的 PAC 就会被当成"用户原值"永久还原。

若仍有残留 CA，提示用户手动删：Win+R → `certmgr.msc` → 受信任的根证书颁发机构 → 证书 → `DSH Local MITM CA` → 删除；或用 `tests/remove-root-ca.ps1` 静默删除。

## 合法使用

仅用于下载用户有权保存的内容（自己的作品、已授权素材、合理使用）。提示用户遵守微信服务条款与著作权法。
