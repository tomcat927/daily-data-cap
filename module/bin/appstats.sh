#!/system/bin/sh
# 每应用蜂窝用量统计 (引擎归档与 WebUI 共用)
# 用法:
#   appstats.sh [t0]           当前开机实时用量 (自 t0 起, 缺省今日 0 点)
#   appstats.sh [t0] day       今日全天: 历史开机周期快照最大值求和 + 当前开机实时
#   appstats.sh [t0] snapshot  保存 UID 当日累计快照 (reboot.js 重启前调用)
# 输出: "包名 MB" 降序行, 末行 "TOTAL 合计MB"
# 系统只保留开机以来的 per-UID 桶; day 模式用快照文件补齐重启前时段
BB="/data/adb/magisk/busybox"
DTMP="/data/adb/daily_data_cap/.appstats"
DROOT="/data/adb/daily_data_cap"

MODE=""; T0=""
for A in "$@"; do
  case "$A" in
    snapshot) MODE="snapshot" ;;
    day) MODE="day" ;;
    ''|*[!0-9]*) ;;
    *) T0="$A" ;;
  esac
done
H=$(date +%H | sed 's/^0//'); M=$(date +%M | sed 's/^0//'); S=$(date +%S | sed 's/^0//')
[ -n "$T0" ] || T0=$(( $(date +%s) - ${H:-0}*3600 - ${M:-0}*60 - ${S:-0} ))
mkdir -p "$DTMP" 2>/dev/null

if [ "$MODE" = "snapshot" ]; then
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

# ---- 实时解析当前开机当日累计 (type=0 蜂窝 ident, uid>=10000) ----
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
    if (st >= t0 && uid >= 10000) sum[uid] += rb + tb
  }
  END { for (u in sum) if (sum[u] > 0) printf "U %d %d\n", u, sum[u] }
' > "$DTMP.raw"
$BB awk 'NR==FNR{m[$1]=$2;next} $1=="U"{u=$2;name=(u in m)?m[u]:("uid"u);printf "%s %d\n",name,$3}' "$DTMP.pkgs" "$DTMP.raw" > "$DTMP.named"

if [ "$MODE" = "day" ]; then
  # 历史开机周期: 今日快照中排除当前 boot, 每周期取最大累计(周期末值)求和
  CURBOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  DAY=$(date -d @"$T0" +%Y%m%d 2>/dev/null)
  [ -n "$DAY" ] || DAY=$(date +%Y%m%d)
  ls "$DROOT/appstats/" 2>/dev/null | grep "^$DAY\." | sed "s|^|$DROOT/appstats/|" > "$DTMP.snaps"
  DBG=/data/adb/daily_data_cap/.daydebug
  { echo "==T0=$T0 DAY=$DAY CURBOOT=$CURBOOT"; echo "snaps字节=$(wc -c < "$DTMP.snaps")"; sed -n '1,3p' "$DTMP.snaps"; } >> "$DBG" 2>&1
  if [ -s "$DTMP.snaps" ]; then
    $BB awk -v curboot="$CURBOOT" -v targetday="$DAY" '
      FNR==1 { boot="" }
      /^boot=/ { boot=substr($0,6); next }
      /^day=/ { d=substr($0,5); next }
      /^time=/ { next }
      boot!="" && d==targetday && NF>=2 { k=boot SUBSEP $1; if($2+0>v[k])v[k]=$2+0 }
      END { for(k in v){ split(k,a,SUBSEP); if(a[1]!=curboot) h[a[2]]+=v[k] }
            for(n in h) if(h[n]>0) printf "%s %d\n", n, h[n] }
    ' $(cat "$DTMP.snaps") > "$DTMP.hist"
  else
    : > "$DTMP.hist"
  fi
  # 合并: 历史周期 + 当前开机实时 (同名累加, 字节级合并后统一格式化)
  $BB awk '{h[$1]+=$2} END{for(n in h) if(h[n]>0) printf "%s %.1f\n",n,h[n]/1048576}' \
    "$DTMP.hist" "$DTMP.named" | sort -k2 -rn
  $BB awk '{t+=$2} END{printf "TOTAL %.1f\n", t/1048576}' "$DTMP.hist" "$DTMP.named"
else
  sort -k2 -rn "$DTMP.named" | $BB awk '{printf "%s %.1f\n",$1,$2/1048576}'
  $BB awk '{t+=$2} END{printf "TOTAL %.1f\n", t/1048576}' "$DTMP.named"
fi
rm -f "$DTMP.pkgs" "$DTMP.raw" "$DTMP.named" "$DTMP.hist" "$DTMP.snaps"
