# Daily Data Cap（流量日帽）

按日限流的 **Magisk 模块**：每天移动数据用量达到阈值后自动断网，必须人工确认才能解除，次日 0 点自动恢复。为「日包 1GB、超出部分 50 元/GB」这类套餐设计。

## 功能特性

- **系统级拦截**：`svc data disable` 拆除数据通道 + iptables/ip6tables 对当前数据接口 REJECT 双保险；从快捷栏重开数据也拦得住，只能进 WebUI 解除
- **动态跟踪数据接口**：`rmnet_dataX` / `vt_data0XX` 接口重编号自动适配（inotifyd 监听 `/sys/class/net`），不误伤 IMS/VoLTE（通话短信正常）
- **WebUI 面板**：本机 `http://127.0.0.1:8899`，用量进度条、解除按钮（可软解除/当日放开）、阈值与重置时刻设置；浏览器「添加到主屏幕」即可当 app 用
- **root 原生守护进程**：活在 Android 进程管理之外，无保活问题；重启后自动恢复状态
- **0 点自动恢复**：删规则、重开数据、计数清零，并发系统通知（`cmd notification post`，已实测可用）
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

## 开发

```bash
./scripts/deploy.sh      # adb 直推 module/ 到手机并重启守护（日常迭代）
./scripts/pack.sh 0.1.0  # 本地打包 zip（需要 zip 命令，CI 在 Linux 上执行）
git tag v0.1.0 && git push --tags   # 触发 Actions：自动构建 zip + Release + 更新 update.json
```

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
