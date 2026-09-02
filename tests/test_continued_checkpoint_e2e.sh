#!/bin/sh
set -eu

checkpoint=${1:?usage: $0 10592-token-checkpoint.kv}
url=${DS4_E2E_URL:-http://127.0.0.1:8002}
log=${DS4_E2E_LOG:-/Users/jack/.dsv4/dsv4.log}
kv_dir=${DS4_E2E_KV_DIR:-/Users/jack/.dsv4/kv}
append_tokens=${DS4_E2E_APPEND_TOKENS:-7000}
expected_sha=9410c9303ecb1ee98be3dec1f594124c0d520359

read_uint() {
    od -An -j "$2" -N"$3" -tu"$3" "$1" | tr -d '[:space:]'
}

[ "$(read_uint "$checkpoint" 8 4)" = 10592 ]
[ "$(read_uint "$checkpoint" 5 1)" = 1 ]
[ "$(read_uint "$checkpoint" 7 1)" = 3 ]
[ "$(read_uint "$checkpoint" 48 4)" = 46403 ]

work=$(mktemp -d "${TMPDIR:-/tmp}/ds4-continued-e2e.XXXXXX")
trap 'rm -rf "$work"' EXIT INT HUP TERM
dd if="$checkpoint" of="$work/stored.txt" bs=1 skip=52 count=46403 2>/dev/null
[ "$(shasum -a 1 "$work/stored.txt" | cut -d ' ' -f1)" = "$expected_sha" ]

WORK="$work" uv run python - <<'PY'
import os
from pathlib import Path

w = Path(os.environ["WORK"])
t = (w / "stored.txt").read_text()
a = t.index("\n<tools>\n\n") + len("\n<tools>\n\n")
b = t.index("\n\n\n</tools>\n\n", a)
m = t.rindex("<|system|>") + len("<|system|>")
(w / "tools.stream.json").write_text(t[a:b])
(w / "system.txt").write_text(t[m:])
PY
jq -s '.' "$work/tools.stream.json" >"$work/tools.json"
[ "$(jq length "$work/tools.json")" = 39 ]
[ "$(jq -r '.[0].name' "$work/tools.json")" = read ]
[ "$(jq -r '.[-1].name' "$work/tools.json")" = sifttext_duplicate_node ]
[ "$(wc -c <"$work/system.txt" | tr -d ' ')" = 17565 ]

run_pass() {
    pass=$1
    nonce="run-$(date +%s)-$$-$pass"
    { printf '%s' "$nonce"; awk -v n="$append_tokens" 'BEGIN { for (i = 0; i < n; i++) printf " checkpoint" }'; } >"$work/user-$pass.txt"
    jq -n --slurpfile tools "$work/tools.json" \
        --rawfile system "$work/system.txt" --rawfile user "$work/user-$pass.txt" \
        '{model:"glm-5.3-flash",reasoning_effort:"max",
          messages:[{role:"system",content:$system},{role:"user",content:$user}],
          tools:$tools[0],max_tokens:1,temperature:0,stream:false}' \
        >"$work/request-$pass.json"

    for i in 1 2 3 4; do
        jq -nc --arg p "cache-displacer-$pass-$i-$(date +%s%N)" \
            '{model:"glm-5.3-flash",messages:[{role:"user",content:$p}],
              max_tokens:32,temperature:0,ignore_eos:true,thinking:false,stream:false}' |
            curl --max-time 120 -fsS "$url/v1/chat/completions" \
                -H 'content-type: application/json' --data-binary @- \
                >"$work/displacer-$pass-$i.json"
    done

    first_line=$(wc -l <"$log" | tr -d ' ')
    started_at=$(date +%s)
    curl -fsS "$url/v1/chat/completions" -H 'content-type: application/json' \
        --data-binary @"$work/request-$pass.json" >"$work/response-$pass.json"
    tail -n "+$((first_line + 1))" "$log" >"$work/log-$pass"
    run_log=$work/log-$pass

    hit_count=$(grep -Ec "kv cache hit text tokens=10592 .*file=.*/$expected_sha\\.kv$" "$run_log" || true)
    [ "$hit_count" = 1 ] || { echo "pass $pass: expected exactly one 10592 source hit, got $hit_count" >&2; exit 1; }
    hit_line=$(grep -nE "kv cache hit text tokens=10592 .*file=.*/$expected_sha\\.kv$" "$run_log" | cut -d: -f1)

    ctx=$(sed -n 's/.*chat ctx=\(10592\.\.[0-9][0-9]*:[0-9][0-9]*\) TOOLS prompt start$/\1/p' "$run_log")
    [ "$(printf '%s\n' "$ctx" | grep -c . || true)" = 1 ] || { echo "pass $pass: expected exactly one measured prompt start" >&2; exit 1; }
    start_line=$(grep -nF "chat ctx=$ctx TOOLS prompt start" "$run_log" | cut -d: -f1)

    slice=$(grep -nF "chat ctx=$ctx TOOLS prefill chunk " "$run_log" | head -1)
    slice_line=${slice%%:*}
    slice_tokens=$(printf '%s\n' "$slice" | sed 's|.* prefill chunk \([0-9][0-9]*\)/.*|\1|')
    [ "$((10592 + slice_tokens))" = 12288 ] || { echo "pass $pass: first slice did not end at 12288" >&2; exit 1; }

    for tokens in 12288 16384; do
        count=$(grep -c "kv cache stored tokens=$tokens .*reason=continued " "$run_log" || true)
        [ "$count" = 1 ] || { echo "pass $pass: expected one continued $tokens store, got $count" >&2; exit 1; }
    done
    store_12288_line=$(grep -n 'kv cache stored tokens=12288 .*reason=continued ' "$run_log" | cut -d: -f1)
    store_16384_line=$(grep -n 'kv cache stored tokens=16384 .*reason=continued ' "$run_log" | cut -d: -f1)

    finish=$(grep -nF "chat ctx=$ctx gen=" "$run_log" | grep ' finish=' || true)
    [ "$(printf '%s\n' "$finish" | grep -c . || true)" = 1 ] || { echo "pass $pass: expected exactly one measured finish" >&2; exit 1; }
    finish_line=${finish%%:*}
    [ "$hit_line" -lt "$start_line" ] && [ "$start_line" -lt "$slice_line" ] && \
        [ "$slice_line" -lt "$store_12288_line" ] && [ "$store_12288_line" -lt "$store_16384_line" ] && \
        [ "$store_16384_line" -lt "$finish_line" ] || { echo "pass $pass: required log events out of order" >&2; exit 1; }

    if grep -q 'reason=continued because live checkpoint is at' "$run_log"; then
        echo "pass $pass: continued checkpoint publication was skipped" >&2
        exit 1
    fi

    found=false
    for file in "$kv_dir"/*.kv; do
        [ -e "$file" ] || continue
        [ "$(read_uint "$file" 8 4)" = 16384 ] || continue
        [ "$(read_uint "$file" 5 1)" = 2 ] || continue
        [ "$(read_uint "$file" 7 1)" = 3 ] || continue
        [ "$(read_uint "$file" 24 8)" -ge "$started_at" ] || continue
        found=true
        break
    done
    "$found" || { echo "pass $pass: new continued 16384 checkpoint missing" >&2; exit 1; }
    printf 'pass %s: 10592 -> 12288 -> 16384 continued checkpoints verified\n' "$pass"
}

run_pass 1
run_pass 2
