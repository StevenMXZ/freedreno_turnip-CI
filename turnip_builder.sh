#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# ===========================
# Turnip Batch Builder (Testando Commits Específicas)
# ===========================

deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
sdkver="35"
# Repositório oficial (upstream)
mesa_repo="https://gitlab.freedesktop.org/mesa/mesa.git"

# LISTA DAS NOVAS COMMITS PARA TESTAR (Lote 5)
commits_to_build=(
    "d8a19711ed1"
    "77b96ac0a74"
    "83212054e07"
)

# Variáveis dinâmicas
current_commit=""
current_short=""
version_str=""

clear

# ===========================
# Funções
# ===========================

check_deps(){
    missing=0
	echo "🔍 Checking system dependencies ..."
	for dep in $deps; do
		if ! command -v $dep >/dev/null 2>&1; then
			echo -e "$red Missing dependency: $dep$nocolor"
			missing=1
		else
			echo -e "$green Found: $dep$nocolor"
		fi
	done
	if [ "$missing" == "1" ]; then
		echo "Please install missing dependencies." && exit 1
	fi
	pip install mako &> /dev/null || true
}

prepare_ndk(){
	echo "📦 Preparing Android NDK ..."
	mkdir -p "$workdir"
	cd "$workdir"
	if [ -z "${ANDROID_NDK_LATEST_HOME}" ]; then
		if [ ! -d "$ndkver" ]; then
			echo "Downloading Android NDK ..."
			curl -L "https://dl.google.com/android/repository/${ndkver}-linux.zip" --output "${ndkver}-linux.zip" &> /dev/null
			echo "Extracting NDK ..."
			unzip "${ndkver}-linux.zip" &> /dev/null
		fi
	else
		echo "Using preinstalled Android NDK."
	fi
}

clone_repo(){
    echo "🌿 Cloning Mesa repository (Full History)..."
    cd "$workdir"
    if [ -d mesa ]; then
        echo "Repo already exists, fetching updates..."
        cd mesa
        git fetch --all
        cd ..
    else
        # Clone completo necessário para navegar entre commits antigos
        git clone "$mesa_repo" mesa
    fi
}

build_commit(){
    local commit_id=$1
    echo -e "${green}>>> Processing commit: $commit_id ${nocolor}"
    
    cd "$workdir/mesa"
    
    # Tenta fazer o checkout. Se falhar, avisa e pula.
    if ! git checkout -f "$commit_id"; then
        echo -e "${red}Commit $commit_id not found! Check if you are using the correct repo URL.${nocolor}"
        return
    fi
    
    current_commit=$(git rev-parse HEAD)
    current_short=$(git rev-parse --short HEAD)
    
    if [ -f VERSION ]; then
	    version_str=$(cat VERSION | xargs)
	else
	    version_str="unknown"
	fi

    # Limpa build anterior para evitar conflitos
    rm -rf build
    
    # Configura NDK paths
	local ndk_root_path
	if [ -z "${ANDROID_NDK_LATEST_HOME}" ]; then
		ndk_root_path="$workdir/$ndkver"
	else
		ndk_root_path="$ANDROID_NDK_LATEST_HOME"
	fi
	local ndk_bin_path="$ndk_root_path/toolchains/llvm/prebuilt/linux-x86_64/bin"
	local ndk_sysroot_path="$ndk_root_path/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

    # Cria crossfile
	local cross_file="$workdir/mesa/android-aarch64-crossfile.txt"
	cat <<EOF > "$cross_file"
[binaries]
ar = '$ndk_bin_path/llvm-ar'
# Usando --sysroot para garantir compatibilidade de bibliotecas
c = ['ccache', '$ndk_bin_path/aarch64-linux-android$sdkver-clang', '--sysroot=$ndk_sysroot_path']
cpp = ['ccache', '$ndk_bin_path/aarch64-linux-android$sdkver-clang++', '--sysroot=$ndk_sysroot_path', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$ndk_bin_path/aarch64-linux-android-strip'
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

    # Configurações de ambiente
	export LIBRT_LIBS=""
	export CFLAGS="-D__ANDROID__"
	export CXXFLAGS="-D__ANDROID__"

    echo "⚙️ Configuring Meson for $commit_id..."
	if ! meson setup build --cross-file "$cross_file" \
		-Dbuildtype=release \
		-Dplatforms=android \
		-Dplatform-sdk-version=$sdkver \
		-Dandroid-stub=true \
		-Dgallium-drivers= \
		-Dvulkan-drivers=freedreno \
		-Dfreedreno-kmds=kgsl \
		-Degl=disabled \
		-Dglx=disabled \
		-Dshared-glapi=enabled \
		-Db_lto=true \
		-Dvulkan-beta=true \
		-Ddefault_library=shared \
		-Dc_args='-D__ANDROID__' \
		2>&1 | tee "$workdir/meson_log_$current_short"; then
            echo -e "${red}Meson configuration failed for $commit_id${nocolor}"
            return
    fi

    echo "🔨 Compiling $commit_id..."
	if ! ninja -C build 2>&1 | tee "$workdir/ninja_log_$current_short"; then
        echo -e "${red}Compilation failed for $commit_id${nocolor}"
        return
    fi
    
    # Empacotamento
    local lib_path="build/src/freedreno/vulkan/libvulkan_freedreno.so"
    if [ ! -f "$lib_path" ]; then
		echo -e "${red}Build failed for $commit_id (Lib not found)${nocolor}"
        return 
	fi

    echo "📦 Packaging $commit_id..."
    local package_temp="$workdir/package_temp_$current_short"
    mkdir -p "$package_temp"
	cp "$lib_path" "$package_temp/lib_temp.so"

	cd "$package_temp"
	patchelf --set-soname "vulkan.adreno.so" lib_temp.so
	mv lib_temp.so "vulkan.ad07XX.so"

    local date_meta=$(date +'%b %d, %Y')
    local zip_name="turnip_test_${current_short}.zip"
    
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "Turnip Test - $current_short",
  "description": "Testing specific commit $current_short",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF
    
    zip -9 "$workdir/$zip_name" "vulkan.ad07XX.so" meta.json
    rm -rf "$package_temp"
    
    echo -e "${green}✅ Created: $zip_name${nocolor}"
}

generate_release_info() {
    echo -e "${green}Generating release info...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
    
    echo "Batch-Test-${date_tag}-Set5" > tag
    echo "Turnip Batch Test (Set 5) - ${date_tag}" > release
    
    echo "Automated Batch Test of specific commits." > description
    echo "" >> description
    echo "### Commits in this release:" >> description
    
    for commit in "${commits_to_build[@]}"; do
        echo "- Commit: \`$commit\`" >> description
    done
}

# ===========================
# Execução
# ===========================
check_deps
prepare_ndk
clone_repo

# Loop através da lista de commits
for commit in "${commits_to_build[@]}"; do
    build_commit "$commit"
done

generate_release_info

echo -e "${green}🎉 Batch processing finished!${nocolor}"
