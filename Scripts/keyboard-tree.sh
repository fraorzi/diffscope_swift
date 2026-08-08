#!/bin/bash
# Builds the working tree the definition of done is stated against: 63 changed files, grouped, in a
# real Git repository (M8-J, `18-version-one-scope.md` §"Definition of done" 6).
#
# `mailingi-2025` had 63 changed files on the day DEC-033 was written and has 3 today, so the shape
# the claim is about no longer exists anywhere to point at. It is constructed here instead, the way
# `20-implementation-plan.md` §6 constructs the fixtures that cannot occur locally.
#
# **This script writes; the application does not.** R-8 is a statement about the Git operations
# `diffscope-app` itself can issue, and it is unchanged by a shell script building a fixture — the
# same separation DEC-053 draws between the application acting on its own and a user typing in a
# shell. Nothing here runs inside the application.

set -euo pipefail

DIR="${1:?usage: keyboard-tree.sh <directory>}"
rm -rf "$DIR"
mkdir -p "$DIR"
cd "$DIR"

git init -q .
git config user.email fixture@diffscope.local
git config user.name "DiffScope Fixture"
git config commit.gpgsign false

# Nine directories, so the list groups (DEC-033 as amended groups by parent directory where no
# workspace is declared) and the walk has headers to step past. Depth 5 is the corpus's shape.
for package in 0 1 2 3 4 5 6 7 8; do
  mkdir -p "packages/app-$package/src/components/nested"
done

# A committed baseline for every file that will be modified or deleted. An untracked file has no
# baseline by definition, which is the point of including one.
index=0
while [ $index -lt 56 ]; do
  package=$((index % 9))
  path="packages/app-$package/src/components/nested/File$index.tsx"
  cat > "$path" <<TSX
export function File$index({ label }: { label: string }) {
  return (
    <section className="file-$index">
      <header>{label}</header>
      <p>line one</p>
      <p>line two</p>
    </section>
  );
}
TSX
  index=$((index + 1))
done
git add -A
git commit -qm "baseline"

# 52 modified, 4 deleted, 4 added, 3 untracked = 63 changed paths in the all-local scope.
index=0
while [ $index -lt 52 ]; do
  package=$((index % 9))
  path="packages/app-$package/src/components/nested/File$index.tsx"
  # A wrapper change, which is the case this product exists for, rather than an appended line.
  sed -i '' "s|<section className=\"file-$index\">|<section className=\"file-$index\" data-changed>|" "$path"
  index=$((index + 1))
done

index=52
while [ $index -lt 56 ]; do
  package=$((index % 9))
  rm "packages/app-$package/src/components/nested/File$index.tsx"
  index=$((index + 1))
done

index=56
while [ $index -lt 60 ]; do
  package=$((index % 9))
  path="packages/app-$package/src/components/nested/File$index.tsx"
  printf 'export const added%s = %s;\n' "$index" "$index" > "$path"
  git add "$path"
  index=$((index + 1))
done

index=60
while [ $index -lt 63 ]; do
  package=$((index % 9))
  printf 'export const untracked%s = %s;\n' "$index" "$index" \
    > "packages/app-$package/src/components/nested/File$index.tsx"
  index=$((index + 1))
done

echo "$DIR"
