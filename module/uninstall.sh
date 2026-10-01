#!/system/bin/sh
# 模块卸载清理: 停进程、删规则、恢复数据
MODDIR=${0%/*}
sh "$MODDIR/bin/dailycap.sh" stop >/dev/null 2>&1
iptables -D OUTPUT -m comment --comment dailycap -j DAILYCAP >/dev/null 2>&1
ip6tables -D OUTPUT -m comment --comment dailycap -j DAILYCAP >/dev/null 2>&1
iptables -F DAILYCAP >/dev/null 2>&1; iptables -X DAILYCAP >/dev/null 2>&1
ip6tables -F DAILYCAP >/dev/null 2>&1; ip6tables -X DAILYCAP >/dev/null 2>&1
svc data enable >/dev/null 2>&1
