#!/usr/bin/env bash
# Extracts real (before, after) file pairs from the history of other repositories, so the diff
# presentation can be measured against many changes rather than one.
#
#   Scripts/devtools/build-corpus.sh corpus ../a__nextjs ../b__next ...
#
# One directory per pair, holding `before.<ext>`, `after.<ext>` and `meta.json`. `meta.json` carries
# the repository, the commit, the path, and the line numbers `git diff -U0` touches on each side —
# the reference every measurement in this series compares the model against.
#
# Filters: source extensions only, modifications only (an add or a delete has nothing to align),
# nothing above 512 KB, nothing generated or minified, and a pair whose two blobs have been seen
# together before is dropped — the same formatting sweep landing in ten repositories would otherwise
# decide the taxonomy on its own.
set -euo pipefail

out=${1:?usage: build-corpus.sh <out-dir> <repo> [repo ...]}
shift
commits=${CORPUS_COMMITS:-150}
maxbytes=${CORPUS_MAX_BYTES:-524288}

mkdir -p "$out"
seen="$out/.seen"
: > "$seen"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

kept=0
skipped_generated=0
skipped_large=0
skipped_duplicate=0

for repo in "$@"; do
  name=$(basename "$repo")
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "  not a repository: $repo"; continue; }
  repo_kept=0

  while read -r sha; do
    while IFS=$'\t' read -r status path; do
      [ "$status" = "M" ] || continue
      case "$path" in
        *.ts|*.tsx|*.js|*.jsx) ;;
        *) continue ;;
      esac
      case "$path" in
        */node_modules/*|*/.next/*|*/dist/*|*/build/*|*.min.js|*.d.ts|*/generated/*|*.config.js) continue ;;
      esac

      git -C "$repo" show "$sha^:$path" > "$work/before" 2>/dev/null || continue
      git -C "$repo" show "$sha:$path"  > "$work/after"  2>/dev/null || continue

      before_bytes=$(wc -c < "$work/before" | tr -d ' ')
      after_bytes=$(wc -c < "$work/after" | tr -d ' ')
      if [ "$before_bytes" -gt "$maxbytes" ] || [ "$after_bytes" -gt "$maxbytes" ]; then
        skipped_large=$((skipped_large + 1)); continue
      fi
      # Minified or generated: one very long line is the shape both take, and neither is a change a
      # person wrote or reads.
      longest=$(awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$work/after")
      if [ "$longest" -gt 2000 ]; then skipped_generated=$((skipped_generated + 1)); continue; fi

      pair=$(shasum -a 256 "$work/before" "$work/after" | awk '{ printf "%s", $1 }')
      if grep -q "^$pair$" "$seen"; then skipped_duplicate=$((skipped_duplicate + 1)); continue; fi
      echo "$pair" >> "$seen"

      ext=${path##*.}
      slug=$(printf '%s' "$path" | tr '/' '_' | tr -c 'A-Za-z0-9._-' '_')
      dir="$out/$name/${sha:0:12}__$slug"
      mkdir -p "$dir"
      cp "$work/before" "$dir/before.$ext"
      cp "$work/after" "$dir/after.$ext"

      # `git diff --no-index` runs on the extracted files, so the reference is a function of the
      # pair alone — the same two blobs measure identically wherever they came from.
      git diff --no-index -U0 -- "$dir/before.$ext" "$dir/after.$ext" > "$work/diff" 2>/dev/null || true
      old_lines=$(awk '/^@@/ { match($0, "-[0-9]+(,[0-9]+)?"); s = substr($0, RSTART + 1, RLENGTH - 1);
                  split(s, p, ","); n = (length(p) > 1) ? p[2] : 1; for (i = 0; i < n; i++) print p[1] + i }' "$work/diff" \
                  | sort -un | paste -sd, -)
      new_lines=$(awk '/^@@/ { match($0, "\\+[0-9]+(,[0-9]+)?"); s = substr($0, RSTART + 1, RLENGTH - 1);
                  split(s, p, ","); n = (length(p) > 1) ? p[2] : 1; for (i = 0; i < n; i++) print p[1] + i }' "$work/diff" \
                  | sort -un | paste -sd, -)

      python3 - "$dir/meta.json" "$name" "$sha" "$path" "$ext" "$before_bytes" "$after_bytes" \
               "${old_lines:-}" "${new_lines:-}" <<'PY'
import json, sys
path, repo, sha, file, ext, before, after, old_lines, new_lines = sys.argv[1:10]
numbers = lambda text: [int(n) for n in text.split(",") if n]
json.dump({
    "repo": repo, "commit": sha, "path": file, "ext": ext,
    "beforeBytes": int(before), "afterBytes": int(after),
    "gitOldLines": numbers(old_lines), "gitNewLines": numbers(new_lines),
}, open(path, "w"), indent=2, sort_keys=True)
PY
      kept=$((kept + 1)); repo_kept=$((repo_kept + 1))
    done < <(git -C "$repo" show --name-status --format= -M "$sha" 2>/dev/null | grep -E '^M' || true)
  done < <(git -C "$repo" rev-list --no-merges -n "$commits" HEAD)

  printf '  %-46s %4d pairs\n' "$name" "$repo_kept"
done

printf '\n  %d pairs kept  (%d generated, %d large, %d duplicate skipped)\n' \
  "$kept" "$skipped_generated" "$skipped_large" "$skipped_duplicate"
