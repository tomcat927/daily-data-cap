#!/system/bin/sh
# Daily Data Cap —— 按日限流 Magisk 模块引擎
# 用法: dailycap.sh {start|stop|restart|status|daemon|babysit|block|lift|liftmin N|reset}

MODDIR="/data/adb/modules/daily_data_cap"
# 运行时数据放模块目录外: Magisk 升级时会整体替换模块目录, 放里面升级即丢
DATA="/data/adb/daily_data_cap"
BB="/data/adb/magisk/busybox"
IPT="/system/bin/iptables"
IPT6="/system/bin/ip6tables"
SVC="/system/bin/svc"
DUMP="/system/bin/dumpsys"
CHAIN="DAILYCAP"
LOG="$DATA/engine.log"
PIDF="$DATA/daemon.pid"
BABY_PIDF="$DATA/babysitter.pid"
HTTPD_PIDF="$DATA/httpd.pid"
CFG="$DATA/config"
STATEF="$DATA/state"
USEDF="$DATA/used_bytes"
DAYF="$DATA/day"
IFINFOF="$DATA/ifinfo"        # 第1行: 数据接口名, 第2行: 上次字节快照
BLOCKED_IF="$DATA/blocked_iface"
CMDF="$DATA/cmd"
IFRES_TS=0

mkdir -p "$DATA" 2>/dev/null

log() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null
  if [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 262144 ] 2>/dev/null; then
    tail -n 400 "$LOG" > "$LOG.t" 2>/dev/null && mv "$LOG.t" "$LOG"
  fi
}

notify() {
  # root(uid0) 直发的通知在部分 ROM 上被 NMS 静默丢弃(crDroid 实测),
  # 经 shell uid2000 转发可正常显示; su 2000 失败(如无 Magisk)则回退 root 直发
  su 2000 -c "cmd notification post -t '$1' dailycap '$2'" >/dev/null 2>&1 \
    || cmd notification post -t "$1" dailycap "$2" >/dev/null 2>&1 || true
}

# 结构化事件流水(统计用): 日期 时间 类型 详情; 超200KB裁到最近1000行
evt() { # $1=TYPE $2=details
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1 ${2:-}" >> "$DATA/events.log" 2>/dev/null
  if [ "$(wc -c < "$DATA/events.log" 2>/dev/null || echo 0)" -gt 204800 ] 2>/dev/null; then
    tail -n 1000 "$DATA/events.log" > "$DATA/events.log.t" 2>/dev/null && mv "$DATA/events.log.t" "$DATA/events.log"
  fi
}

bump() { echo $(( $(cat "$1" 2>/dev/null || echo 0) + 1 )) > "$1"; }

load_cfg() {
  if [ ! -f "$CFG" ]; then
    cat > "$CFG" <<EOF
THRESHOLD_MB=900
HARD_CAP_MB=1024
WEBUI_PORT=8899
CALIB_INTERVAL=3600
FLOW_MOBILE=
FLOW_PWD_HASH=
EOF
    chmod 600 "$CFG" 2>/dev/null
    log "初始化默认配置"
    sleep 3
    notify "Daily Data Cap 已启动" "面板: http://127.0.0.1:8899"
  fi
  . "$CFG"
}

save_state() { # $1=STATE $2=LIFT_MODE $3=LIFT_UNTIL
  printf 'STATE=%s\nLIFT_MODE=%s\nLIFT_UNTIL=%s\n' "$1" "$2" "${3:-0}" > "$STATEF.t" && mv "$STATEF.t" "$STATEF"
}
read_state() {
  STATE="ACTIVE"; LIFT_MODE="-"; LIFT_UNTIL=0
  [ -f "$STATEF" ] && . "$STATEF" 2>/dev/null
}
get_used() { cat "$USEDF" 2>/dev/null || echo 0; }
set_used() { printf '%s\n' "$1" > "$USEDF.t" && mv "$USEDF.t" "$USEDF"; }

# 64 位数值运算 (mksh 是 32 位算术, 字节级运算必须走 busybox awk, 否则溢出)
ncmp() { $BB awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >= b+0)}'; }    # a >= b ?
nadd() { $BB awk -v a="$1" -v b="$2" 'BEGIN{printf "%d", a+b}'; }
nmb()  { $BB awk -v b="$1" 'BEGIN{printf "%.1f", b/1048576}'; }

