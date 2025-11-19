#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# ===========================
# Turnip Dual Builder
# Variant 1: Main (Nuclear Fix for A6xx freezes)
# Variant 2: PixelyIon (Specific Query Pool Fix)
# ===========================

deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
sdkver="35"

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

# Função principal de build
build_variant() {
    local variant_name=$1      # Nome para exibição/arquivo (Ex: Main, PixelyIon)
    local repo_url=$2          # URL do Git
    local branch=$3            # Branch para checkout
    local patch_strategy=$4    # 'nuclear' ou 'query_only'
    
    local source_dir="$workdir/source_$variant_name"
    local build_dir="$workdir/build_$variant_name"
    local package_dir="$workdir/package_$variant_name"

    echo -e "\n${green}==============================================${nocolor}"
    echo -e "${green}🚀 Starting Build: $variant_name ($branch) ${nocolor}"
    echo -e "${green}==============================================${nocolor}"

    # 1. Preparar Fonte
    if [ -d "$source_dir" ]; then rm -rf "$source_dir"; fi
    git clone --depth=1 "$repo_url" "$source_dir"
    cd "$source_dir"
    
    # Se o branch não for o padrão do clone, faz fetch e checkout
    if [ "$branch" != "main" ] && [ "$branch" != "master" ]; then
        echo "Fetching branch $branch..."
        git fetch origin "$branch"
        git checkout "$branch"
    fi

    # --- APLICAÇÃO DE PATCHES ---
    echo -e "${green}--- Applying Patches ($patch_strategy) ---${nocolor}"

    # Patch Comum: Reverter tu_bo_init_new_cached em tu_query.cc
    # Isso corrige a regressão específica de query pools
    if [ -f src/freedreno/vulkan/tu_query.cc ]; then
        sed -i 's/tu_bo_init_new_cached/tu_bo_init_new/g' src/freedreno/vulkan/tu_query.cc
        echo "✅ Reverted tu_bo_init_new_cached in tu_query.cc"
    else
        echo "${red}⚠️ Warning: tu_query.cc not found.${nocolor}"
    fi

    # Patch Adicional para 'nuclear' (Mesa Main): Desativar globalmente memória cacheada
    if [ "$patch_strategy" == "nuclear" ]; then
        echo "Applying Nuclear Fix (Global No Cached Mem)..."
        if [ -f src/freedreno/vulkan/tu_device.cc ]; then
            sed -i 's/physical_device->has_cached_coherent_memory = .*/physical_device->has_cached_coherent_memory = false;/' src/freedreno/vulkan/tu_device.cc || true
        fi
        grep -rl "VK_MEMORY_PROPERTY_HOST_CACHED_BIT" src/freedreno/vulkan/ | while read file; do
            sed -i 's/dev->physical_device->has_cached_coherent_memory ? VK_MEMORY_PROPERTY_HOST_CACHED_BIT : 0/0/g' "$file" || true
            sed -i 's/VK_MEMORY_PROPERTY_HOST_CACHED_BIT/0/g' "$file" || true
        done
        echo "✅ Globally disabled cached coherent memory."
    fi
    # ----------------------------

    # Info do Commit
    local commit_hash=$(git rev-parse --short HEAD)
    local version_str=$(cat VERSION 2>/dev/null | xargs || echo "unknown")

    # 4. Compilar
    echo -e "${green}--- Compiling $variant_name ---${nocolor}"
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
    
    export LIBRT_LIBS=""
	export CFLAGS="-D__ANDROID__"
	export CXXFLAGS="-D__ANDROID__"

	if ! meson setup "$build_dir" --cross-file "$cross_file" \
		-Dbuildtype=release -Dplatforms=android -Dplatform-sdk-version=$sdkver \
		-Dandroid-stub=true -Dgallium-drivers= -Dvulkan-drivers=freedreno \
		-Dfreedreno-kmds=kgsl -Degl=disabled -Dglx=disabled -Dshared-glapi=enabled \
		-Db_lto=true -Dvulkan-beta=true -Ddefault_library=shared \
		2>&1 | tee "$workdir/log_meson_$variant_name.txt"; then
        
        echo -e "${red}Meson setup failed for $variant_name.${nocolor}"
        return
    fi

    if ! ninja -C "$build_dir" 2>&1 | tee "$workdir/log_ninja_$variant_name.txt"; then
        echo -e "${red}Compilation failed for $variant_name.${nocolor}"
        return
    fi

    # 5. Empacotar
    echo -e "${green}--- Packaging $variant_name ---${nocolor}"
    local lib_path="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"
    if [ ! -f "$lib_path" ]; then
        echo -e "${red}Build failed for $variant_name (lib not found)${nocolor}"
        return
    fi

    if [ -d "$package_dir" ]; then rm -rf "$package_dir"; fi
    mkdir -p "$package_dir"
    cp "$lib_path" "$package_dir/libvulkan_freedreno.so"
    
    cd "$package_dir"
    patchelf --set-soname "vulkan.adreno.so" libvulkan_freedreno.so
    mv libvulkan_freedreno.so "vulkan.ad07XX.so"

    local date_meta=$(date +'%Y-%m-%d')
    # Nome curto e limpo
    local meta_name="Turnip-${variant_name}-${commit_hash}"
    
    # Descrição dinâmica baseada no patch
    local meta_desc=""
    if [ "$patch_strategy" == "nuclear" ]; then
        meta_desc="Mesa $version_str ($variant_name) + Nuclear A619 Fix (No Cache)."
    else
        meta_desc="Mesa $version_str ($variant_name) + Query Pool Fix."
    fi

    cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "$meta_desc",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF
    
    local zip_name="turnip_${variant_name}_${commit_hash}.zip"
    zip -9 "$workdir/$zip_name" ./*
    echo -e "${green}✅ Created: $workdir/$zip_name${nocolor}"
}

generate_release_info() {
    echo -e "${green}Generating release info...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
    
    echo "Turnip-Dual-${date_tag}" > tag
    echo "Turnip Dual Build - ${date_tag}" > release
    
    echo "Automated Build containing 2 variants:" > description
    echo "" >> description
    echo "1. **Mesa Main:** (Nuclear Fix)" >> description
    echo "   - Reverted \`tu_bo_init_new_cached\` usage in \`tu_query.cc\`." >> description
    echo "   - Globally disabled \`VK_MEMORY_PROPERTY_HOST_CACHED_BIT\`." >> description
    echo "   - *Best for Adreno 6xx stability.*" >> description
    echo "" >> description
    echo "2. **PixelyIon:** (Branch \`tu-newat\`)" >> description
    echo "   - Reverted \`tu_bo_init_new_cached\` usage in \`tu_query.cc\`." >> description
    echo "   - *Contains specific autotuner changes from PixelyIon.*" >> description
}

# ===========================
# Execução
# ===========================
check_deps
prepare_ndk

# VARIANT 1: Mesa Main (Nuclear Fix: Query Revert + Global Disable)
# Isso replica o build 1985370 que você confirmou ser o melhor
build_variant "Main" "https://gitlab.freedesktop.org/mesa/mesa.git" "main" "nuclear"

# VARIANT 2: PixelyIon (Query Revert Only)
# Apenas reverte a commit problemática do query pool
build_variant "PixelyIon" "https://gitlab.freedesktop.org/PixelyIon/mesa.git" "tu-newat" "query_only"

generate_release_info

echo -e "${green}🎉 All builds finished!${nocolor}"
