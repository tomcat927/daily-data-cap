#!/system/bin/sh
# 手机端安装脚本: 由 deploy.sh 推送后以 root 执行
set -e
DIR="/data/adb/modules/daily_data_cap"
STAGE="/data/local/tmp/dailycap_stage"

mkdir -p "$DIR"
cp -a "$STAGE/mod/." "$DIR/"
rm -rf "$STAGE"

# 清洗 Windows 换行符, 修正权限
find "$DIR" -type f -exec sed -i 's/\r$//' {} +
find "$DIR" -type d -exec chmod 755 {} +
find "$DIR" -type f -exec chmod 644 {} +
chmod 755 "$DIR/service.sh" "$DIR/uninstall.sh"
chmod 755 "$DIR/bin/"*.sh "$DIR/web/cgi-bin/"* 2>/dev/null || true

# 开发构建版本号
sed -i "s/{{VERSION}}/dev-$(date +%m%d%H%M)/; s/{{VCODE}}/$(date +%s)/" "$DIR/module.prop"

sh "$DIR/bin/dailycap.sh" restart || true
echo ">> 部署完成"