init_day() {
  if [ ! -f "$DAYF" ]; then
    date +%Y%m%d > "$DAYF"
    [ -f "$USEDF" ] || set_used 0
  fi
}

# ---------- 数据接口识别 ----------
valid_cell_iface() {
  case "$1" in
    rmnet_data*|vt_data*|ccmni*) [ -d "/sys/class/net/$1" ] && return 0 ;;
  esac
  return 1
}

# 找当前"移动数据上网"接口: dumpsys 解析 CELLULAR+INTERNET 能力(天然排除 IMS/WiFi), 路由查询兜底
get_data_iface() {
  IF_=""
  IF_=$($DUMP connectivity 2>/dev/null \
    | grep 'NetworkAgentInfo' | grep 'Transports: CELLULAR' \
    | grep 'INTERNET' | grep -v 'NOT_INTERNET' \
    | grep -o 'InterfaceName: [a-z0-9_]*' | head -n 1 | cut -d' ' -f2)
  if valid_cell_iface "$IF_"; then echo "$IF_"; return 0; fi
  IF_=$(ip -6 route get 2400:3200::1111 2>/dev/null | grep -o 'dev [a-z0-9_]*' | head -n 1 | cut -d' ' -f2)
  if valid_cell_iface "$IF_"; then echo "$IF_"; return 0; fi
  return 1
}

# ---------- iptables ----------
ensure_chains() {
  $IPT -N $CHAIN 2>/dev/null
  $IPT6 -N $CHAIN 2>/dev/null
}

apply_block() { # $1=iface
  ensure_chains
  $IPT -C OUTPUT -m comment --comment dailycap -j $CHAIN 2>/dev/null \
    || $IPT -I OUTPUT 1 -m comment --comment dailycap -j $CHAIN
  $IPT6 -C OUTPUT -m comment --comment dailycap -j $CHAIN 2>/dev/null \
    || $IPT6 -I OUTPUT 1 -m comment --comment dailycap -j $CHAIN
  $IPT -F $CHAIN 2>/dev/null
  $IPT6 -F $CHAIN 2>/dev/null
  # 系统探针白名单: 放行 uid0(netd 的 DNS) 与 uid1051(NetworkStack 连通性探针)。
  # 否则探针被拦 → Android 把网络标记为"不可用"并回避 → 系统无默认网络 →
  # 浏览器拒绝加载本机面板, 断网时恰恰需要面板来解除。
  # uid0 仅放行 53 端口: clatd 以 root 运行, 若放行全部 root 流量,
  # 经 clat 翻译的应用 IPv4 流量会绕过拦截。
  $IPT -A $CHAIN -m owner --uid-owner 0 -p udp --dport 53 -j RETURN
  $IPT -A $CHAIN -m owner --uid-owner 0 -p tcp --dport 53 -j RETURN
  $IPT -A $CHAIN -m owner --uid-owner 1051 -j RETURN
  $IPT6 -A $CHAIN -m owner --uid-owner 0 -p udp --dport 53 -j RETURN
  $IPT6 -A $CHAIN -m owner --uid-owner 0 -p tcp --dport 53 -j RETURN
  $IPT6 -A $CHAIN -m owner --uid-owner 1051 -j RETURN
  $IPT -A $CHAIN -o "$1" -j REJECT 2>/dev/null
  $IPT6 -A $CHAIN -o "$1" -j REJECT 2>/dev/null
  echo "$1" > "$BLOCKED_IF"
  log "拦截规则已应用到 $1"
}

unblock_rules() {
  $IPT -D OUTPUT -m comment --comment dailycap -j $CHAIN 2>/dev/null
  $IPT6 -D OUTPUT -m comment --comment dailycap -j $CHAIN 2>/dev/null
  $IPT -F $CHAIN 2>/dev/null
  $IPT6 -F $CHAIN 2>/dev/null
  $IPT -X $CHAIN 2>/dev/null
  $IPT6 -X $CHAIN 2>/dev/null
  rm -f "$BLOCKED_IF"
}

