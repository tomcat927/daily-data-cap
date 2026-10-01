#!/usr/bin/env bash
# 本地打包 Magisk 模块 zip（需要 zip 命令；发布构建由 CI 在 Linux 上执行）
# 用法: ./scripts/pack.sh [版本号] [versionCode]
set -euo pipefail

VERSION="${1:-dev}"
VCODE="${2:-$(date +%s)}"
STAGE="$(mktemp -d)"

cp -r module/. "${STAGE}/"
sed -i "s/{{VERSION}}/v${VERSION}/; s/{{VCODE}}/${VCODE}/" "${STAGE}/module.prop"

mkdir -p dist
(cd "${STAGE}" && zip -qr "$OLDPWD/dist/daily-data-cap.zip" .)
rm -rf "${STAGE}"

echo ">> dist/daily-data-cap.zip 已生成 (version=v${VERSION}, versionCode=${VCODE})"
