#!/bin/bash
set -e
green='\033[0;32m'
cyan='\033[0;36m'
nocolor='\033[0m'

# Configuração
mesa_repo="https://gitlab.freedesktop.org/mesa/mesa.git"

# Seus Hashes
# GOOD = Funciona (365cd04375)
# BAD  = Erro Unity (5b11c3ff0a)
COMMIT_GOOD="365cd04375"
COMMIT_BAD="5b11c3ff0a"

echo -e "${cyan}--- Filtrando Commits Turnip (tu:) ---${nocolor}"

# 1. Baixar histórico leve
if [ ! -d "mesa_history" ]; then
    git clone --bare --filter=blob:none "$mesa_repo" mesa_history
fi
cd mesa_history

# 2. Listar commits APENAS com "tu:" no título
echo -e "${green}Listando commits 'tu:' entre $COMMIT_GOOD e $COMMIT_BAD...${nocolor}"
echo "------------------------------------------------"

# A ordem dos pontos (..) depende da data, o git log resolve automático se usar --ancestry-path as vezes,
# mas aqui vamos pegar a lista bruta filtrada por grep.
git log --oneline --no-merges "${COMMIT_GOOD}..${COMMIT_BAD}" --grep="tu:" --reverse > ../lista_turnip.txt

count=$(cat ../lista_turnip.txt | wc -l)

cat ../lista_turnip.txt
echo "------------------------------------------------"
echo -e "${green}Total de commits Turnip encontrados: $count${nocolor}"
echo "A lista foi salva em 'lista_turnip.txt'."
echo "Escolha um commit do meio dessa lista e use no GitHub Actions abaixo."