# ---------- 状态动作 ----------
do_block() {
  read_state
  save_state BLOCKED - 0
  # 注意: 不用 svc data disable —— 拆掉数据通道后系统无活动网络,
  # 浏览器(如 X浏览器)会拒绝加载 127.0.0.1 面板, 而断网时恰恰需要面板来解除。
  # 拦截完全由 iptables 内核层完成, 数据通道保持连接但流量出不去。
  IFB_=$(get_data_iface) && apply_block "$IFB_"
  notify "Daily Data Cap" "今日用量已达 ${THRESHOLD_MB:-?}MB, 移动数据已断开。解除请打开 WebUI。"
  log "BLOCK 断网生效 used=$(get_used)"
  bump "$DATA/day_blocks"
  date '+%H:%M:%S' >> "$DATA/day_block_times"
  evt "BLOCK used=$(nmb "$(get_used)")MB iface=${IFB_:-无}"
}

do_lift() { # $1=mode $2=minutes
  unblock_rules
  $SVC data enable >/dev/null 2>&1 || true
  case "$1" in
    MIDNIGHT) save_state LIFTED MIDNIGHT 0 ;;
    HARDCAP)  save_state LIFTED HARDCAP 0 ;;
    MINUTES)  save_state LIFTED MINUTES $(( $(date +%s) + ${2:-30} * 60 )) ;;
  esac
  notify "Daily Data Cap" "已人工解除限制(模式 $1), 超出部分按套餐计费。0 点自动恢复。"
  log "LIFT mode=$1 arg=${2:-}"
  bump "$DATA/day_lifts"
  evt "LIFT mode=$1 used=$(nmb "$(get_used)")MB"
}

# 每应用用量归档: day 模式合并各开机周期(快照最大值+当前实时), 写入 appstats/<日期>.csv
app_archive() { # $1=日期YYYYMMDD $2=该日0点epoch
  mkdir -p "$DATA/appstats" 2>/dev/null
  app_snapshot "$1" "$2" || true
  sh "$MODDIR/bin/appstats.sh" "$2" day > "$DATA/appstats/$1.tmp" 2>/dev/null
  if grep -q '^TOTAL' "$DATA/appstats/$1.tmp" 2>/dev/null; then
    $BB awk '{
      if ($1=="TOTAL") printf "total,%s\n", $2
      else if (NF>=2) printf "%s,%s\n", $1, $2
    }' "$DATA/appstats/$1.tmp" > "$DATA/appstats/$1.csv"
    evt "APPARCH day=$1"
  else
    evt "APPARCH 失败 day=$1"
  fi
  rm -f "$DATA/appstats/$1.tmp" "$DATA/appstats/$1.live" "$DATA/appstats/$1."*.snap
  N_=$(ls "$DATA/appstats" 2>/dev/null | grep -c '\.csv$')
  if [ "${N_:-0}" -gt 40 ]; then
    for F_ in $(ls "$DATA/appstats" | sort | head -n $((N_ - 40))); do
      rm -f "$DATA/appstats/$F_"
    done
  fi
}

app_snapshot() { # $1=日期YYYYMMDD $2=当天0点epoch
  sh "$MODDIR/bin/appstats.sh" "$2" snapshot >/dev/null 2>&1
  CUR="$DATA/.appstats.snapshot"
  [ -f "$CUR" ] || return 1
  CURBOOT=$(sed -n '2s/^boot=//p' "$CUR")
  CURDAY=$(sed -n '1s/^day=//p' "$CUR")
  [ -n "$CURBOOT" ] && [ "$CURDAY" = "$1" ] || return 1
  cp "$CUR" "$DATA/appstats/$1.$CURBOOT.snap"
  return $?
}

