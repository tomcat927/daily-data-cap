#!/usr/bin/env bash
# 开发迭代：把 module/ 直推到手机并重启守护，无需打包 zip
set -euo pipefail

MODULE_ID="daily_data_cap"
STAGE="/data/local/tmp/dailycap_stage"
DIR="/data/adb/modules/${MODULE_ID}"

# Git Bash 会把 /data/... 自动改写成 Git 安装路径，必须禁用
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"

adb wait-for-device

echo ">> 推送模块文件与安装脚本"
adb shell "rm -rf ${STAGE} && mkdir -p ${STAGE}"
adb push module "${STAGE}/mod"
adb push scripts/remote-install.sh "${STAGE}/install.sh"

echo ">> root 安装到 ${DIR}"
adb shell "su -c 'sh ${STAGE}/install.sh'"

echo ">> 当前状态："
adb shell "su -c 'sh ${DIR}/bin/dailycap.sh status'" || true
echo ">> 最近日志："
adb shell "su -c 'tail -n 10 ${DIR}/data/engine.log'" 2>/dev/null || echo "(暂无日志)"
