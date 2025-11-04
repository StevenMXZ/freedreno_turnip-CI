#!/usr/bin/env bash
set -e

# === CONFIG ===
REPO_URL="https://gitlab.freedesktop.org/mesa/mesa.git"
GOOD_COMMIT="47619ef538"
BAD_COMMIT="93f24f0bd0"
OUTPUT_FILE="commits_between.txt"

echo "Clonando Mesa..."
git clone --depth=1000 "$REPO_URL" mesa_repo
cd mesa_repo

echo "Listando commits entre $GOOD_COMMIT e $BAD_COMMIT..."
git fetch --all
git log --oneline ${GOOD_COMMIT}..${BAD_COMMIT} > "../$OUTPUT_FILE"

cd ..
echo "Arquivo gerado: $OUTPUT_FILE"
ls -lh "$OUTPUT_FILE"