do_rollover() {
  read_state
  unblock_rules
  if [ "$STATE" = "BLOCKED" ]; then
    $SVC data enable >/dev/null 2>&1 || true
  fi
  # 当日统计归档(清零前): 日期,本地MB,营业厅MB,偏差MB,触发次数,解除次数,BLOCK时间(|分隔)
  FIN_=$(nmb "$(get_used)")
  CC_=$($BB awk 'NR==1{print $3}' "$DATA/carrier" 2>/dev/null)
  CD_=""
  [ -n "$CC_" ] && CD_=$($BB awk -v c="$CC_" -v f="$FIN_" 'BEGIN{printf "%.1f", c-f}')
  BT_=$(tr '\n' '|' < "$DATA/day_block_times" 2>/dev/null | sed 's/|$//')
  printf '%s,%s,%s,%s,%s,%s,%s\n' "$(cat "$DAYF" 2>/dev/null)" "$FIN_" "${CC_:-0}" "${CD_:-0}" \
    "$(cat "$DATA/day_blocks" 2>/dev/null || echo 0)" "$(cat "$DATA/day_lifts" 2>/dev/null || echo 0)" \
    "$BT_" \
    >> "$DATA/daily.csv"
  tail -n 184 "$DATA/daily.csv" > "$DATA/daily.csv.t" 2>/dev/null && mv "$DATA/daily.csv.t" "$DATA/daily.csv"
  echo 0 > "$DATA/day_blocks"; echo 0 > "$DATA/day_lifts"; : > "$DATA/day_block_times"
  evt "ROLLOVER final=${FIN_}MB carrier=${CC_:-NA}MB"
  # 每应用归档: 结束日的 0 点 epoch = 当前时刻减去今天已走的时分秒 (翻转刚发生, 结束日即刚过的那天)
  H_=$(date +%H | sed 's/^0//'); M_=$(date +%M | sed 's/^0//'); S_=$(date +%S | sed 's/^0//')
  app_archive "$(cat "$DAYF" 2>/dev/null)" "$(( $(date +%s) - ${H_:-0}*3600 - ${M_:-0}*60 - ${S_:-0} ))"
  set_used 0
  rm -f "$DATA/carrier"
  date +%s > "$DATA/last_calib"   # 0点后隔一个校对周期再查, 避开运营商重置延迟拿到昨日旧数据
  date +%Y%m%d > "$DAYF"
  save_state ACTIVE - 0
  notify "Daily Data Cap" "新的一天: 计数清零, 移动数据已恢复。"
  log "ROLLOVER 计数清零并恢复网络"
}

# ---------- 主循环各环节 ----------
cmd_tick() {
  [ -f "$CMDF" ] || return 0
  C_=$(cat "$CMDF" 2>/dev/null)
  rm -f "$CMDF"
  case "$C_" in
    LIFT:MIDNIGHT)  do_lift MIDNIGHT ;;
    LIFT:HARDCAP)   do_lift HARDCAP ;;
    LIFT:MINUTES:*) do_lift MINUTES "${C_##*:}" ;;
    BLOCK)          do_block ;;
    CALIB)   flow_calib 1 ;;
    RESET)
      set_used 0
      notify "Daily Data Cap" "今日计数已手动清零"
      log "RESET 手动清零"
      ;;
    SETTHRESH:*)
      V_="${C_##*:}"
      case "$V_" in ''|*[!0-9]*) log "SETTHRESH 非法值: $V_"; return ;; esac
      if [ "$V_" -lt 50 ] || [ "$V_" -gt 2000 ]; then log "SETTHRESH 超范围: $V_"; return; fi
      sed -i "s/^THRESHOLD_MB=.*/THRESHOLD_MB=${V_}/" "$CFG" && . "$CFG"
      notify "Daily Data Cap" "阈值已更新为 ${V_}MB"
      log "SETTHRESH $V_"
      ;;
    *) [ -n "$C_" ] && log "未知命令: $C_" ;;
  esac
}

