#!/bin/sh
set -eu

: "${MRSK_BIN:?MRSK_BIN is required}"
: "${OCR_BIN:?OCR_BIN is required}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

# Keep the review offline: no LLM endpoint may leak in from the environment.
unset OCR_CONFIG_PATH OCR_LLM_URL OCR_LLM_TOKEN OCR_LLM_MODEL \
    ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL
export HOME="$tmp/home"
repo="$tmp/repo"
mkdir -p "$HOME" "$tmp/bin" "$repo"
ln -s "$OCR_BIN" "$tmp/bin/ocr"
PATH="$tmp/bin:$PATH"
export PATH

git -C "$repo" init -q -b main
git -C "$repo" config user.name Test
git -C "$repo" config user.email test@example.com
echo 'package main' > "$repo/a.go"
git -C "$repo" add a.go
git -C "$repo" commit -qm initial
git -C "$repo" switch -qc feature-auth
printf 'package main\n\nfunc f() int { return 1 }\n' > "$repo/a.go"
echo 'package main' > "$repo/b.go"
git -C "$repo" add a.go b.go
git -C "$repo" commit -qm feature
sha=$(git -C "$repo" rev-parse --short HEAD)
git -C "$repo" switch -q main

# --preview lists the files open-code-review would send to the LLM.
(cd "$repo" && "$MRSK_BIN" review --from main --to feature-auth --preview > "$tmp/range.out")
grep -q "Will review (2)" "$tmp/range.out"
grep -q "a.go" "$tmp/range.out"
grep -q "b.go" "$tmp/range.out"

(cd "$repo" && "$MRSK_BIN" review --commit "$sha" --preview > "$tmp/commit.out")
grep -q "Will review (2)" "$tmp/commit.out"

echo 'package main // work in progress' > "$repo/a.go"
(cd "$repo" && "$MRSK_BIN" review --preview > "$tmp/workspace.out")
grep -q "Will review (1)" "$tmp/workspace.out"
grep -q "a.go" "$tmp/workspace.out"

if (cd "$repo" && "$MRSK_BIN" review --commit "$sha" > "$tmp/unconfigured.out" 2>&1); then
    echo "expected review to fail without an LLM endpoint" >&2
    exit 1
fi
grep -q "no valid LLM endpoint configured" "$tmp/unconfigured.out"

if (cd "$repo" && PATH=/usr/bin:/bin "$MRSK_BIN" review > "$tmp/missing.out" 2>&1); then
    echo "expected review to fail without ocr installed" >&2
    exit 1
fi
grep -q "mrsk: cannot run ocr" "$tmp/missing.out"

echo "review e2e: ok"
