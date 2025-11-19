#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# ===========================
# Turnip Dual Builder (PixelyIon & Main) + MR 35894 + VK1.4
# ===========================

deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
sdkver="35"

# Lista de MRs para mesclar
mrs_to_merge=("35894")

# ===========================
# Funções Auxiliares
# ===========================

check_deps(){
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

# Função genérica para construir uma variante
build_variant() {
    local variant_name=$1
    local repo_url=$2
    local branch=$3
    
    local source_dir="$workdir/source_$variant_name"
    local build_dir="$workdir/build_$variant_name"
    local package_dir="$workdir/package_$variant_name"
    local package_temp="$workdir/package_temp_$variant_name"

    echo -e "\n${green}==============================================${nocolor}"
    echo -e "${green}🚀 Starting Build: $variant_name ${nocolor}"
    echo -e "${green}==============================================${nocolor}"

    # 1. Preparar Fonte
    if [ -d "$source_dir" ]; then rm -rf "$source_dir"; fi
    # Clone completo para permitir merge
    git clone "$repo_url" "$source_dir"
    cd "$source_dir"
    git checkout "$branch" || git checkout main

    # Configurar Git
    git config user.name "CI Builder"
    git config user.email "ci@builder.com"

    # 2. Mesclar Merge Requests (Direto do Upstream)
    # Adiciona o repo oficial como 'upstream' para garantir que encontramos os MRs
    git remote add upstream https://gitlab.freedesktop.org/mesa/mesa.git || true
    git fetch upstream

    for mr in "${mrs_to_merge[@]}"; do
        echo -e "${green}--- Merging MR !${mr} ---${nocolor}"
        # Busca a referência do MR do upstream
        if git fetch upstream "refs/merge-requests/${mr}/head"; then
            if git merge --no-edit FETCH_HEAD; then
                echo -e "${green}✅ MR !${mr} merged successfully.${nocolor}"
            else
                echo -e "${red}❌ Merge failed for MR !${mr}. Skipping this MR but continuing build...${nocolor}"
                git merge --abort || true
            fi
        else
             echo -e "${red}❌ Could not fetch MR !${mr}.${nocolor}"
        fi
    done

    # 3. Aplicar Patch VK 1.4 (A6xx Hack) via SED
    echo -e "${green}--- Applying A6xx VK 1.4 Hack ---${nocolor}"
	if [ -f src/freedreno/vulkan/meson.build ]; then
		sed -i 's/--api-version.*1\.1.*/--api-version 1.4/' src/freedreno/vulkan/meson.build || true
	fi
	if [ -f src/freedreno/vulkan/tu_device.cc ]; then
		sed -i 's/#define TU_API_VERSION VK_MAKE_VERSION(1, 3, VK_HEADER_VERSION)/#define TU_API_VERSION VK_MAKE_VERSION(1, 4, VK_HEADER_VERSION)/' src/freedreno/vulkan/tu_device.cc || true
        
        # Injeção do bloco de conformidade
		sed -n '1,4000p' src/freedreno/vulkan/tu_device.cc > /tmp/tu_snippet.$$
		if grep -q "tu_GetPhysicalDeviceProperties2" /tmp/tu_snippet.$$; then
			sed -i '/tu_GetPhysicalDeviceProperties2/,/return;/ {
  /return;/ i\
   p->conformanceVersion = (VkConformanceVersion){1, 4, 0, 0};
}' src/freedreno/vulkan/tu_device.cc || true
		fi
		rm -f /tmp/tu_snippet.$$
        
		sed -i 's/VK_MAKE_VERSION(1, 3, VK_HEADER_VERSION)/TU_API_VERSION/g' src/freedreno/vulkan/tu_device.cc || true
	fi
    echo -e "${green}✅ VK 1.4 patch applied.${nocolor}"

    # Info do Commit
    local commit_hash=$(git rev-parse --short HEAD)
    local version_str=$(cat VERSION 2>/dev/null | xargs || echo "unknown")

    # 4. Compilar
    echo -e "${green}--- Compiling ---${nocolor}"
	local ndk_root_path
	if [ -z "${ANDROID_NDK_LATEST_HOME}" ]; then ndk_root_path="$workdir/$ndkver"; else ndk_root_path="$ANDROID_NDK_LATEST_HOME"; fi
	local ndk_bin="$ndk_root_path/toolchains/llvm/prebuilt/linux-x86_64/bin"
	local sysroot="$ndk_root_path/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

	local cross_file="$source_dir/android-cross.txt"
	cat <<EOF > "$cross_file"
[binaries]
ar = '$ndk_bin/llvm-ar'
c = ['ccache', '$ndk_bin/aarch64-linux-android$sdkver-clang', '--sysroot=$sysroot']
cpp = ['ccache', '$ndk_bin/aarch64-linux-android$sdkver-clang++', '--sysroot=$sysroot']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$ndk_bin/aarch64-linux-android-strip'
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF
    
    # Configs de ambiente
    export LIBRT_LIBS=""
	export CFLAGS="-D__ANDROID__"
	export CXXFLAGS="-D__ANDROID__"

    # REMOVIDO: -Dhave_librt=false e -Dshared-glapi=enabled
	if ! meson setup "$build_dir" --cross-file "$cross_file" \
		-Dbuildtype=release -Dplatforms=android -Dplatform-sdk-version=$sdkver \
		-Dandroid-stub=true -Dgallium-drivers= -Dvulkan-drivers=freedreno \
		-Dfreedreno-kmds=kgsl -Degl=disabled -Dglx=disabled \
		-Db_lto=true -Dvulkan-beta=true -Ddefault_library=shared \
		2>&1 | tee "$workdir/log_meson_$variant_name.txt"; then
        
        echo -e "${red}Meson setup failed for $variant_name. Check log_meson_$variant_name.txt${nocolor}"
        return
    fi

    if ! ninja -C "$build_dir" 2>&1 | tee "$workdir/log_ninja_$variant_name.txt"; then
        echo -e "${red}Compilation failed for $variant_name.${nocolor}"
        return
    fi
    echo -e "${green}Compilation successful.${nocolor}"

    # 5. Empacotar
    echo -e "${green}--- Packaging ---${nocolor}"
    local lib_path="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"
    if [ ! -f "$lib_path" ]; then
        echo -e "${red}Build failed for $variant_name (lib not found)${nocolor}"
        return
    fi

    # Garante diretório limpo para este pacote
    if [ -d "$package_dir" ]; then rm -rf "$package_dir"; fi
    mkdir -p "$package_dir"
    
    cp "$lib_path" "$package_dir/libvulkan_freedreno.so"
    
    cd "$package_dir"
    patchelf --set-soname "vulkan.adreno.so" libvulkan_freedreno.so
    mv libvulkan_freedreno.so "vulkan.ad07XX.so"

    local date_meta=$(date +'%b %d, %Y')
    cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "Turnip ($variant_name) - $date_meta",
  "description": "Mesa $version_str + MR !${mrs_to_merge[*]} + VK1.4 Patch. Commit $commit_hash",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF
    
    local zip_name="turnip_${variant_name}_$(date +'%Y%m%d')_${commit_hash}.zip"
    zip -9 "$workdir/$zip_name" ./*
    echo -e "${green}✅ Created: $workdir/$zip_name${nocolor}"
}

generate_release_info() {
    echo -e "${green}Generating release info...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
    
    echo "Turnip-MultiBuild-${date_tag}" > tag
    echo "Turnip Dual Build - ${date_tag}" > release
    
    echo "Automated Build containing 2 variants:" > description
    echo "" >> description
    echo "1. **Mesa Main:** Upstream Mesa + MR !${mrs_to_merge[*]} + VK1.4 Patch" >> description
    echo "2. **PixelyIon:** PixelyIon Fork + MR !${mrs_to_merge[*]} + VK1.4 Patch" >> description
}

# ===========================
# Execução
# ===========================
check_deps
prepare_ndk

# VARIANT 1: Mesa Main
build_variant "Main" "https://gitlab.freedesktop.org/mesa/mesa.git" "main"

# VARIANT 2: PixelyIon
build_variant "PixelyIon" "https://gitlab.freedesktop.org/PixelyIon/mesa.git" "tu-newat"

generate_release_info

echo -e "${green}🎉 All builds finished!${nocolor}"
