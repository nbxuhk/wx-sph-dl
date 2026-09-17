# 更新日志

## v1.1.0（首个公开发布）

**功能**

- 抓取微信视频号分享链接背后的原始视频文件（非录屏、非转码）：本地 MITM 抓签名取流地址 + 播放期间从微信进程内存取回 ISAAC-64 密钥流解密。
- 两种形态：免安装单文件 exe（内嵌 Node）、便携目录版（绿色模式）；另有 CLI（`sph.mjs`）。
- CLI 子命令：`doctor` / `setup` / `status` / `watch` / `key` / `decrypt` / `cleanup` / `stopscans`。

**安全边界（改动网络前必须成立）**

- `setup` 在写任何系统代理设置前，必须有一份「本次写入且 schema 合法」的代理备份；备份缺失/损坏/类型错/空对象 → 中止且不动网络。
- 还原语义是**照备份写回**四字段（`ProxyEnable/ProxyServer/ProxyOverride/AutoConfigURL`），只有在备份里本来就是空时才删 `AutoConfigURL` 键。
- `saveproxy` 会把自己安装过的 PAC 端点归一化为空（`WARN normalized`），避免 state 丢失后把自己写的 PAC 当成用户原值永久还原。
- 备份丢失时 `cleanup` 只删除**本工具记录过的** PAC 端点（`records/pac-endpoints.json`），其它值一律不动。

**进程/证书卫生**

- 进程一律按 PID 文件管理；孤儿代理的停止需要三重证据：机器级运行记录（pid + 脚本绝对路径 + 端口 + 启动时间）、脚本路径属于本工具已知安装位置、实际命令行与之相符。陌生同名 `proxy.mjs`、无记录的监听者、pid 被回收的情况一律 **refuse**（`ORPHAN-REFUSED`）。
- 每个 state 的 CA 主体带唯一后缀（`CN=DSH Local MITM CA <8hex>`）；叶子 PFX 签发后回读校验「恰好是叶子 + 本 state 的 CA」；`ca.crt` 自己写并回读比对指纹（不用 `certutil -encode`，它不覆盖已存在文件）。
- `cleanup` 清理 `My` / 中间 CA 存储 / 受信任根三处，并复查残留；`doctor` 把「受信任根里有残留 CA」「系统里挂着本工具记录过的 PAC」判为失败。

**构建与验证**

- `build.ps1` 的门禁：只有 exe 自检退出码为 0 **且**日志里出现 `EXE-SELFTEST-OK` 才输出 `BUILD-OK`（`winexe` 的 `$LASTEXITCODE` 不可信）。
- exe 解包缓存带内嵌脚本内容指纹（脚本一变就重新解包；旧版只比常量版本号，升级后仍跑旧脚本）。
- 回归测试 6 组：`setup-gate-tests.mjs`（22 断言）、`mitm-selftest.mjs`（证书链 + 服务端实际链）、`cert-collision-tests.ps1`（8）、`proxy-restore-tests.ps1`（21）、`orphan-proxy-tests.ps1`（16）、`parse-check.ps1`（语法 + ASCII）。

**实测**

- 微信 PC 4.1.13.65 / Windows 11：端到端跑通，产出 1920×1080 HEVC + AAC 原始文件（33.17s / 5.32MB，ffprobe 与抽帧确认）。