count_tick() {
  NOW_=$(date +%s)
  IF_=""; SRX_=""; STX_=""
  if [ -f "$IFINFOF" ]; then
    IF_=$(head -n 1 "$IFINFOF")
    SRX_=$(sed -n '2p' "$IFINFOF")
    STX_=$(sed -n '3p' "$IFINFOF")
  fi
  # 无缓存 / 接口消失或已 down / 每 60 秒: 重新解析数据接口
  # (sysfs 里 rmnet_dataX 条目不会因数据呼叫拆除而消失, 必须查 operstate)
  if [ -z "$IF_" ] || [ ! -d "/sys/class/net/$IF_" ] \
     || [ "$(cat "/sys/class/net/$IF_/operstate" 2>/dev/null)" = "down" ] \
     || [ $((NOW_ - IFRES_TS)) -gt 60 ]; then
    IFRES_TS=$NOW_
    NEW_=$(get_data_iface) || NEW_=""
    if [ -n "$NEW_" ] && [ "$NEW_" != "$IF_" ]; then
      IF_="$NEW_"; SRX_=""; STX_=""     # 换接口: 基线重置, 不把历史字节算进今天
      log "数据接口: $IF_"
    elif [ -z "$NEW_" ]; then
      IF_=""
    fi
  fi
  [ -z "$IF_" ] && { IFACE=""; return 1; }
  [ -d "/sys/class/net/$IF_/statistics" ] || { IFACE=""; return 1; }
  RX_=$(cat "/sys/class/net/$IF_/statistics/rx_bytes" 2>/dev/null || echo 0)
  TX_=$(cat "/sys/class/net/$IF_/statistics/tx_bytes" 2>/dev/null || echo 0)
  if [ -z "$SRX_" ]; then
    DELTA_=0     # 新基线: 本次不计量
  else
    DELTA_=$($BB awk -v rx="$RX_" -v tx="$TX_" -v srx="$SRX_" -v stx="$STX_" \
      'BEGIN{d=(rx-srx)+(tx-stx); printf "%d", d<0?0:d}')
  fi
  USED_=$(nadd "$(get_used)" "$DELTA_")
  set_used "$USED_"
  printf '%s\n%s\n%s\n' "$IF_" "$RX_" "$TX_" > "$IFINFOF"
  USED="$USED_"; IFACE="$IF_"
}

state_tick() {
  read_state
  THB_=$(( ${THRESHOLD_MB:-900} * 1048576 ))
  HCB_=$(( ${HARD_CAP_MB:-1024} * 1048576 ))
  NOW_=$(date +%s)
  case "$STATE" in
    ACTIVE)
      ncmp "${USED:-0}" "$THB_" && do_block
      ;;
    LIFTED)
      case "$LIFT_MODE" in
        MINUTES) [ "${LIFT_UNTIL:-0}" -gt 0 ] && ncmp "$NOW_" "$LIFT_UNTIL" && do_block ;;
        HARDCAP) ncmp "${USED:-0}" "$HCB_" && do_block ;;
      esac
      ;;
    BLOCKED)
      # 快捷开关重开数据 / 接口重编号: 每轮强制重新解析当前上网接口,
      # 与被拦接口不一致就立刻重新上规则 (不依赖 count_tick 的缓存)
      IFB_=$(cat "$BLOCKED_IF" 2>/dev/null || echo "")
      CUR_=$(get_data_iface) || CUR_=""
      if [ -n "$CUR_" ] && [ "$CUR_" != "$IFB_" ]; then
        apply_block "$CUR_"
        evt "REBLOCK iface=$CUR_ (旧:$IFB_)"
      fi
      ;;
  esac
}

