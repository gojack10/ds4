#!/bin/sh
set -eu

checkpoint=${1:?usage: $0 10592-token-checkpoint.kv}
url=${DS4_E2E_URL:-http://127.0.0.1:8002}
log=${DS4_E2E_LOG:-/Users/jack/.dsv4/dsv4.log}
kv_dir=${DS4_E2E_KV_DIR:-/Users/jack/.dsv4/kv}
append_tokens=${DS4_E2E_APPEND_TOKENS:-7000}

read_u32() {
    od -An -j "$2" -N4 -tu4 "$1" | tr -d '[:space:]'
}

[ "$(read_u32 "$checkpoint" 8)" = 10592 ] || {
    echo "checkpoint must contain 10592 tokens: $checkpoint" >&2
    exit 1
}

work=$(mktemp -d "${TMPDIR:-/tmp}/ds4-continued-e2e.XXXXXX")
trap 'rm -rf "$work"' EXIT INT HUP TERM
text_bytes=$(read_u32 "$checkpoint" 48)
dd if="$checkpoint" of="$work/prompt" bs=1 skip=52 count="$text_bytes" 2>/dev/null
awk -v n="$append_tokens" 'BEGIN { for (i = 0; i < n; i++) printf " checkpoint" }' >>"$work/prompt"
jq -Rs '{model:"glm-5.3-flash",prompt:.,max_tokens:1,temperature:0,stream:false}' \
    <"$work/prompt" >"$work/request.json"

first_line=$(wc -l <"$log")
curl -fsS "$url/v1/completions" -H 'content-type: application/json' \
    --data-binary @"$work/request.json" >"$work/response.json"
tail -n "+$((first_line + 1))" "$log" >"$work/log"

grep -q 'kv cache hit text tokens=10592 ' "$work/log"
for tokens in 12288 16384; do
    grep -q "kv cache stored tokens=$tokens .*reason=continued " "$work/log"
    found=false
    for file in "$kv_dir"/*.kv; do
        [ "$(read_u32 "$file" 8)" = "$tokens" ] || continue
        [ "$(od -An -j5 -N1 -tu1 "$file" | tr -d '[:space:]')" = 2 ] || continue
        found=true
        break
    done
    "$found" || { echo "continued checkpoint file missing: $tokens" >&2; exit 1; }
done

if grep -q 'reason=continued because live checkpoint is at' "$work/log"; then
    echo "continued checkpoint publication was skipped" >&2
    exit 1
fi

printf 'published continued checkpoints from off-grid 10592: 12288 16384\n'
