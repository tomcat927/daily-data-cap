#!/usr/bin/env bash
# 开发迭代：把 module/ 直推到手机并重启守护，无需打包 zip
# 用法: DEVICE=<serial> ./scripts/deploy.sh   (多设备时必须指定 DEVICE)
set -euo pipefail

MODULE_ID="daily_data_cap"
STAGE="/data/local/tmp/dailycap_stage"
DIR="/data/adb/modules/${MODULE_ID}"

# Git Bash 会把 /data/... 自动改写成 Git 安装路径，必须禁用
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"

ADB="adb"
[ -n "${DEVICE:-}" ] && ADB="adb -s ${DEVICE}"
$ADB wait-for-device

echo ">> 推送模块文件与安装脚本"
$ADB shell "rm -rf ${STAGE} && mkdir -p ${STAGE}"
$ADB push module "${STAGE}/mod"
$ADB push scripts/remote-install.sh "${STAGE}/install.sh"

echo ">> root 安装到 ${DIR}"
$ADB shell "su -c 'sh ${STAGE}/install.sh'"

echo ">> 当前状态："
$ADB shell "su -c 'sh ${DIR}/bin/dailycap.sh status'" || true
echo ">> 最近日志："
$ADB shell "su -c 'tail -n 10 /data/adb/daily_data_cap/engine.log'" 2>/dev/null || echo "(暂无日志)"