# ---------- 营业厅校对 (flow.mxzu.net, 可选) ----------
# 数据滞后特性决定校对方向: 只上修不下修 —— 营业厅比本地高超过容差说明本地漏计
flow_calib() { # $1=force(1 手动)
  [ -n "$FLOW_MOBILE" ] && [ -n "$FLOW_PWD_HASH" ] || return 0
  read_state
  [ "$1" != "1" ] && [ "$STATE" = "BLOCKED" ] && return 0   # 断网时查询必失败, 跳过不计失败
  RESP=$($BB wget -qO- \
    --header="User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36" \
    --header="Referer: https://flow.mxzu.net/" \
    "https://flow.mxzu.net/api/get-info?mobile=${FLOW_MOBILE}&password=${FLOW_PWD_HASH}" 2>/dev/null)
  case "$RESP" in
    *'"code":200'*) ;;
    *)
      FAILS_=$(cat "$DATA/flow_fails" 2>/dev/null || echo 0)
      FAILS_=$((FAILS_ + 1))
      echo "$FAILS_" > "$DATA/flow_fails"
      log "CALIB 失败(${FAILS_}): $(printf '%s' "$RESP" | head -c 120)"
      if [ "$FAILS_" -ge 3 ]; then
        sed -i "s/^CALIB_INTERVAL=.*/CALIB_INTERVAL=0/" "$CFG"
        notify "Daily Data Cap" "营业厅校对连续失败3次, 已自动停用(凭证失效?). 重新配置 config 后可开启"
        log "CALIB 自动停用"
      fi
      return 1
      ;;
  esac
  echo 0 > "$DATA/flow_fails"
  # 日租宝条目: flowType=3 且带 rzbEndData(每日到期)特征, 防未来多桶时选错;
  # 套内5M(flowType=1)/定向免费(flowType=2)为长期有效, 不进每日校对
  ALL3_=$(printf '%s' "$RESP" | sed 's/{"addUpItemName"/\n{"addUpItemName"/g' | grep '"flowType":"3"')
  ENTRY_=$(printf '%s' "$ALL3_" | grep 'rzbEndData' | head -n 1)
  [ -z "$ENTRY_" ] && ENTRY_=$(printf '%s' "$ALL3_" | head -n 1)
  C_MB=$(printf '%s' "$ENTRY_" | grep -o '"use":"[0-9.]*"' | head -n 1 | grep -o '[0-9.]*')
  [ -z "$C_MB" ] && { log "CALIB 解析失败: 未找到日租宝use"; return 1; }
  C_RM=$(printf '%s' "$ENTRY_" | grep -o '"remain":"[0-9.]*"' | head -n 1 | grep -o '[0-9.]*')
  RZB_=$(printf '%s' "$ENTRY_" | grep -o '"rzbEndData":"[^"]*"' | cut -d'"' -f4)
  printf '%s %s %s\n' "$(date '+%m-%d %H:%M')" "$C_MB" "${C_RM:-0}" > "$DATA/carrier"
  DIFF_=$($BB awk -v c="$C_MB" -v u="$(nmb "$(get_used)")" 'BEGIN{printf "%.1f", c-u}')
  # 上修条件: 差值>50MB 说明本地漏计; >800MB 视为运营商滞后旧数据(如0点重置未完成), 不校
  UP_=$($BB awk -v d="$DIFF_" 'BEGIN{print (d>50 && d<800)?1:0}')
  BIG_=$($BB awk -v d="$DIFF_" 'BEGIN{print (d>=800)?1:0}')
  if [ "$UP_" = "1" ]; then
    NEWU_=$($BB awk -v u="$(get_used)" -v d="$DIFF_" 'BEGIN{printf "%d", u + d*1048576}')
    set_used "$NEWU_"
    notify "Daily Data Cap" "校对: 营业厅${C_MB}MB明显高于本地, 已补计+${DIFF_}MB"
    log "CALIB 上修+${DIFF_}MB -> $(nmb "$NEWU_")MB (日包到期: ${RZB_:-未知})"
  elif [ "$BIG_" = "1" ]; then
    log "CALIB 偏差异常(${DIFF_}MB), 疑似运营商滞后数据, 不校对 (营业厅${C_MB}MB)"
  else
    log "CALIB 偏差${DIFF_}MB 在容差内, 营业厅${C_MB}MB 剩${C_RM}MB (日包到期: ${RZB_:-未知})"
  fi
  date +%s > "$DATA/last_calib"
  return 0
}

# ---------- WebUI ----------
start_httpd() {
  load_cfg
  [ -f "$HTTPD_PIDF" ] && kill "$(cat "$HTTPD_PIDF")" 2>/dev/null
  rm -f "$HTTPD_PIDF"
  nohup $BB httpd -f -p 127.0.0.1:${WEBUI_PORT:-8899} -h "$MODDIR/web" >/dev/null 2>&1 &
  echo $! > "$HTTPD_PIDF"
  log "WebUI 启动: http://127.0.0.1:${WEBUI_PORT:-8899}"
}

# ---------- 进程管理 ----------
babysit() {
  echo $$ > "$BABY_PIDF"
  while :; do
    sleep 60
    if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then continue; fi
    log "babysitter: 拉起 daemon"
    sh "$0" daemon >/dev/null 2>&1 &
  done
}

