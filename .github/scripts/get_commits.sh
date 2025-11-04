#!/usr/bin/env bash
set -e

# === CONFIG ===
REPO_URL="https://gitlab.freedesktop.org/mesa/mesa.git"
GOOD_COMMIT="47619ef5"
BAD_COMMIT="93f24f0b"
OUTPUT_ALL="commits_between.txt"
OUTPUT_FILTERED="suspects.txt"

echo "==> Clonando Mesa (histórico completo, pode demorar um pouco)..."
git clone "$REPO_URL" mesa_repo
cd mesa_repo

echo "==> Buscando commits específicos..."
git fetch origin $GOOD_COMMIT $BAD_COMMIT || echo "Aviso: refs não encontradas explicitamente, prosseguindo com log..."

echo "==> Gerando lista completa entre $GOOD_COMMIT e $BAD_COMMIT..."
git log --oneline ${GOOD_COMMIT}..${BAD_COMMIT} > "../$OUTPUT_ALL"

cd ..

echo "==> Filtrando commits suspeitos (timeline, submit, fence, flush, gmem, queue, sync)..."
grep -iE 'turnip|timeline|submit|fence|flush|gmem|sysmem|queue|sync|semaphore|vkCmd|barrier|frame' "$OUTPUT_ALL" > "$OUTPUT_FILTERED" || true

echo "==> Arquivos gerados:"
ls -lh "$OUTPUT_ALL" "$OUTPUT_FILTERED"

echo
echo "==> Amostra (primeiras 10 linhas filtradas):"
head "$OUTPUT_FILTERED" || true
