#!/bin/bash
# fixed_case4.spthy の lemma をすべて 1 本ずつ実行し、結果を results_<ファイル名>.tsv にまとめる。
#
# 使い方:
#   ./run.sh [ファイル=fixed_case4.spthy] [制約なしの制限秒=1800] [探索制約つきの制限秒=900]
#
#   MODE=default ./run.sh   時計が正確なモデルだけ回す
#   MODE=lkgt    ./run.sh   時計が遅れるモデル（-D=LKGT）の有効期限の lemma だけ回す
#   ONLY=tight_  ./run.sh   名前がその文字列で始まる lemma だけ回す
#   RESUME=1     ./run.sh   結果ファイルで verified / falsified が出ている行は飛ばし、残りだけ回す
#                           （ONLY と一緒に使うと、ONLY に合う行だけを取り直す）
#   JSON=0       ./run.sh   トレースの JSON を出力しない
#   TRACE_DIR=dir ./run.sh  JSON の出力先（既定: traces_<ファイル名>/）
#
# トレースの JSON（Tamarin の --output-json）
#   lemma ごとに <TRACE_DIR>/<lemma>__<exact|lkgt>.json に出力し、結果表の trace 列にパスを書く。
#   トレースが出るのは「exists-trace の verified（見つかった実行）」と「all-traces の falsified（反例）」。
#   all-traces の verified・TIMEOUT などトレースがないものは JSON を残さず、trace 列は「-」。
#   1 ファイル数 MB になるので、不要なら JSON=0 で止める。
#
# 回し方（lemma ごとに自動で選ぶ）
#   [時計が正確]
#     exists-trace（case_finished, tight_*）      : -D=SEARCH
#     exists-trace（有効期限: expiry_executable, attack_expired_key_*） : -D=SEARCH_EXP
#     all-traces                                  : 制約なし。終わらなければ探索制約つきで反例を探す
#   [時計が遅れる（-D=LKGT）] 有効期限の lemma（名前が EXP_RE に合うもの）だけ
#     exists-trace                                : -D=LKGT -D=SEARCH_EXP
#     all-traces                                  : まず -D=LKGT -D=SEARCH_EXP で反例を探し（falsified なら確定）、
#                                                   見つからなければ -D=LKGT だけで回す
#                                                   （どちらも探索制約つきの制限秒で切り上げる）
#
# 結果の読み方
#   探索制約（SEARCH / SEARCH_EXP）はトレースを絞るだけなので、
#     exists-trace の verified と all-traces の falsified は元のモデルでも成り立つ（採用する）。
#     all-traces の verified と exists-trace の falsified は証明にならない（「不確定」と表示する）。

f=${1:-fixed_case4.spthy}; t1=${2:-1800}; t2=${3:-900}
MODE=${MODE:-all}
EXP_RE='^(expiry_|no_commit_|lkgt_|attack_expired_)|_after_expiry_'     # 有効期限の lemma の名前
JSON=${JSON:-1}
TRACE_DIR=${TRACE_DIR:-traces_$(basename "$f" .spthy)}

[ -f "$f" ] || { echo "ファイルがありません: $f"; exit 1; }
command -v tamarin-prover >/dev/null || { echo "tamarin-prover が見つかりません（PATH を確認）"; exit 1; }
export LANG=C.UTF-8 LC_ALL=C.UTF-8

out=results_$(basename "$f" .spthy).tsv
if [ "$RESUME" = 1 ] && [ -f "$out" ]; then
  # 確定していない行（TIMEOUT・不確定）は消して取り直す
  # ONLY を付けたときは、その対象の行だけを消す（ほかの行はそのまま残す）
  awk -F'\t' -v only="$ONLY" 'NR==1 || $4 ~ /^(verified|falsified)$/ || (only != "" && index($1, only) != 1)' "$out" > "$out.tmp" && mv "$out.tmp" "$out"
else
  printf 'lemma\tclock\tflags\tresult\tsteps\tsec\ttrace\n' > "$out"
fi
[ "$JSON" = 1 ] && mkdir -p "$TRACE_DIR"

# lemma 名の一覧（#ifdef LKGT の中の lemma も含む）
lemmas=$(grep -oP '^lemma \K[A-Za-z0-9_]+' "$f")
is_exists(){ grep -A2 -E "^lemma $1( |:|\[)" "$f" | grep -q 'exists-trace'; }
is_exp(){ echo "$1" | grep -Eq "$EXP_RE"; }
done_already(){ awk -F'\t' -v l="$1" -v c="$2" '$1==l && $2==c {f=1} END{exit !f}' "$out"; }

# JSON にトレース（グラフ）が 1 つ以上入っているか
has_trace(){ python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("graphs") else 1)' "$1" 2>/dev/null; }

