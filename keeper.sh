#!/usr/bin/env bash
# keeper.sh — InstaBox 免费机器的「运行 7h50m → 停机 10min → 继续」循环
#
# 由 GitHub Actions 每 10 分钟调用一次。每次调用只做一件事：
#   A. 机器已经停着（平台到点回收 / 手动停）且冷却结束  → 拉起
#   B. 机器在跑，且已连续跑满 RUN_MINUTES            → 停 → 等 REST_MINUTES → 起
#   C. 其它                                          → 什么都不做
#
# 状态记在 state.json（由 workflow 自动提交回仓库），
# 因为 GitHub runner 每次都是全新的一次性环境，本地文件留不住。

set -uo pipefail

MACHINE_ID="${MACHINE_ID:?MACHINE_ID is required}"
API_BASE="${API_BASE:-https://api.instabox.sh}"
RUN_MINUTES="${RUN_MINUTES:-470}"    # 7h50m
REST_MINUTES="${REST_MINUTES:-10}"
STATE_FILE="${STATE_FILE:-state.json}"
PY="${PY_BIN:-$(command -v python3 || command -v python || true)}"

[ -n "$PY" ] || { echo "::error::no python3/python on PATH"; exit 1; }
[ -n "${INSTABOX_API_KEY:-}" ] || { echo "::error::INSTABOX_API_KEY is empty — set the repo secret"; exit 1; }

API_CODE=000
API_BODY=""

# call METHOD PATH —— 直接调用（不要用 $( ) 包住），结果写进 API_CODE / API_BODY
call() {
  local method="$1" path="$2" resp
  local -a args=(-sS -X "$method"
                 -H "X-API-Key: ${INSTABOX_API_KEY}"
                 -H 'Accept: application/json'
                 -w '\n%{http_code}' --max-time 30)
  if [ "$method" = "POST" ]; then
    args+=(-H 'Content-Type: application/json' -d '{}'
           -H "Idempotency-Key: $("$PY" -c 'import uuid;print(uuid.uuid4())')")
  fi
  resp="$(curl "${args[@]}" "$API_BASE$path" 2>/dev/null)" || resp=$'\n000'
  API_CODE="${resp##*$'\n'}"
  API_BODY="${resp%$'\n'*}"
}

# jget FIELD -> 从标准输入取一个字段（支持 a.b），取不到输出空
jget() {
  "$PY" -c '
import json,sys
try:
    d=json.loads(sys.stdin.read())
except Exception:
    raise SystemExit
v=d
for p in sys.argv[1].split("."):
    v = v.get(p) if isinstance(v,dict) else None
    if v is None: break
print("" if v is None else v)
' "$1"
}

# jfirst JSON KEY1 KEY2 ... -> 依次尝试，返回第一个非空字段
jfirst() {
  local body="$1"; shift
  for k in "$@"; do
    local v; v="$(printf '%s' "$body" | jget "$k")"
    [ -n "$v" ] && { printf '%s' "$v"; return; }
  done
  printf ''
}

to_epoch() { # ISO8601 -> epoch（解析失败输出空）
  [ -n "$1" ] || { printf ''; return; }
  date -u -d "$1" +%s 2>/dev/null || printf ''
}

save_state() { # key value
  "$PY" - "$STATE_FILE" "$1" "$2" <<'PY'
import json,sys,time
path,key,val=sys.argv[1],sys.argv[2],sys.argv[3]
try:
    d=json.load(open(path))
except Exception:
    d={}
d[key]=int(val)
d["updatedAt"]=time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())
json.dump(d,open(path,"w"),indent=2)
PY
}

read_state() { # key
  [ -f "$STATE_FILE" ] || { printf ''; return; }
  "$PY" - "$STATE_FILE" "$1" <<'PY' 2>/dev/null
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    v=d.get(sys.argv[2])
    print("" if v is None else v)
except Exception:
    print("")
PY
}

now="$(date -u +%s)"
echo "now=$(date -u +%FT%TZ) run=${RUN_MINUTES}m rest=${REST_MINUTES}m"

