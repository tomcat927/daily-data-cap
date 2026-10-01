#!/system/bin/sh
# Daily Data Cap —— 按日限流 Magisk 模块引擎
# 用法: dailycap.sh {start|stop|restart|status|daemon|babysit|block|lift|liftmin N|reset}

MODDIR="/data/adb/modules/daily_data_cap"
DATA="$MODDIR/data"
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
  cmd notification post -t "$1" dailycap "$2" >/dev/null 2>&1 || true
}

load_cfg() {
  if [ ! -f "$CFG" ]; then
    TOKEN=$(head -c 16 /dev/urandom | md5sum | cut -c1-12)
    cat > "$CFG" <<EOF
THRESHOLD_MB=900
HARD_CAP_MB=1024
WEBUI_PORT=8899
WEBUI_TOKEN=$TOKEN
EOF
    chmod 600 "$CFG" 2>/dev/null
    log "初始化默认配置"
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
  $SVC data disable >/dev/null 2>&1 || true
  IFB_=$(get_data_iface) && apply_block "$IFB_"
  notify "Daily Data Cap" "今日用量已达 ${THRESHOLD_MB:-?}MB, 移动数据已断开。解除请打开 WebUI。"
  log "BLOCK 断网生效 used=$(get_used)"
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
}

do_rollover() {
  read_state
  unblock_rules
  if [ "$STATE" = "BLOCKED" ]; then
    $SVC data enable >/dev/null 2>&1 || true
  fi
  set_used 0
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
        $SVC data disable >/dev/null 2>&1 || true
        apply_block "$CUR_"
      fi
      ;;
  esac
}

# ---------- WebUI ----------
start_httpd() {
  load_cfg
  [ -f "$HTTPD_PIDF" ] && kill "$(cat "$HTTPD_PIDF")" 2>/dev/null
  rm -f "$HTTPD_PIDF"
  nohup $BB httpd -f -p 127.0.0.1:${WEBUI_PORT:-8899} -h "$MODDIR/web" >/dev/null 2>&1 &
  echo $! > "$HTTPD_PIDF"
  log "WebUI 启动: http://127.0.0.1:${WEBUI_PORT:-8899}/cgi-bin/action?t=$WEBUI_TOKEN"
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
  echo "webui: http://127.0.0.1:${WEBUI_PORT:-8899}/cgi-bin/action?t=$WEBUI_TOKEN"
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
