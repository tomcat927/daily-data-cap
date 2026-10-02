# Daily Data Cap（流量日帽）

按日限流的 **Magisk 模块**：每天移动数据用量达到阈值后自动断网，必须人工确认才能解除，次日 0 点自动恢复。为「日包 1GB、超出部分 50 元/GB」这类套餐设计。

## 功能特性

- **系统级拦截**：`svc data disable` 拆除数据通道 + iptables/ip6tables 对当前数据接口 REJECT 双保险；从快捷栏重开数据也拦得住，只能进 WebUI 解除
- **动态跟踪数据接口**：`rmnet_dataX` / `vt_data0XX` 接口重编号自动适配（inotifyd 监听 `/sys/class/net`），不误伤 IMS/VoLTE（通话短信正常）
- **WebUI 面板**：本机 `http://127.0.0.1:8899`，用量进度条、解除按钮（可软解除/当日放开）、阈值与重置时刻设置；浏览器「添加到主屏幕」即可当 app 用
- **root 原生守护进程**：活在 Android 进程管理之外，无保活问题；重启后自动恢复状态
- **0 点自动恢复**：删规则、重开数据、计数清零，并发系统通知（`cmd notification post`，已实测可用）
- **营业厅校对（可选）**：基于第三方监控站 flow.mxzu.net 的查询接口（手机号+密码哈希，无抓包、凭证不过期），把联通侧真实用量与本地计数对账。**只上修不下修**——营业厅比本地高 50MB 以上才补计（说明本地漏计），绝不拿滞后数字往下修导致晚断网；偏差超 800MB 视为运营商滞后旧数据不校；连续失败 3 次自动停用；0 点后隔一个周期才查，避开运营商重置延迟。默认每小时一次（约 70KB/天），也可在面板手动"立即对账"
- **每日统计与看板（本地）**：断网/解除/重拦/翻转事件写入 `events.log`；每天 0 点把当日最终用量、营业厅读数、偏差、触发次数归档到 `daily.csv`（滚动保留约 40 天）；面板"📊 近30天统计"折叠区以柱状图展示（红柱=当天触发过断网）并列出最近事件。纯本地记录，零流量开销，不参与断网决策
- **计数口径**：当前上网接口字节增量累加并持久化，方向偏保守（宁多勿少）；IMS 独立接口天然排除

## 已验证设备

Redmi 9T (chime) · LineageOS 19 (Android 12) · Magisk 27.0 · 中国联通单卡（日包 0 点重置）。
断网手段、接口动态性、通知、busybox httpd/inotifyd 均已在真机实测通过。其他高通 4G 机型理论通用。

## 安装

1. Magisk 管理器 → 模块 → 从存储安装 → 选择 Release 里的 `daily-data-cap.zip`
2. 或者在 Magisk 管理器里通过模块的更新通道（updateJson）直接升级到最新版

安装后重启，通知栏出现常驻状态即守护已运行。

## 使用

**打开面板：手机浏览器访问 `http://127.0.0.1:8899`**

- 首次打开输入访问码 **1234**（默认值，输入一次浏览器就记住）；可在面板里点"修改访问码"换成自己的
- 面板只监听本机 127.0.0.1，外网/局域网无法访问；访问码只是防手机内其他应用误触"解除"的轻量门槛

**建议立刻用 Chrome 菜单 →「添加到主屏幕」**，和 app 无异。

- 面板显示今日用量进度、当前状态，并提供解除按钮（当日放开 / 到硬顶再断 / 30 分钟后再断）、阈值修改
- 访问码存于 `/data/adb/modules/daily_data_cap/data/config`（`WEBUI_TOKEN`）

## 开发与发版

```bash
./scripts/deploy.sh      # adb 直推 module/ 到手机并重启守护（日常迭代）
./scripts/pack.sh 0.1.0  # 本地打包 zip（需要 zip 命令；Windows 可跳过，用 CI）
```

**构建产物 / 发版（无需本地环境，agent 可直接执行）：**

```bash
git tag v0.x.y && git push origin v0.x.y   # 就这一步
```

- 推送 tag 后 GitHub Actions 自动完成：打 zip + 生成 update.json → 挂到 Release，约 15 秒
- 版本号规则：**v 前缀由 CI 统一添加**，`module.prop` 模板里是 `version={{VERSION}}`，不要手工改版本号
- 改过 workflow 或脚本后必须先推 main 再打 tag（CI 使用 tag 指向提交里的流水线定义）
- 验证产物：

```bash
gh release view v0.x.y --json assets --jq '.assets[].name'   # 应列出 zip + update.json
gh release download v0.x.y --pattern "daily-data-cap.zip"    # 下载后可用 python zipfile 检查 module.prop 版本
```

- 手机端实测刷入（不影响 data/ 里的凭证与统计）：

```bash
adb push daily-data-cap.zip /data/local/tmp/ddc.zip
adb shell "su -c 'magisk --install-module /data/local/tmp/ddc.zip'"
```

- 更新通道：`module.prop` 的 updateJson 指向 `releases/latest/download/update.json`，Magisk 管理器据此提示升级，发新版即自动生效
- 历史教训：zip 无 META-INF 也能刷（Magisk 27 内置安装器接管）；Magisk 解压**不保留** zip 执行位（一律 644），CGI 权限靠 `customize.sh` 刷入时补——改权限逻辑不要动 zip，改 customize.sh；模板与 CI 双方都加 v 会产生 `vv0.1.0` 这类版本号

目录结构：

```
module/                       # 模块本体（打包进 zip 的内容，根目录即 zip 根）
├── module.prop
├── service.sh                # 开机启动守护
├── uninstall.sh              # 卸载清理（删规则、恢复数据）
├── bin/dailycap.sh           # 引擎：状态机 + 计数 + 拦截执行
└── web/                      # busybox httpd 站点（状态页 + CGI 按钮入口）
scripts/                      # 部署/打包脚本（PC 侧）
.github/workflows/            # 打 tag 自动发版
```

## 免责声明

需要 root。流量统计与运营商计费存在口径差异，默认阈值 900MB 已留 100MB 余量；请在头两天对照运营商 App 校准。软件按"现状"提供，超额费用风险自负。
