#!/bin/bash -e
set -o pipefail

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"

# --- CONFIGURAÇÃO EXTREMA ---
# Usamos NDK r28 (Stable Latest) para suporte máximo
ndkver="android-ndk-r28"
# ALVO: Android 16 (API 36)
target_sdk="36" 

# REPOSITÓRIOS
base_repo="https://gitlab.freedesktop.org/robclark/mesa.git"
base_branch="tu/gen8"
hacks_repo="https://github.com/whitebelyash/mesa-tu8.git"
hacks_branch="gen8-hacks"

commit_hash=""
version_str=""

check_deps(){
	echo "Checking system dependencies ..."
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
	echo "Preparing NDK r28..."
	mkdir -p "$workdir"
	cd "$workdir"
	if [ ! -d "$ndkver" ]; then
		echo "Downloading Android NDK $ndkver..."
		curl -L "https://dl.google.com/android/repository/${ndkver}-linux.zip" --output "${ndkver}-linux.zip" &> /dev/null
		echo "Extracting NDK..."
		unzip -q "${ndkver}-linux.zip" &> /dev/null
	fi
    export ANDROID_NDK_HOME="$workdir/$ndkver"
}

prepare_source(){
	echo "Preparing Mesa source..."
	cd "$workdir"
	if [ -d mesa ]; then rm -rf mesa; fi
	
    # 1. Clona BASE (Rob Clark Recente)
    echo "Cloning Base: $base_repo ($base_branch)..."
	git clone --branch "$base_branch" "$base_repo" mesa
	cd mesa

    # Configura Git Identity para o merge
    git config user.email "ci@turnip.builder"
    git config user.name "Turnip CI Builder"

    # 2. Traz HACKS (Whitebelyash)
    echo "Fetching Hacks from: $hacks_repo..."
    git remote add hacks "$hacks_repo"
    git fetch hacks "$hacks_branch"
    
    echo "Attempting FORCE MERGE (-X theirs)..."
    # Tenta fundir. Se der conflito, o código do Hack VENCE (theirs).
    git merge --no-edit -X theirs "hacks/$hacks_branch" --allow-unrelated-histories || {
        echo -e "${red}Merge failed critically. Continuing might produce broken code.${nocolor}"
        exit 1
    }

    # --- SPIRV Manual (Obrigatório) ---
    echo "Manually cloning dependencies to subprojects..."
    mkdir -p subprojects
    cd subprojects
    rm -rf spirv-tools spirv-headers
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Headers.git spirv-headers
    cd .. 
    
	commit_hash=$(git rev-parse HEAD)
	version_str="API36-BleedingEdge"
	cd "$workdir"
}

compile_mesa(){
	echo -e "${green}Compiling Mesa for SDK $target_sdk...${nocolor}"

	local source_dir="$workdir/mesa"
	local build_dir="$source_dir/build"
	
	local ndk_root_path="$ANDROID_NDK_HOME"
	local ndk_bin_path="$ndk_root_path/toolchains/llvm/prebuilt/linux-x86_64/bin"
	local ndk_sysroot_path="$ndk_root_path/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

    # --- TRUQUE DO COMPILADOR (Fix para "No such file") ---
    # O binário android36-clang geralmente não existe ainda.
    # Usamos o 35 ou 34 como binário, mas o Meson vai usar a flag -Dplatform-sdk-version=36
    local compiler_ver="35"
    if [ ! -f "$ndk_bin_path/aarch64-linux-android${compiler_ver}-clang" ]; then
        compiler_ver="34" # Fallback garantido
    fi
    echo "Using compiler binary version: $compiler_ver (Targeting API $target_sdk)"

	local cross_file="$source_dir/android-aarch64-crossfile.txt"
    
	cat <<EOF > "$cross_file"
[binaries]
ar = '$ndk_bin_path/llvm-ar'
c = ['ccache', '$ndk_bin_path/aarch64-linux-android${compiler_ver}-clang', '--sysroot=$ndk_sysroot_path']
cpp = ['ccache', '$ndk_bin_path/aarch64-linux-android${compiler_ver}-clang++', '--sysroot=$ndk_sysroot_path', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$ndk_bin_path/aarch64-linux-android-strip'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

	cd "$source_dir"

	export LIBRT_LIBS=""
	export CFLAGS="-D__ANDROID__"
	export CXXFLAGS="-D__ANDROID__"

    # CORREÇÃO APLICADA: -Dlibarchive=disabled REMOVIDO
	meson setup "$build_dir" --cross-file "$cross_file" \
		-Dbuildtype=release \
		-Dplatforms=android \
		-Dplatform-sdk-version=$target_sdk \
		-Dandroid-stub=true \
		-Dgallium-drivers= \
		-Dvulkan-drivers=freedreno \
		-Dfreedreno-kmds=kgsl \
		-Degl=disabled \
		-Dglx=disabled \
		-Db_lto=true \
		-Dvulkan-beta=true \
		-Ddefault_library=shared \
        -Dzstd=disabled \
        --force-fallback-for=spirv-tools,spirv-headers \
		2>&1 | tee "$workdir/meson_log"

	ninja -C "$build_dir" 2>&1 | tee "$workdir/ninja_log"
}

package_driver(){
	local source_dir="$workdir/mesa"
	local build_dir="$source_dir/build"
	local lib_path="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"
	local package_temp="$workdir/package_temp"

	if [ ! -f "$lib_path" ]; then
		echo -e "${red}Build failed: libvulkan_freedreno.so not found.${nocolor}"
		exit 1
	fi

	rm -rf "$package_temp"
	mkdir -p "$package_temp"
	cp "$lib_path" "$package_temp/lib_temp.so"

	cd "$package_temp"
	patchelf --set-soname "vulkan.adreno.so" lib_temp.so
	mv lib_temp.so "vulkan.ad07XX.so"

	local short_hash=${commit_hash:0:7}
	local meta_name="Turnip-A830-SDK36-${short_hash}"
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "Turnip Gen8 (Bleeding Edge + Force Hacks) - SDK 36. Commit $short_hash",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF

	local zip_name="Turnip-A830-SDK36-${short_hash}.zip"
	zip -9 "$workdir/$zip_name" "vulkan.ad07XX.so" meta.json
	echo -e "${green}Package ready: $workdir/$zip_name${nocolor}"
}

generate_release_info() {
    echo -e "${green}Generating release info...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
	local short_hash=${commit_hash:0:7}

    echo "Turnip-A830-SDK36-${date_tag}-${short_hash}" > tag
    echo "Turnip A830 (SDK 36) - ${date_tag}" > release
    echo "Automated Turnip Build. Strategy: RobClark Base + Forced Hacks + SDK 36." > description
}

check_deps
prepare_ndk
prepare_source
compile_mesa
package_driver
generate_release_info
