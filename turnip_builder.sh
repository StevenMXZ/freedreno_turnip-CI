#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# ===========================
# Turnip Dual Builder (Clean Main & PixelyIon + A619 Fix Only)
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

# Função genérica para construir uma variante
build_variant() {
    local variant_name=$1  # Ex: Main, PixelyIon
    local repo_url=$2
    local branch=$3
    
    local source_dir="$workdir/source_$variant_name"
    local build_dir="$workdir/build_$variant_name"
    local package_dir="$workdir/package_$variant_name"

    echo -e "\n${green}==============================================${nocolor}"
    echo -e "${green}🚀 Starting Build: $variant_name ${nocolor}"
    echo -e "${green}==============================================${nocolor}"

    # 1. Preparar Fonte
    if [ -d "$source_dir" ]; then rm -rf "$source_dir"; fi
    # Clone completo
    git clone "$repo_url" "$source_dir"
    cd "$source_dir"
    git checkout "$branch" || git checkout main

    # --- APLICAR APENAS O FIX DA A619 (Nuclear) ---
    # Isso é essencial para não congelar o seu dispositivo.
    echo -e "${green}--- Applying A619 NUCLEAR Freeze Fix ---${nocolor}"
    
    # PARTE 1: Reverter a função específica em tu_query.cc
    if [ -f src/freedreno/vulkan/tu_query.cc ]; then
		sed -i 's/tu_bo_init_new_cached/tu_bo_init_new/g' src/freedreno/vulkan/tu_query.cc
	fi

    # PARTE 2: Matar a flag de cache globalmente
    if [ -f src/freedreno/vulkan/tu_device.cc ]; then
        sed -i 's/physical_device->has_cached_coherent_memory = .*/physical_device->has_cached_coherent_memory = false;/' src/freedreno/vulkan/tu_device.cc || true
    fi
    grep -rl "VK_MEMORY_PROPERTY_HOST_CACHED_BIT" src/freedreno/vulkan/ | while read file; do
		sed -i 's/dev->physical_device->has_cached_coherent_memory ? VK_MEMORY_PROPERTY_HOST_CACHED_BIT : 0/0/g' "$file" || true
		sed -i 's/VK_MEMORY_PROPERTY_HOST_CACHED_BIT/0/g' "$file" || true
	done
    echo -e "${green}✅ A619 Nuclear Fix applied (No Cached Mem).${nocolor}"


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

	meson setup "$build_dir" --cross-file "$cross_file" \
		-Dbuildtype=release -Dplatforms=android -Dplatform-sdk-version=$sdkver \
		-Dandroid-stub=true -Dgallium-drivers= -Dvulkan-drivers=freedreno \
		-Dfreedreno-kmds=kgsl -Degl=disabled -Dglx=disabled -Dshared-glapi=enabled \
		-Db_lto=true -Dvulkan-beta=true -Ddefault_library=shared \
		2>&1 | tee "$workdir/log_meson_$variant_name.txt"

    ninja -C "$build_dir" 2>&1 | tee "$workdir/log_ninja_$variant_name.txt"

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
    # CORREÇÃO: Nome curto e sem espaços para evitar erro de dlopen
    local short_name="Turnip-${variant_name}-${commit_hash}"
    
    cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$short_name",
  "description": "Mesa $version_str ($variant_name) + A619 Fix. Commit $commit_hash",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF
    
    # Zip com nome limpo
    local zip_name="turnip_${variant_name}_${commit_hash}.zip"
    zip -9 "$workdir/$zip_name" ./*
    echo -e "${green}✅ Created: $workdir/$zip_name${nocolor}"
}

generate_release_info() {
    echo -e "${green}Generating release info...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
    
    echo "Turnip-Dual-${date_tag}" > tag
    echo "Turnip Dual Build (Clean + A619 Fix) - ${date_tag}" > release
    
    echo "Automated Build containing 2 variants:" > description
    echo "" >> description
    echo "**Common Features:** A619 Freeze Fix (No Cached Mem) applied to ALL builds." >> description
    echo "**Removed:** Fake VK 1.4 patch and unstable MRs." >> description
    echo "" >> description
    echo "1. **Mesa Main:** Official Upstream Mesa" >> description
    echo "2. **PixelyIon:** Fork branch \`tu-newat\`" >> description
}

# ===========================
# Execução
# ===========================
check_deps
prepare_ndk

# VARIANT 1: Mesa Main (Sem MRs extras)
build_variant "Main" "https://gitlab.freedesktop.org/mesa/mesa.git" "main"

# VARIANT 2: PixelyIon (Sem MRs extras)
build_variant "PixelyIon" "https://gitlab.freedesktop.org/PixelyIon/mesa.git" "tu-newat"

generate_release_info

echo -e "${green}🎉 All builds finished!${nocolor}"
