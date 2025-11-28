#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# ===========================
# Turnip Triple Builder (Main, a6xx, OneUI)
# ===========================

deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
sdkver="35"
mesa_repo="https://gitlab.freedesktop.org/mesa/mesa.git"

# Variáveis globais
commit_hash=""
version_str=""
date_tag=$(date +'%Y-%m-%d')

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
	echo " Preparing Android NDK ..."
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

# Função Principal de Build
build_variant() {
    local variant_name=$1   # Nome interno para logs/pastas (ex: Normal)
    local zip_name=$2       # Nome EXATO do arquivo final
    local patch_mode=$3     # Modo de patch (none, a6xx_fix, oneui_fix)

    echo -e "\n${green}==============================================${nocolor}"
    echo -e "${green} Building Variant: $variant_name -> $zip_name ${nocolor}"
    echo -e "${green}==============================================${nocolor}"

    # 1. Limpar e Preparar Fonte (Garante build limpo a cada rodada)
    cd "$workdir"
    if [ -d mesa ]; then rm -rf mesa; fi
    if [ -d build ]; then rm -rf build; fi
    
    echo "Cloning Mesa Main..."
    git clone --depth=1 "$mesa_repo" mesa
    cd mesa
    
    commit_hash=$(git rev-parse --short HEAD)
    version_str=$(cat VERSION 2>/dev/null | xargs || echo "unknown")

    # 2. Aplicar Patches (Baseado no modo)
    case "$patch_mode" in
        "a6xx_fix")
            echo -e "${green}Applying a6xx Stability Fixes...${nocolor}"
            if [ -f src/freedreno/vulkan/tu_query.cc ]; then
                sed -i 's/tu_bo_init_new_cached/tu_bo_init_new/g' src/freedreno/vulkan/tu_query.cc
            fi
            if [ -f src/freedreno/vulkan/tu_device.cc ]; then
                sed -i 's/physical_device->has_cached_coherent_memory = .*/physical_device->has_cached_coherent_memory = false;/' src/freedreno/vulkan/tu_device.cc || true
            fi
            grep -rl "VK_MEMORY_PROPERTY_HOST_CACHED_BIT" src/freedreno/vulkan/ | while read file; do
                sed -i 's/dev->physical_device->has_cached_coherent_memory ? VK_MEMORY_PROPERTY_HOST_CACHED_BIT : 0/0/g' "$file" || true
                sed -i 's/VK_MEMORY_PROPERTY_HOST_CACHED_BIT/0/g' "$file" || true
            done
            ;;
        "oneui_fix")
            echo -e "${green}Applying OneUI Fix (UBWC Hint)...${nocolor}"
            if [ -f src/freedreno/common/freedreno_devices.py ]; then
                sed -i 's/enable_tp_ubwc_flag_hint = False,/enable_tp_ubwc_flag_hint = True,/' src/freedreno/common/freedreno_devices.py
            fi
            ;;
        "none")
            echo "No patches applied (Stock Build)."
            ;;
    esac

    # 3. Compilar
    echo -e "${green}--- Compiling ---${nocolor}"
	local ndk_root_path
	if [ -z "${ANDROID_NDK_LATEST_HOME}" ]; then ndk_root_path="$workdir/$ndkver"; else ndk_root_path="$ANDROID_NDK_LATEST_HOME"; fi
	local ndk_bin="$ndk_root_path/toolchains/llvm/prebuilt/linux-x86_64/bin"
	local sysroot="$ndk_root_path/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
	local cross_file="$workdir/android-cross.txt"

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

	meson setup build --cross-file "$cross_file" \
		-Dbuildtype=release -Dplatforms=android -Dplatform-sdk-version=$sdkver \
		-Dandroid-stub=true -Dgallium-drivers= -Dvulkan-drivers=freedreno \
		-Dfreedreno-kmds=kgsl -Degl=disabled -Dglx=disabled -Dshared-glapi=enabled \
		-Db_lto=true -Dvulkan-beta=true -Ddefault_library=shared \
		2>&1 | tee "$workdir/log_meson_$variant_name.txt"

    ninja -C build 2>&1 | tee "$workdir/log_ninja_$variant_name.txt"

    # 4. Empacotar
    local lib_path="build/src/freedreno/vulkan/libvulkan_freedreno.so"
    if [ ! -f "$lib_path" ]; then
        echo -e "${red}Build failed for $variant_name${nocolor}"
        return
    fi

    local package_temp="$workdir/temp_$variant_name"
    mkdir -p "$package_temp"
    cp "$lib_path" "$package_temp/libvulkan_freedreno.so"
    
    cd "$package_temp"
    patchelf --set-soname "vulkan.adreno.so" libvulkan_freedreno.so
    mv libvulkan_freedreno.so "vulkan.ad07XX.so"

    # Meta.json com nome interno descritivo
    local meta_desc=""
    case "$variant_name" in
        "Normal") meta_desc="Standard Mesa Main build." ;;
        "a6xx")   meta_desc="for Adreno 6xx stability." ;;
        "OneUI")  meta_desc="Patched for OneUI compatibility." ;;
    esac

    cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "Turnip $variant_name - $version_str",
  "description": "$meta_desc Commit: $commit_hash",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF
    
    echo "Zipping to $zip_name..."
    zip -9 "$workdir/$zip_name" ./*
    
    rm -rf "$package_temp"
}

generate_release_info() {
    echo -e "${green}Generating release info...${nocolor}"
    cd "$workdir"
    
    # Formatos de data para os nomes dos arquivos
    # %d%m%y = 281125 (DiaMêsAno)
    # %m%y   = 1125   (MêsAno)
    local d_full=$(date +'%d%m%y')
    local d_short=$(date +'%m%y')
    
    # Salva os nomes em variáveis para uso abaixo e para referência
    name_normal="Turnip-${d_full}.zip"
    name_a6xx="Turnip-a6xx-${d_short}.zip"
    name_oneui="Turnip-OneUI-${d_short}.zip"

    echo "Turnip-Release-${d_full}" > tag
    echo "Turnip Drivers - $(date +'%Y-%m-%d')" > release
    
    echo "Automated Turnip builds from Mesa Main." > description
    echo "Mesa Version: \`$version_str\` | Commit: \`$commit_hash\`" >> description
    echo "" >> description
    echo "### Downloads:" >> description
    echo "1. **$name_normal**: Standard build from main branch." >> description
    echo "2. **$name_a6xx**: fix for a6xx devices." >> description
    echo "3. **$name_oneui**: Includes UBWC hint fix for Samsung OneUI." >> description
}

# ===========================
# Execução
# ===========================
check_deps
prepare_ndk

# Formatos de data
d_full=$(date +'%d%m%y') # Ex: 281125
d_short=$(date +'%m%y')  # Ex: 1125

# 1. Turnip Normal -> Turnip-281125.zip
build_variant "Normal" "Turnip-${d_full}.zip" "none"

# 2. Turnip a6xx -> Turnip-a6xx-1125.zip
build_variant "a6xx" "Turnip-a6xx-${d_short}.zip" "a6xx_fix"

# 3. Turnip OneUI -> Turnip-OneUI-1125.zip
build_variant "OneUI" "Turnip-OneUI-${d_short}.zip" "oneui_fix"

generate_release_info

echo -e "${green}🎉 All builds finished!${nocolor}"
