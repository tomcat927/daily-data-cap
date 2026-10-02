#!/system/bin/sh
# Magisk 默认安装器解压时不保留 zip 执行位(一律 644), 而 busybox httpd 要求 CGI 可执行,
# 因此每次刷入后在此统一修正脚本权限
ui_print "- 修正脚本执行权限"
chmod 755 "$MODPATH/service.sh" "$MODPATH/uninstall.sh" 2>/dev/null
chmod 755 "$MODPATH/bin/"*.sh 2>/dev/null
chmod 755 "$MODPATH/web/cgi-bin/"* 2>/dev/null
