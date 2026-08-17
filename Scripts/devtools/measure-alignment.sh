#!/usr/bin/env bash
# Counts the lines the model reports as changed against the lines git reports, over the modified
# files of another repository. M11-B measured this with an untracked script; this is the same
# instrument, kept where it can be run again.
#
#   Scripts/devtools/measure-alignment.sh ../5bonsai__website__nextjs [extra emit-structural args]
#
# `false`  — a line the model stars on the new side that `git diff -U0` says is untouched.
# `missed` — a line git removes that the old side does not mark.
set -euo pipefail

corpus=${1:?usage: measure-alignment.sh <repo> [emit-structural extra args]}
shift || true
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swift build --package-path "$here" >/dev/null
verify="$here/.build/debug/diffscope-verify"

total_false=0 total_missed=0 total_reported=0 total_segments=0

# Lines a side of `git diff -U0` touches, as bare line numbers.
git_lines() { # <file> <+|->
  git -C "$corpus" diff -U0 -- "$1" | awk -v side="$2" '
    /^@@/ {
      match($0, "\\" side "[0-9]+(,[0-9]+)?")
      spec = substr($0, RSTART + 1, RLENGTH - 1)
      split(spec, parts, ",")
      count = (length(parts) > 1) ? parts[2] : 1
      for (i = 0; i < count; i++) print parts[1] + i
    }'
}

# Lines the model stars, from the `*  12 | …` column of --emit-structural.
model_lines() { # <side marker> <emit output file>
  awk -v want="$1" '
    $0 ~ /^=== (OLD|NEW) ===$/ { side = ($0 ~ /OLD/) ? "OLD" : "NEW"; next }
    side == want && /^\*/ { print $2 }' "$2"
}

while read -r file; do
  case "$file" in *.tsx|*.ts|*.jsx|*.js) ;; *) continue ;; esac
  git -C "$corpus" show "HEAD:$file" > "$work/old" 2>/dev/null || continue
  cp "$corpus/$file" "$work/new"
  "$verify" --emit-structural "$work/old" "$work/new" "$file" "$@" > "$work/out" 2>/dev/null

  comm -13 <(git_lines "$file" '+' | sort -u) <(model_lines NEW "$work/out" | sort -u) > "$work/false"
  comm -23 <(git_lines "$file" '-' | sort -u) <(model_lines OLD "$work/out" | sort -u) > "$work/missed"

  f=$(wc -l < "$work/false"); m=$(wc -l < "$work/missed")
  reported=$(model_lines NEW "$work/out" | wc -l)
  segments=$(grep -o '⟦' "$work/out" | wc -l)
  printf '%-56s reported %4d  false %3d  missed %3d  segments %4d\n' \
    "$file" "$reported" "$f" "$m" "$segments"
  total_false=$((total_false + f)); total_missed=$((total_missed + m))
  total_reported=$((total_reported + reported)); total_segments=$((total_segments + segments))
done < <(git -C "$corpus" diff --name-only)

printf '\n%-56s reported %4d  false %3d  missed %3d  segments %4d\n' \
  "TOTAL" "$total_reported" "$total_false" "$total_missed" "$total_segments"