# prove <lemma> <制限秒> <フラグ...>  →  RES・STEPS・TRACE を設定
#   JSON は一時ファイルに書き、結果が出た回（verified / falsified）のものだけを $JSONFILE に残す
prove(){
  local l=$1 t=$2; shift 2
  local line tmp="" jopt=()
  if [ "$JSON" = 1 ]; then tmp="$JSONFILE.tmp"; rm -f "$tmp"; jopt=(--output-json="$tmp"); fi
  line=$(timeout "$t" tamarin-prover --derivcheck-timeout=0 "$@" "${jopt[@]}" --prove="$l" "$f" 2>&1 | grep -E "^\s+$l \(" | head -1)
  RES=$(echo "$line" | grep -oE 'verified|falsified|analysis incomplete' | head -1); RES=${RES:-TIMEOUT}
  STEPS=$(echo "$line" | grep -oP '\(\K[0-9]+(?= steps\))')
  if [ -n "$tmp" ]; then
    if { [ "$RES" = verified ] || [ "$RES" = falsified ]; } && [ -s "$tmp" ] && has_trace "$tmp"; then
      mv "$tmp" "$JSONFILE"; TRACE="$JSONFILE"
    else
      rm -f "$tmp"
      # 結果が出たのにトレースがない（all-traces の verified など）→ 前の回の JSON も消す
      { [ "$RES" = verified ] || [ "$RES" = falsified ]; } && rm -f "$JSONFILE"
      [ -f "$JSONFILE" ] && TRACE="$JSONFILE" || TRACE="-"
    fi
  fi
}

record(){ printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "${3:-(なし)}" "$4" "$5" "$6" "$7" | tee -a "$out"; }

# run_one <lemma> <clock: 正確|LKGT>
run_one(){
  local l=$1 clock=$2 s base search flags
  s=$(date +%s)
  TRACE="-"
  if [ "$clock" = LKGT ]; then JSONFILE="$TRACE_DIR/${l}__lkgt.json"; else JSONFILE="$TRACE_DIR/${l}__exact.json"; fi
  rm -f "$JSONFILE"
  [ "$clock" = LKGT ] && base="-D=LKGT" || base=""
  if is_exp "$l"; then search="-D=SEARCH_EXP"; else search="-D=SEARCH"; fi

  if is_exists "$l"; then
    # exists-trace: 探索制約つきで回す。verified なら確定、falsified は「制約の中では見つからない」だけ
    flags="$base $search"; prove "$l" "$t2" $flags
    [ "$RES" = falsified ] && RES="トレースなし（探索制約の中で）"
  elif [ "$clock" = LKGT ]; then
    # all-traces（LKGT）: 先に探索制約つきで反例を探す（falsified なら確定）。
    # 見つからなければ制約なしで回す（証明できるものは数秒で終わるので、どちらも t2 で切り上げる）
    flags="$base $search"; prove "$l" "$t2" $flags
    if [ "$RES" != falsified ]; then
      flags="$base"; prove "$l" "$t2" $flags
      [ "$RES" = TIMEOUT ] && RES="TIMEOUT（証明も反例も出ず）"
    fi
  else
    # all-traces（時計が正確）: 制約なしで証明する。終わらなければ探索制約つきで反例を探す
    flags="$base"; prove "$l" "$t1" $flags
    if [ "$RES" != verified ] && [ "$RES" != falsified ]; then
      flags="$base $search"; prove "$l" "$t2" $flags
      case "$RES" in
        verified) RES="不確定（探索制約の中では成立。制約なしは時間切れ）"; STEPS="" ;;
        TIMEOUT)  RES="TIMEOUT（証明も反例も出ず）" ;;
      esac
    fi
  fi
  [ "$JSON" = 1 ] || TRACE="-"
  record "$l" "$clock" "$(echo $flags)" "$RES" "$STEPS" "$(( $(date +%s)-s ))" "$TRACE"
}

want(){ [ -z "$ONLY" ] && return 0; case "$1" in "$ONLY"*) return 0;; *) return 1;; esac; }

if [ "$MODE" = all ] || [ "$MODE" = default ]; then
  echo "== 時計が正確なモデル =="
  for l in $lemmas; do
    case "$l" in lkgt_*) continue;; esac          # LKGT 専用の lemma は既定のモデルにない
    want "$l" || continue
    done_already "$l" 正確 && continue
    run_one "$l" 正確
  done
fi

if [ "$MODE" = all ] || [ "$MODE" = lkgt ]; then
  echo "== 時計が遅れるモデル（-D=LKGT）: 有効期限の lemma =="
  for l in $lemmas; do
    is_exp "$l" || continue
    want "$l" || continue
    done_already "$l" LKGT && continue
    run_one "$l" LKGT
  done
fi

echo "結果: $out"
[ "$JSON" = 1 ] && echo "トレース: $TRACE_DIR/"