start() {
  load_cfg
  if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
    echo "已在运行 (pid $(cat "$PIDF"))"
    return 0
  fi
  nohup sh "$0" daemon </dev/null >/dev/null 2>&1 &
  nohup sh "$0" babysit </dev/null >/dev/null 2>&1 &
  N_=0
  while [ "$N_" -lt 10 ]; do
    [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null && break
    sleep 0.5; N_=$((N_+1))
  done
  sh "$0" status
}

stop() {
  kill "$(cat "$BABY_PIDF" 2>/dev/null)" 2>/dev/null
  kill "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null
  kill "$(cat "$HTTPD_PIDF" 2>/dev/null)" 2>/dev/null
  rm -f "$BABY_PIDF" "$PIDF" "$HTTPD_PIDF"
  log "daemon 已停止"
}

status() {
  load_cfg; read_state
  USED=$(get_used)
  if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then D_="运行中(pid $(cat "$PIDF"))"; else D_="未运行"; fi
  echo "daemon: $D_"
  echo "state: $STATE (mode=$LIFT_MODE)  used: $(nmb "$USED") MB / ${THRESHOLD_MB}MB  iface: $(head -n 1 "$IFINFOF" 2>/dev/null || echo -)  blocked_if: $(cat "$BLOCKED_IF" 2>/dev/null || echo -)"
  echo "webui: http://127.0.0.1:${WEBUI_PORT:-8899}"
}

daemon() {
  load_cfg
  init_day
  echo $$ > "$PIDF"
  log "=== daemon 启动 pid=$$ state=$(read_state; echo $STATE) ==="
  start_httpd
  LASTHB=0
  while :; do
    # 日期翻转(0 点重置)
    TODAY=$(date +%Y%m%d)
    [ "$TODAY" != "$(cat "$DAYF" 2>/dev/null || echo)" ] && { do_rollover; continue; }
    cmd_tick
    USED=$(get_used); IFACE=""
    count_tick || true
    state_tick
    # 定时营业厅校对 (CALIB_INTERVAL=0 关闭; 断网状态内部自动跳过)
    if [ "${CALIB_INTERVAL:-0}" -gt 0 ]; then
      LASTC_=$(cat "$DATA/last_calib" 2>/dev/null || echo 0)
      CN2_=$(date +%s)
      [ $((CN2_ - LASTC_)) -ge "$CALIB_INTERVAL" ] && flow_calib 0
    fi
    # 每 5 分钟持久化 UID 累计量，跨开机周期保留（失败也顺延, 避免每 5 秒重试打爆 dumpsys）
    SNAPTS=$(cat "$DATA/appstats_snapshot_time" 2>/dev/null || echo 0)
    if [ $(( $(date +%s) - SNAPTS )) -ge 300 ]; then
      SNAPDAY=$(date +%Y%m%d)
      H_=$(date +%H | sed 's/^0//'); M_=$(date +%M | sed 's/^0//'); S_=$(date +%S | sed 's/^0//')
      app_snapshot "$SNAPDAY" "$(( $(date +%s) - ${H_:-0}*3600 - ${M_:-0}*60 - ${S_:-0} ))"
      date +%s > "$DATA/appstats_snapshot_time"
    fi
    # WebUI 看门狗
    HP_=$(cat "$HTTPD_PIDF" 2>/dev/null || echo "")
    if [ -z "$HP_" ] || ! kill -0 "$HP_" 2>/dev/null; then start_httpd; fi
    # 轮询间隔: 近阈值(80%)加密到 1 秒 (乘法保持 32 位安全量级)
    TH80_=$(( ${THRESHOLD_MB:-900} * 838861 ))   # 0.8 * 1048576
    HC90_=$(( ${HARD_CAP_MB:-1024} * 943719 ))   # 0.9 * 1048576
    INTERVAL=5
    if [ "$STATE" = "ACTIVE" ] && ncmp "${USED:-0}" "$TH80_"; then INTERVAL=1; fi
    if [ "$STATE" = "LIFTED" ] && [ "$LIFT_MODE" = "HARDCAP" ] && ncmp "${USED:-0}" "$HC90_"; then INTERVAL=1; fi
    NOW_=$(date +%s)
    [ $((NOW_ - LASTHB)) -ge 300 ] && { LASTHB=$NOW_; log "HB state=$STATE used=$(nmb ${USED:-0})MB iface=${IFACE:-无} interval=$INTERVAL"; }
    sleep "$INTERVAL"
  done
}

case "$1" in
  start)   start ;;
  stop)    stop ;;
  restart) stop; sleep 1; start ;;
  status)  status ;;
  daemon)  daemon ;;
  babysit) babysit ;;
  block)   load_cfg; do_block ;;
  lift)    load_cfg; do_lift MIDNIGHT ;;
  liftmin) load_cfg; do_lift MINUTES "${2:-30}" ;;
  resetchain) unblock_rules ;;
  *) echo "用法: $0 {start|stop|restart|status|block|lift|liftmin N|reset...}" ;;
esac
