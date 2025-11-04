#!/usr/bin/env bash
set -e

# === CONFIG ===
REPO_URL="https://gitlab.freedesktop.org/mesa/mesa.git"
GOOD_COMMIT="47619ef538"
BAD_COMMIT="93f24f0bd0"
OUTPUT_FILE="commits_between.txt"

echo "==> Clonando Mesa (completo para garantir histórico)..."
git clone "$REPO_URL" mesa_repo
cd mesa_repo

echo "==> Buscando commits..."
git fetch origin $GOOD_COMMIT $BAD_COMMIT

echo "==> Gerando lista entre $GOOD_COMMIT e $BAD_COMMIT..."
git log --oneline ${GOOD_COMMIT}..${BAD_COMMIT} > "../$OUTPUT_FILE"

cd ..
echo "==> Arquivo gerado:"
ls -lh "$OUTPUT_FILE"
