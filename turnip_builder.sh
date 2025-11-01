#!/bin/bash
set -e

# Hashes dos commits a comparar
OLD_COMMIT="47619ef5389c44cb92066c20409e6a9617d685fb"
NEW_COMMIT="93f24f0bd02916d9ce4cc452312c19e9cca5d299"

# Clona o repositório Mesa
echo "🔽 Clonando o repositório Mesa..."
git clone --depth=10000 https://gitlab.freedesktop.org/mesa/mesa.git mesa-repo
cd mesa-repo

# Confere se ambos os commits existem
if ! git cat-file -e $OLD_COMMIT || ! git cat-file -e $NEW_COMMIT; then
  echo "❌ Um dos commits não existe!"
  exit 1
fi

# Conta o número de commits entre eles
COUNT=$(git rev-list --count ${OLD_COMMIT}..${NEW_COMMIT})
echo "📊 Número de commits entre:"
echo "De: $OLD_COMMIT"
echo "Até: $NEW_COMMIT"
echo "👉 Total: $COUNT commits"

# Mostra resumo opcional dos commits
echo ""
echo "📝 Lista resumida de commits:"
git log --oneline ${OLD_COMMIT}..${NEW_COMMIT} | tail -n 20
