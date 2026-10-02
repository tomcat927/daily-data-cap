#!/system/bin/sh
# 每应用蜂窝用量统计 (引擎归档与 WebUI 共用)
# 用法: appstats.sh [起始epoch]   # 缺省=今日本地 0 点; 系统只保留开机以来的桶
# 输出: 按 MB 降序的 "包名 MB" 行, 末行 "TOTAL 合计MB"
BB="/data/adb/magisk/busybox"
DTMP="/data/adb/daily_data_cap/.appstats"
T0="${1:-}"
H=$(date +%H | sed 's/^0//'); M=$(date +%M | sed 's/^0//'); S=$(date +%S | sed 's/^0//')
[ -n "$T0" ] || T0=$(( $(date +%s) - ${H:-0}*3600 - ${M:-0}*60 - ${S:-0} ))
mkdir -p "$DTMP" 2>/dev/null

pm list packages -U 2>/dev/null | $BB awk -F'[ :]' 'NF>=4{print $4" "$2}' > "$DTMP.pkgs"
/system/bin/dumpsys netstats detail 2>/dev/null | $BB awk -v t0="$T0" '
  /^ *ident=/ {
    mob = ($0 ~ /type=0/)          # 只认蜂窝 ident (type=0), WiFi 天然排除
    uid = -1
    if (match($0, /uid=[0-9]+/)) uid = substr($0, RSTART+4, RLENGTH-4) + 0
  }
  mob && /^ *st=/ {
    n = split($0, f, " ")
    st = 0; rb = 0; tb = 0
    for (i = 1; i <= n; i++) {
      if (f[i] ~ /^st=/)      st = substr(f[i], 4) + 0
      else if (f[i] ~ /^rb=/) rb = substr(f[i], 4) + 0
      else if (f[i] ~ /^tb=/) tb = substr(f[i], 4) + 0
    }
    if (st >= t0) {
      tot += rb + tb
      if (uid >= 10000) sum[uid] += rb + tb
    }
  }
  END {
    for (u in sum) if (sum[u] > 0) printf "U %d %d\n", u, sum[u]
    printf "T %d\n", tot+0
  }
' > "$DTMP.raw"

sort -k3 -rn "$DTMP.raw" 2>/dev/null | $BB awk '
  NR==FNR { m[$1]=$2; next }
  $1=="U" { u=$2; name=(u in m)?m[u]:("uid" u); printf "%s %.1f\n", name, $3/1048576 }
' "$DTMP.pkgs" -
grep '^T ' "$DTMP.raw" 2>/dev/null | $BB awk '{printf "TOTAL %.1f\n", $2/1048576}'
rm -f "$DTMP.pkgs" "$DTMP.raw"
