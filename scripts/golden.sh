#!/bin/zsh
# The plugin against in-process MLXServeEngine: seeded jobs called on the signed bundle the way Gaea calls them
# (gaea-plugin-check: launch under the launch requirement, configure, prepare, run) and through boogu-inproc with the
# lane configuration and request the worker builds, on this package's dependency resolution. Each pair must be byte
# for byte the same, or pixel for pixel when the bytes differ.
#
#   scripts/golden.sh <out-dir>     (after scripts/build-plugin.sh and `swift build -c release --product boogu-inproc`)
#
# Cases: Boogu (Base) bf16 generate, Boogu Turbo int8 generate, and Boogu Edit bf16 on fixtures/fox-256.png with no size
# asked, so the package draws it at its 768².
set -uo pipefail
ROOT=${0:A:h:h}
cd $ROOT
OUT=${1:?out dir}; mkdir -p $OUT
B=$ROOT/dist/boogu.gaeaplugin
MODELS=${CHECK_MODELS_ROOT:-$HOME/Library/Application Support/MLXEngine/Models}
BIN=$(xcrun swift build -c release --show-bin-path)
CHECK=$BIN/gaea-plugin-check; INPROC=$BIN/boogu-inproc
FOX=$ROOT/scripts/fixtures/fox-256.png
PIXDIFF=$OUT/pixdiff; swiftc -O -o $PIXDIFF $ROOT/scripts/pixdiff.swift
LOG=$OUT/golden.log; : > $LOG
pass=0; fail=0
say() { print -r -- "$*" | tee -a $LOG }
say "# Boogu golden check $(date -u +%FT%TZ): $(python3 -c "import json; m=json.load(open('$B/Contents/Resources/manifest.json')); print(m['id'], m['version'])")"

# compare <name> <model> <lane> <operation> <text> <params json> <inproc args...>
compare() {
  local name=$1 model=$2 lane=$3 operation=$4 text=$5 params=$6; shift 6
  local inputs=(); [[ $operation == image.edit ]] && inputs=(--input "images=$FOX")
  $CHECK $B --operation $operation --model $model --lane $lane --params $params --seed 7 --text "$text" $inputs \
    --models-root "$MODELS" --budget 64000000000 --timeout 1800 --session $OUT/$name.gpp > $OUT/$name-gpp.log 2>&1
  local file=$(grep -o '"path":"[^"]*"' $OUT/$name-gpp.log | tail -1 | sed 's/"path":"//; s/"$//; s/\\\//\//g')
  [[ -n $file && -f $file ]] && cp $file $OUT/$name-gpp.png
  $INPROC --model $model --lane $lane --seed 7 --models-root "$MODELS" --out $OUT/$name-inproc.png "$@" > $OUT/$name-inproc.json 2>> $LOG
  if [[ ! -f $OUT/$name-gpp.png ]]; then fail=$((fail+1)); say "FAIL  $name: no output over GPP ($(grep -E 'FAIL|error' $OUT/$name-gpp.log | tail -1))"; return; fi
  if [[ ! -f $OUT/$name-inproc.png ]]; then fail=$((fail+1)); say "FAIL  $name: no in-process output"; return; fi
  local a=$(shasum -a 256 $OUT/$name-gpp.png | cut -c1-16) b=$(shasum -a 256 $OUT/$name-inproc.png | cut -c1-16)
  local ran=$(grep -o 'ran in [0-9.]* s' $OUT/$name-gpp.log | head -1)
  local effective=$(grep -o '"effective":{[^}]*}[^}]*}' $OUT/$name-gpp.log | head -1)
  if [[ $a == $b ]]; then pass=$((pass+1)); say "PASS  $name ($model $lane): byte-identical, sha256 $a…; over GPP $ran, $effective; in-process $(cat $OUT/$name-inproc.json)"
  elif $PIXDIFF $OUT/$name-gpp.png $OUT/$name-inproc.png >> $LOG 2>&1; then pass=$((pass+1)); say "PASS  $name: pixel-identical (bytes $a… / $b…)"
  else fail=$((fail+1)); say "FAIL  $name: differs ($a… / $b…): $(tail -1 $LOG)"; fi
}

PROMPT="a lighthouse on a rocky coast at dusk, warm light in the windows, photorealistic"
compare generate boogu bf16 image.generate "prompt=$PROMPT" '{"size":{"width":768,"height":768},"x-boogu.steps":12}' \
  --prompt "$PROMPT" --width 768 --height 768 --steps 12
compare turbo boogu-turbo int8 image.generate "prompt=$PROMPT" '{"size":{"width":1024,"height":1024}}' \
  --prompt "$PROMPT" --width 1024 --height 1024
EDIT="make it night with falling snow"
compare edit boogu-edit bf16 image.edit "instruction=$EDIT" '{"x-boogu.steps":20}' --prompt "$EDIT" --steps 20 --image $FOX

say "== $pass passed, $fail failed"
exit $(( fail > 0 ))
