#!/bin/bash
# models/case.spthy の lemma を 1 本ずつ実行し、結果を <ファイル名>_out.txt（タブ区切り）にまとめる
#   ./run.sh [ファイル] [制約なしの制限秒] [探索制約つきの制限秒]
#   環境変数: MODE=default|lkgt  ONLY=<lemma名の先頭>  RESUME=1  DERIVCHECK=<秒、0で無効>
# exists-trace は探索制約つきで回すので、verified だけを採用する（falsified は「トレースなし」と表示）

f=${1:-../models/case.spthy}; t1=${2:-1800}; t2=${3:-900}
MODE=${MODE:-all}
EXP_RE='^(expiry_|no_commit_|lkgt_|attack_expired_)|_after_expiry_'
DERIVCHECK=${DERIVCHECK:-60}

[ -f "$f" ] || { echo "ファイルがありません: $f"; exit 1; }
command -v tamarin-prover >/dev/null || { echo "tamarin-prover が見つかりません（PATH を確認）"; exit 1; }
export LANG=C.UTF-8 LC_ALL=C.UTF-8

out=$(basename "$f" .spthy)_out.txt
if [ "$RESUME" = 1 ] && [ -f "$out" ]; then
  awk -F'\t' -v only="$ONLY" 'NR==1 || $4 ~ /^(verified|falsified)$/ || (only != "" && index($1, only) != 1)' "$out" > "$out.tmp" && mv "$out.tmp" "$out"
else
  printf 'lemma\tclock\tflags\tresult\tsteps\tsec\n' > "$out"
fi

lemmas=$(grep -oP '^lemma \K[A-Za-z0-9_]+' "$f")
is_exists(){ grep -A2 -E "^lemma $1( |:|\[)" "$f" | grep -q 'exists-trace'; }
is_exp(){ echo "$1" | grep -Eq "$EXP_RE"; }
done_already(){ awk -F'\t' -v l="$1" -v c="$2" '$1==l && $2==c {f=1} END{exit !f}' "$out"; }

prove(){
  local l=$1 t=$2; shift 2
  local line
  line=$(timeout "$t" tamarin-prover --derivcheck-timeout="$DERIVCHECK" "$@" --prove="$l" "$f" 2>&1 | grep -E "^\s+$l \(" | head -1)
  RES=$(echo "$line" | grep -oE 'verified|falsified|analysis incomplete' | head -1); RES=${RES:-TIMEOUT}
  STEPS=$(echo "$line" | grep -oP '\(\K[0-9]+(?= steps\))')
}

record(){ printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "${3:-(なし)}" "$4" "$5" "$6" | tee -a "$out"; }

run_one(){
  local l=$1 clock=$2 s base search flags
  s=$(date +%s)
  [ "$clock" = LKGT ] && base="-D=LKGT" || base=""
  if is_exp "$l"; then search="-D=SEARCH_EXP"; else search="-D=SEARCH"; fi

  if is_exists "$l"; then
    flags="$base $search"; prove "$l" "$t2" $flags
    [ "$RES" = falsified ] && RES="トレースなし（探索制約の中で）"
  elif [ "$clock" = LKGT ]; then
    flags="$base $search"; prove "$l" "$t2" $flags
    if [ "$RES" != falsified ]; then
      flags="$base"; prove "$l" "$t2" $flags
      [ "$RES" = TIMEOUT ] && RES="TIMEOUT（証明も反例も出ず）"
    fi
  else
    flags="$base"; prove "$l" "$t1" $flags
    if [ "$RES" != verified ] && [ "$RES" != falsified ]; then
      flags="$base $search"; prove "$l" "$t2" $flags
      case "$RES" in
        verified) RES="不確定（探索制約の中では成立。制約なしは時間切れ）"; STEPS="" ;;
        TIMEOUT)  RES="TIMEOUT（証明も反例も出ず）" ;;
      esac
    fi
  fi
  record "$l" "$clock" "$(echo $flags)" "$RES" "$STEPS" "$(( $(date +%s)-s ))"
}

want(){ [ -z "$ONLY" ] && return 0; case "$1" in "$ONLY"*) return 0;; *) return 1;; esac; }

if [ "$MODE" = all ] || [ "$MODE" = default ]; then
  echo "== 時計が正確なモデル =="
  for l in $lemmas; do
    case "$l" in lkgt_*) continue;; esac
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
