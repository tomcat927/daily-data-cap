#!/usr/bin/env bash
# 开发迭代：把 module/ 直推到手机并重启守护，无需打包 zip
set -euo pipefail

MODULE_ID="daily_data_cap"
STAGE="/data/local/tmp/dailycap_stage"
DIR="/data/adb/modules/${MODULE_ID}"

adb wait-for-device

echo ">> 推送模块文件到手机临时目录"
adb shell "rm -rf ${STAGE} && mkdir -p ${STAGE}"
adb push module/. "${STAGE}/"

echo ">> root 复制到 /data/adb/modules 并设置权限"
adb shell su -c "
  set -e
  mkdir -p ${DIR}
  cp -a ${STAGE}/. ${DIR}/
  rm -rf ${STAGE}
  sed -i \"s/{{VERSION}}/dev-\$(date +%m%d%H%M)/; s/{{VCODE}}/\$(date +%s)/\" ${DIR}/module.prop
  find ${DIR} -type d -exec chmod 755 {} +
  find ${DIR} -type f -exec chmod 644 {} +
  chmod 755 ${DIR}/service.sh ${DIR}/uninstall.sh ${DIR}/bin/*.sh
  sh ${DIR}/bin/dailycap.sh restart || true
  echo '>> 部署完成'
"

echo ">> 最近日志："
adb shell su -c "tail -n 20 /data/adb/modules/${MODULE_ID}/data/engine.log 2>/dev/null || echo '(暂无日志)'"
