#!/bin/bash -e
# Bisect para encontrar regressão no Turnip entre dois commits Mesa

WORKDIR=$(pwd)/turnip_bisect
GOOD_COMMIT="47619ef5389c44cb92066c20409e6a9617d685fb"
BAD_COMMIT="93f24f0bd02916d9ce4cc452312c19e9cca5d299"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "🔽 Clonando Mesa..."
git clone https://gitlab.freedesktop.org/mesa/mesa.git mesa
cd mesa

echo "📍 Iniciando git bisect..."
git bisect start
git bisect bad $BAD_COMMIT
git bisect good $GOOD_COMMIT

# Script de teste automatizado — apenas verifica se compila
git bisect run bash -c "
  cd ..;
  rm -rf turnip_workdir;
  mkdir turnip_workdir;
  cp ../scripts/build_turnip.sh ./;
  bash build_turnip.sh > build_output.log 2>&1;
"

echo "✅ Bisect finalizado!"
git bisect log > ../bisect_log.txt
git bisect visualize > ../bisect_result.txt || true
