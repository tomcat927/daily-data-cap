#!/system/bin/sh
# Magisk 开机入口: 等 boot 完成后启动守护
MODDIR=${0%/*}
(
  N=0
  until [ "$(getprop sys.boot_completed)" = "1" ] || [ "$N" -ge 30 ]; do
    sleep 2; N=$((N+1))
  done
  sleep 10
  sh "$MODDIR/bin/dailycap.sh" start >/dev/null 2>&1
) &
