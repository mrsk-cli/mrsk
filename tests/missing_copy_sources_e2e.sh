#!/bin/sh
set -eu

: "${MRSK_BIN:?MRSK_BIN is required}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

export HOME="$tmp/home"
project="$tmp/provans.info"
mkdir -p "$HOME/.mrsk" "$project/main"

git -C "$project/main" init -q -b main
git -C "$project/main" config user.name Test
git -C "$project/main" config user.email test@example.com
printf '.env\n' > "$project/main/.gitignore"
printf 'secret\n' > "$project/main/.env"
git -C "$project/main" add .gitignore
git -C "$project/main" commit -qm initial

cat > "$HOME/.mrsk/config.yml" <<EOF
projects:
  - project_name: provans.info
    project_root: "$project/main"
    main_branch: main
    copy_files:
      - .env
    copy_folders:
      - node_modules
EOF

"$MRSK_BIN" provans.info new PROV-65 2>"$tmp/missing-folder.err"
escape=$(printf '\033')
grep -Fq "${escape}[33mmrsk: warning: copy folder does not exist: $project/main/node_modules${escape}[0m" \
    "$tmp/missing-folder.err"
test -d "$project/PROV-65"
test "$(cat "$project/PROV-65/.env")" = secret
"$MRSK_BIN" provans.info remove PROV-65

cat > "$HOME/.mrsk/config.yml" <<EOF
project_root: "$project/main"
main_branch: main
copy_files:
  - missing.env
EOF

if "$MRSK_BIN" new PROV-66 >"$tmp/missing-file.out" 2>&1; then
    echo "expected a missing copy file to fail" >&2
    exit 1
fi
grep -Fq "mrsk: copy source does not exist: $project/main/missing.env" \
    "$tmp/missing-file.out"
test ! -e "$project/PROV-66"

echo "missing copy sources e2e: ok"
