#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# ===========================
# Turnip Build: Main + MR 38709 + A6xx Fix
# ===========================

deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
sdkver="35"

mesa_repo="https://gitlab.freedesktop.org/mesa/mesa.git"
mr_num="38709" # VK_EXT_legacy_vertex_attributes

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

prepare_source(){
	echo "🌿 Preparing Mesa source (Main Branch)..."
	cd "$workdir"
	if [ -d mesa ]; then rm -rf mesa; fi
	
    echo "Cloning Mesa Main..."
	# Clone completo para permitir merge
	git clone "$mesa_repo" mesa
	cd mesa

    # --- 1. MERGE DO MR 38709 ---
    echo -e "${green}Configuring git & merging MR !${mr_num}...${nocolor}"
	git config user.name "CI Builder"
	git config user.email "ci@builder.com"
    
    git fetch origin "refs/merge-requests/${mr_num}/head"
    if git merge --no-edit FETCH_HEAD; then
		echo -e "${green}✅ MR !${mr_num} merged successfully!${nocolor}"
	else
		echo -e "${red}❌ Merge failed for MR !${mr_num}. Aborting.${nocolor}"
		exit 1
	fi
    # ---------------------------

	# --- 2. APLICAR FIX DA A6XX (Nuclear) ---
	echo -e "${green}Applying A6xx Stability Fixes (No Cached Mem)...${nocolor}"

    # Reverter uso em tu_query.cc (se existir)
	if [ -f src/freedreno/vulkan/tu_query.cc ]; then
		sed -i 's/tu_bo_init_new_cached/tu_bo_init_new/g' src/freedreno/vulkan/tu_query.cc
        echo "✅ Reverted tu_bo_init_new_cached in tu_query.cc"
	fi

    # Desativar globalmente a flag de cache
	if [ -f src/freedreno/vulkan/tu_device.cc ]; then
        # Força a variável de capacidade para falso
		sed -i 's/physical_device->has_cached_coherent_memory = .*/physical_device->has_cached_coherent_memory = false;/' src/freedreno/vulkan/tu_device.cc || true
	fi
    
    # Substituição global da flag
	grep -rl "VK_MEMORY_PROPERTY_HOST_CACHED_BIT" src/freedreno/vulkan/ | while read file; do
		sed -i 's/dev->physical_device->has_cached_coherent_memory ? VK_MEMORY_PROPERTY_HOST_CACHED_BIT : 0/0/g' "$file" || true
		sed -i 's/VK_MEMORY_PROPERTY_HOST_CACHED_BIT/0/g' "$file" || true
	done
    echo -e "${green}✅ A6xx Nuclear Fix applied.${nocolor}"
	# ----------------------------------------

	commit_hash=$(git rev-parse --short HEAD)
	if [ -f VERSION ]; then
	    version_str=$(cat VERSION | xargs)
	else
	    version_str="unknown"
	fi

	cd "$workdir"
}

compile_mesa(){
	echo -e "${green}⚙️ Compiling Mesa...${nocolor}"

	local source_dir="$workdir/mesa"
	local build_dir="$source_dir/build"
	
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

	cd "$source_dir"

    # Flags limpas e corretas
	export LIBRT_LIBS=""
	export CFLAGS="-D__ANDROID__"
	export CXXFLAGS="-D__ANDROID__"

	meson setup "$build_dir" --cross-file "$cross_file" \
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

	local date_meta=$(date +'%Y-%m-%d')
    # Nome descritivo no meta.json
	local meta_name="Turnip-MR${mr_num}-${commit_hash}"
    
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "Mesa Main + MR !${mr_num} + A6xx Stability Fix. Commit $commit_hash",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF

    # Nome do zip
    local d_short=$(date +'%m%y')
	local zip_name="Turnip-MR${mr_num}-a6xx-${d_short}.zip"
	zip -9 "$workdir/$zip_name" "vulkan.ad07XX.so" meta.json
	echo -e "${green}✅ Package ready: $workdir/$zip_name${nocolor}"
}

generate_release_info() {
    echo -e "${green}Generating release info...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y-%m-%d')

    echo "Turnip-MR${mr_num}-${date_tag}" > tag
    echo "Turnip Build (MR !${mr_num}) - ${date_tag}" > release

    echo "Automated Turnip CI build." > description
    echo "" >> description
    echo "### Build Details:" >> description
    echo "- **Base:** Mesa Main" >> description
    echo "- **Feature:** Merged MR \`!${mr_num}\` (VK_EXT_legacy_vertex_attributes)." >> description
    echo "- **Fix:** A6xx Stability Fix (No Cached Memory)." >> description
    echo "- **Commit:** $commit_hash" >> description
}

# ===========================
# Execução
# ===========================
clear
check_deps
prepare_ndk
prepare_source
compile_mesa
package_driver
generate_release_info

echo -e "${green}🎉 Build completed successfully!${nocolor}"
