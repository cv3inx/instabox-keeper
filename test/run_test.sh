#!/usr/bin/env bash
# 用假 API 把 keeper.sh 的主路径跑一遍。在 Git Bash 里执行：
#   PY_BIN="/c/.../python.exe" bash test/run_test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-8899}"
API="http://127.0.0.1:$PORT"
export PY_BIN="${PY_BIN:-python3}"

PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

"$PY_BIN" "$ROOT/test/mock_instabox.py" "$PORT" &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null' EXIT

for _ in $(seq 1 60); do
  curl -s "$API/__body" >/dev/null 2>&1 && break
  sleep 0.2
done

reset() { # state startedAgoMin cooldown
  curl -s -X POST "$API/__set?state=$1&startedAgoMin=$2&cooldown=$3" >/dev/null
}
events() { curl -s "$API/__events"; }
n_events() { events | "$PY_BIN" -c 'import json,sys;print(len(json.load(sys.stdin)))'; }

run_keeper() { # run_min rest_min
  INSTABOX_API_KEY=x MACHINE_ID=m_test API_BASE="$API" \
  RUN_MINUTES="$1" REST_MINUTES="$2" STATE_FILE="$ROOT/test/state.json" \
  PY_BIN="$PY_BIN" bash "$ROOT/keeper.sh"
}

echo "== 场景 1：跑满 471 分钟 → 应 stop → 等 → start =="
curl -s -X POST "$API/__set?state=running&startedAgoMin=471&cooldown=" >/dev/null
rm -f "$ROOT/test/state.json"
out1="$(run_keeper 470 0.05)"; echo "$out1" | sed 's/^/      /'
ev="$(events)"
n="$(n_events)"
[ "$n" = "2" ] && ok "产生 2 个动作（stop+start）" || bad "动作数应为 2，实际 $n"
first="$(echo "$ev" | "$PY_BIN" -c 'import json,sys;e=json.load(sys.stdin);print(e[0]["action"])')"
second="$(echo "$ev" | "$PY_BIN" -c 'import json,sys;e=json.load(sys.stdin);print(e[1]["action"])')"
[ "$first" = "stop" ] && ok "第一个动作是 stop" || bad "第一个动作是 $first"
[ "$second" = "start" ] && ok "第二个动作是 start" || bad "第二个动作是 $second"
echo "$out1" | grep -q "已重新启动" && ok "日志确认重启成功" || bad "日志没有重启成功"

echo "== 场景 2：只跑了 10 分钟 → 不应动它 =="
curl -s -X POST "$API/__set?state=running&startedAgoMin=10&cooldown=" >/dev/null
before="$(n_events)"
out2="$(run_keeper 470 0.05)"; echo "$out2" | sed 's/^/      /'
after="$(n_events)"
[ "$before" = "$after" ] && ok "没有触发任何动作" || bad "不该动却被动了"
echo "$out2" | grep -q "还没到 470 分钟" && ok "日志说明未到点" || bad "日志未说明"

echo "== 场景 3：机器被平台停掉且冷却已过 → 应直接拉起 =="
curl -s -X POST "$API/__set?state=suspended&startedAgoMin=0&cooldown=" >/dev/null
before="$(n_events)"
out3="$(run_keeper 470 0.05)"; echo "$out3" | sed 's/^/      /'
after="$(n_events)"
[ $((after-before)) -eq 1 ] && ok "只下发一次 start" || bad "动作数异常"
out3g="$(events | "$PY_BIN" -c 'import json,sys;e=json.load(sys.stdin);print(e[-1]["action"])')"
[ "$out3g" = "start" ] && ok "最后一个动作是 start" || bad "最后动作是 $out3g"

echo "== 场景 4：冷却中 → 什么都不做 =="
future="$("$PY_BIN" -c 'import time;print(time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime(time.time()+3600)))')"
curl -s -X POST "$API/__set?state=suspended&startedAgoMin=0&cooldown=$future" >/dev/null
before="$(n_events)"
out4="$(run_keeper 470 0.05)"; echo "$out4" | sed 's/^/      /'
after="$(n_events)"
[ "$before" = "$after" ] && ok "冷却期内没有动作" || bad "冷却期内仍然动了"
echo "$out4" | grep -q "冷却中" && ok "日志说明在冷却" || bad "日志未说明冷却"

echo
echo "结果：PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
