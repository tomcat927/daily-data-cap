#!/system/bin/sh
# 每应用蜂窝用量统计 (引擎归档与 WebUI 共用)
# 用法: appstats.sh [起始epoch] [snapshot]
#   缺省: 输出 "包名 MB" 降序行 + 末行 "TOTAL 合计MB" (起始epoch 缺省=今日本地 0 点)
#   snapshot: 额外把 UID 累计快照写入 .appstats.snapshot 并自归档到 appstats/<日>.<boot>.snap
#   系统只保留开机以来的桶; 本脚本不对 defaultNetwork 标志做过滤 (该标志在这台设备上不稳定,
#   曾导致归档全空; type=0 的不同 ident 是不同网络/时段, 无重复计量)
BB="/data/adb/magisk/busybox"
DTMP="/data/adb/daily_data_cap/.appstats"
DROOT="/data/adb/daily_data_cap"

MODE=""; T0=""
for A in "$@"; do
  case "$A" in
    snapshot) MODE="snapshot" ;;
    ''|*[!0-9]*) ;;
    *) T0="$A" ;;
  esac
done
H=$(date +%H | sed 's/^0//'); M=$(date +%M | sed 's/^0//'); S=$(date +%S | sed 's/^0//')
[ -n "$T0" ] || T0=$(( $(date +%s) - ${H:-0}*3600 - ${M:-0}*60 - ${S:-0} ))
mkdir -p "$DTMP" 2>/dev/null

if [ "$MODE" = "snapshot" ]; then
  # UID 当日累计快照: 供跨重启合并 (每个开机周期取最大值)
  SNAP="$DROOT/.appstats.snapshot"
  NOW=$(date +%s)
  BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  /system/bin/dumpsys netstats detail 2>/dev/null | $BB awk -v t0="$T0" '
    /^ *ident=/ { mob=($0~/type=0/); uid=-1; if(match($0,/uid=[0-9]+/))uid=substr($0,RSTART+4,RLENGTH-4)+0 }
    /^ *NetworkStatsHistory:/ { hist=(mob && $0~/bucketDuration=7200/); next }
    hist && /^ *st=/ { n=split($0,f," "); st=0; rb=0; tb=0; for(i=1;i<=n;i++){if(f[i]~/^st=/)st=substr(f[i],4)+0;else if(f[i]~/^rb=/)rb=substr(f[i],4)+0;else if(f[i]~/^tb=/)tb=substr(f[i],4)+0} if(st>=t0 && uid>=10000)sum[uid]+=rb+tb }
    END {for(u in sum)printf "%d %d\n",u,sum[u]}
  ' > "$DTMP.data"
  pm list packages -U 2>/dev/null | $BB awk -F'[ :]' 'NF>=4{print $2" "$4}' > "$DTMP.pkgs"
  $BB awk 'NR==FNR{p[$2]=$1;next}{print (p[$1]!=""?p[$1]:"uid"$1),$2}' "$DTMP.pkgs" "$DTMP.data" > "$DTMP.named"
  DAY=$(date +%Y%m%d)
  { printf 'day=%s\nboot=%s\ntime=%s\n' "$DAY" "$BOOT" "$NOW"; cat "$DTMP.named"; } > "$SNAP.tmp"
  mv "$SNAP.tmp" "$SNAP"
  # 自归档: 重启前由 AutoJs6 等外部调用时, 不依赖引擎也能落盘
  mkdir -p "$DROOT/appstats" 2>/dev/null
  cp "$SNAP" "$DROOT/appstats/$DAY.$BOOT.snap" 2>/dev/null
  rm -f "$DTMP.data" "$DTMP.pkgs" "$DTMP.named"
  exit 0
fi

pm list packages -U 2>/dev/null | $BB awk -F'[ :]' 'NF>=4{print $4" "$2}' > "$DTMP.pkgs"
/system/bin/dumpsys netstats detail 2>/dev/null | $BB awk -v t0="$T0" '
  /^ *ident=/ {
    mob = ($0 ~ /type=0/)
    uid = -1
    if (match($0, /uid=[0-9]+/)) uid = substr($0, RSTART+4, RLENGTH-4) + 0
  }
  mob && /^ *NetworkStatsHistory:/ { uidstats = ($0 ~ /bucketDuration=7200/); next }
  mob && uidstats && /^ *st=/ {
    n = split($0, f, " ")
    st = 0; rb = 0; tb = 0
    for (i = 1; i <= n; i++) {
      if (f[i] ~ /^st=/)      st = substr(f[i], 4) + 0
      else if (f[i] ~ /^rb=/) rb = substr(f[i], 4) + 0
      else if (f[i] ~ /^tb=/) tb = substr(f[i], 4) + 0
    }
    if (st >= t0) {
      if (uid >= 10000) sum[uid] += rb + tb
    }
  }
  END {
    for (u in sum) if (sum[u] > 0) printf "U %d %d\n", u, sum[u]
    for (u in sum) tot += sum[u]
    printf "T %d\n", tot+0
  }
' > "$DTMP.raw"

sort -k3 -rn "$DTMP.raw" 2>/dev/null | $BB awk '
  NR==FNR { m[$1]=$2; next }
  $1=="U" { u=$2; name=(u in m)?m[u]:("uid" u); printf "%s %.1f\n", name, $3/1048576 }
' "$DTMP.pkgs" -
grep '^T ' "$DTMP.raw" 2>/dev/null | $BB awk '{printf "TOTAL %.1f\n", $2/1048576}'
rm -f "$DTMP.pkgs" "$DTMP.raw"
