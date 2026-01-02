#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
sdkver="35"
mesa_repo="https://gitlab.freedesktop.org/mesa/mesa.git"

commit_short=""
mesa_version=""

check_deps(){
	echo "Checking system dependencies..."
	for dep in $deps; do
		if ! command -v $dep >/dev/null 2>&1; then
			echo -e "$red Missing dependency: $dep$nocolor"
		else
			echo -e "$green Found: $dep$nocolor"
		fi
	done
	pip install mako &> /dev/null || true
}

prepare_workdir(){
	echo "Preparing Work Directory..."
	mkdir -p "$workdir"
	cd "$workdir"

	if [ -z "${ANDROID_NDK_LATEST_HOME}" ] || [ ! -d "${ANDROID_NDK_LATEST_HOME}" ]; then
		if [ ! -d "$ndkver" ]; then
			echo "Downloading Android NDK..."
			curl -L "https://dl.google.com/android/repository/${ndkver}-linux.zip" --output "${ndkver}-linux.zip" &> /dev/null
			unzip -q "${ndkver}-linux.zip" &> /dev/null
            export ANDROID_NDK_HOME="$workdir/$ndkver"
		fi
	else	
		echo "Using Pre-installed NDK"
        export ANDROID_NDK_HOME="${ANDROID_NDK_LATEST_HOME}"
	fi

	if [ -d mesa ]; then rm -rf mesa; fi
	echo "Cloning Mesa..."
	git clone "$mesa_repo" mesa
	cd mesa
    
    git config user.name "CI Builder"
    git config user.email "ci@builder.com"

	commit_short=$(git rev-parse --short HEAD)
	mesa_version=$(cat VERSION 2>/dev/null || echo "unknown")
	cd "$workdir"
}

# --- FUNÇÕES DE PATCH (Caminhos Corrigidos) ---

# Nota: Estas funções assumem que você já está dentro da pasta 'mesa'

apply_sysmem_patch() {
    echo -e "${green}Applying Patch: Force Sysmem...${nocolor}"
    local file="src/freedreno/vulkan/tu_cmd_buffer.cc"
    # Correção: removido prefixo 'mesa/' pois já estaremos dentro da pasta
    if [ -f "$file" ]; then
        sed -i '/if (TU_DEBUG(SYSMEM)) {/i \   return true;' "$file"
    else
        echo -e "${red}Error: $file not found! PWD: $(pwd)${nocolor}"
        exit 1
    fi
}

apply_oneui_patch() {
    echo -e "${green}Applying Patch: OneUI/A740 Fix...${nocolor}"
    local file="src/freedreno/common/freedreno_devices.py"
    if [ -f "$file" ]; then
        sed -i 's/\[a7xx_base, a7xx_gen2\]/\[a7xx_base, a7xx_gen2, GPUProps(enable_tp_ubwc_flag_hint = True)\]/' "$file"
    else
        echo -e "${red}Error: $file not found!${nocolor}"
        exit 1
    fi
}

apply_a6xx_patch() {
    echo -e "${green}Applying Patch: A6xx Stability...${nocolor}"
    
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
}

# --- COMPILAÇÃO ---

build_variant() {
    local variant_name="$1"
    local zip_suffix="$2"
    
    echo -e "${green}>>> Building Variant: $variant_name${nocolor}"
    
    # Garante que estamos na raiz do mesa
    cd "$workdir/mesa"
    
    local ndk="$ANDROID_NDK_LATEST_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local cross_file="$workdir/android-aarch64"
    
    # Correção: pkgconfig -> pkg-config
	cat <<EOF >"$cross_file"
[binaries]
ar = '$ndk/llvm-ar'
c = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang']
cpp = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$ndk/aarch64-linux-android-strip'
pkg-config = '/usr/bin/pkg-config'
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

    # Correção: Removido -Dlibarchive=disabled (causava erro)
    rm -rf build-android
    meson setup build-android \
        --cross-file "$cross_file" \
        -Dbuildtype=release \
        -Dplatforms=android \
        -Dplatform-sdk-version=$sdkver \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dvulkan-beta=true \
        -Dfreedreno-kmds=kgsl \
        -Db_lto=true \
        -Degl=disabled \
        &> "$workdir/meson_log_$zip_suffix"

    ninja -C build-android &> "$workdir/ninja_log_$zip_suffix"
    
    if [ ! -f build-android/src/freedreno/vulkan/libvulkan_freedreno.so ]; then
        echo -e "${red}Build failed for $variant_name${nocolor}"
        cat "$workdir/meson_log_$zip_suffix"
        # Mostra o erro do ninja se falhar
        tail -n 20 "$workdir/ninja_log_$zip_suffix"
        return 1
    fi

    # Packaging
    cd "$workdir"
    cp "mesa/build-android/src/freedreno/vulkan/libvulkan_freedreno.so" .
    patchelf --set-soname "vulkan.adreno.so" libvulkan_freedreno.so
    mv libvulkan_freedreno.so "vulkan.ad07XX.so"
    
    local filename="Turnip-${variant_name}-${commit_short}"
    local json_name="Turnip - $mesa_version - $commit_short ($variant_name)"
    
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$json_name",
  "description": "Variant: $variant_name. Commit: $commit_short",
  "author": "mesa-ci",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "$mesa_version",
  "minApi": 27,
  "libraryName": "vulkan.ad07XX.so"
}
EOF

    zip -9 "$filename.zip" vulkan.ad07XX.so meta.json
    echo -e "${green}Created $filename.zip${nocolor}"
    echo "- **$variant_name**: $filename.zip" >> release_notes.txt
}

# --- EXECUÇÃO ---

check_deps
prepare_workdir
echo "Automated Builds Report" > release_notes.txt
echo "" >> release_notes.txt

# 1. BUILD SYSMEM
echo "--- Preparing Sysmem ---"
cd "$workdir/mesa"
git checkout .
git clean -fd
apply_sysmem_patch
build_variant "Sysmem" "sysmem"

# 2. BUILD ONEUI / A740
echo "--- Preparing OneUI ---"
cd "$workdir/mesa"
git checkout .
git clean -fd
apply_oneui_patch
build_variant "OneUI_Fix" "oneui"

# 3. BUILD A6XX + SYSMEM
echo "--- Preparing A6xx + Sysmem ---"
cd "$workdir/mesa"
git checkout .
git clean -fd
apply_a6xx_patch
apply_sysmem_patch
build_variant "A6xx_Sysmem" "a6xx"

# 4. BUILD AUTOTUNER
echo "--- Preparing Autotuner ---"
cd "$workdir/mesa"
git checkout .
git clean -fd
echo "Fetching Autotuner MR..."
git fetch origin refs/merge-requests/37802/head
git merge --no-edit FETCH_HEAD
build_variant "Autotuner" "autotuner"

echo -e "${green}All builds finished!${nocolor}"
ls -lh *.zip
