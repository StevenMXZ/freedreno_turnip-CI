#!/bin/bash
set -e
green='\033[0;32m'
red='\033[0;31m'
cyan='\033[0;36m'
nocolor='\033[0m'

# Configuração
workdir="$(pwd)/bisect_check"
mesa_repo="https://gitlab.freedesktop.org/mesa/mesa.git"

# SEUS COMMITS
# GOOD = O que funciona
# BAD  = O que deu erro
COMMIT_GOOD="365cd04375"
COMMIT_BAD="5b11c3ff0a"

echo -e "${cyan}--- Verificador de Commits (Bisection Helper) ---${nocolor}"

mkdir -p "$workdir"
cd "$workdir"

# 1. Preparar Repo (Apenas histórico, sem checkout pesado)
if [ ! -d "mesa/.git" ]; then
    echo "Clonando histórico do Mesa (pode levar um momento)..."
    git clone --bare --filter=blob:none "$mesa_repo" mesa
else
    echo "Atualizando histórico..."
    cd mesa
    git fetch origin
    cd ..
fi

cd mesa

# 2. Verificar se os commits existem
echo "Verificando commits..."
if ! git rev-parse --verify "$COMMIT_GOOD" >/dev/null 2>&1; then
    echo -e "${red}Erro: Commit GOOD ($COMMIT_GOOD) não encontrado no repo oficial.${nocolor}"
    exit 1
fi
if ! git rev-parse --verify "$COMMIT_BAD" >/dev/null 2>&1; then
    echo -e "${red}Erro: Commit BAD ($COMMIT_BAD) não encontrado no repo oficial.${nocolor}"
    exit 1
fi

# 3. Listar intervalo
# A ordem ... ou .. depende de qual é mais antigo. O git log resolve.
echo -e "${green}Calculando diferença entre as versões...${nocolor}"

# Lista commits entre eles
commits_list=$(git log --oneline --no-merges "${COMMIT_GOOD}..${COMMIT_BAD}")
count=$(echo "$commits_list" | grep -v "^$" | wc -l)

if [ "$count" -eq 0 ]; then
    # Tenta inverter caso o BAD seja mais antigo que o GOOD (improvável, mas possível)
    commits_list=$(git log --oneline --no-merges "${COMMIT_BAD}..${COMMIT_GOOD}")
    count=$(echo "$commits_list" | grep -v "^$" | wc -l)
fi

echo "------------------------------------------------"
if [ "$count" -eq 0 ]; then
    echo -e "${red}Nenhum commit encontrado entre esses dois.${nocolor}"
    echo "Eles são adjacentes ou o hash está incorreto."
else
    echo -e "${green}Existem $count commits entre o Bom e o Ruim.${nocolor}"
    echo "------------------------------------------------"
    echo "Lista de suspeitos (do mais novo pro mais antigo):"
    echo "$commits_list"
    echo "------------------------------------------------"
    
    # 4. Achar o commit do meio
    half=$((count / 2))
    # Pega o commit que está na metade da lista
    middle_commit=$(echo "$commits_list" | sed -n "${half}p" | awk '{print $1}')
    
    echo -e "${cyan}SUGESTÃO DE PRÓXIMO TESTE:${nocolor}"
    echo -e "Você deve compilar este commit agora: ${green}$middle_commit${nocolor}"
    echo "(Este é o ponto médio. Se ele funcionar, o erro está na metade de cima. Se falhar, está na metade de baixo.)"
fi