call GET "/v1/machines/$MACHINE_ID"
body="$API_BODY"
if [ "$API_CODE" != "200" ]; then
  echo "::error::GET machine failed http=$API_CODE body=$(printf '%s' "$body" | head -c 300)"
  exit 1
fi

state="$(printf '%s' "$body" | jget state | tr '[:upper:]' '[:lower:]')"
cooldown="$(jfirst "$body" cooldownUntil cooldown_until)"
started_raw="$(jfirst "$body" runStartedAt run_started_at startedAt started_at lastStartedAt)"

if [ -z "$state" ]; then
  echo "::error::cannot parse state; body=$(printf '%s' "$body" | head -c 300)"
  exit 1
fi

cd_epoch="$(to_epoch "$cooldown")"
if [ -n "$cd_epoch" ] && [ "$now" -lt "$cd_epoch" ]; then
  echo "冷却中，直到 $cooldown（还剩 $(( (cd_epoch-now)/60 )) 分钟）"
  exit 0
fi

case "$state" in
  running|active|started)
    ;;
  suspended|stopped|hibernated|paused|off)
    echo "机器处于 $state，冷却已过 → 拉起"
    call POST "/v1/machines/$MACHINE_ID/start"
    if [ "$API_CODE" = "200" ] || [ "$API_CODE" = "202" ]; then
      echo "start 已下发"
      save_state lastStart "$now"
      exit 0
    fi
    echo "::warning::start 失败 http=$API_CODE body=$(printf '%s' "$API_BODY" | head -c 300)"
    exit 0
    ;;
  starting|pending|provisioning|stopping|rebooting|restarting)
    echo "过渡态 $state，本轮跳过"
    exit 0
    ;;
  *)
    echo "未知状态 '$state'，本轮跳过"
    exit 0
    ;;
esac

# ---- 运行中：判断该不该进入循环 ----
anchor="$(to_epoch "$started_raw")"
if [ -z "$anchor" ]; then
  anchor="$(read_state lastStart)"
fi
if [ -z "$anchor" ] || ! [ "$anchor" -gt 0 ] 2>/dev/null; then
  echo "没有可信的启动时间，以现在重新计时"
  save_state lastStart "$now"
  exit 0
fi

age_min="$("$PY" -c "print(int(($now-$anchor)/60))")"
echo "已连续运行 ${age_min} 分钟（锚点 $anchor）"

if [ "$age_min" -lt "$RUN_MINUTES" ]; then
  echo "还没到 ${RUN_MINUTES} 分钟，继续跑"
  exit 0
fi

# ---- 到点了：停 → 等 → 起 ----
echo "已达 ${RUN_MINUTES} 分钟 → stop"
call POST "/v1/machines/$MACHINE_ID/stop"
echo "stop http=$API_CODE"

settled=""
for _ in $(seq 1 30); do
  call GET "/v1/machines/$MACHINE_ID"
  s="$(printf '%s' "$API_BODY" | jget state | tr '[:upper:]' '[:lower:]')"
  case "$s" in
    suspended|stopped|hibernated|paused|off) settled="$s"; break ;;
  esac
  sleep 5
done

if [ -z "$settled" ]; then
  echo "::warning::停止后仍未落地（state=${s:-?}），下一轮重试"
  exit 0
fi
echo "已停止（$settled），保持 ${REST_MINUTES} 分钟"

rest_sec="$("$PY" -c "print(max(1,int(float('$REST_MINUTES')*60)))")"
sleep "$rest_sec"

echo "休息结束 → start"
call POST "/v1/machines/$MACHINE_ID/start"
if [ "$API_CODE" = "200" ] || [ "$API_CODE" = "202" ]; then
  save_state lastStart "$now"
  echo "已重新启动，下次循环在 ${RUN_MINUTES} 分钟后"
else
  echo "::error::休息完 start 失败 http=$API_CODE body=$(printf '%s' "$API_BODY" | head -c 300)"
  exit 1
fi
