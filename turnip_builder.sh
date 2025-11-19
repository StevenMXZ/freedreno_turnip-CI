#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# ===========================
# Turnip Build Script (Mesa Main + Fix A619 Freeze)
# ===========================

deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
sdkver="35"

mesa_repo="https://gitlab.freedesktop.org/mesa/mesa.git"

commit_hash=""
version_str=""

# ===========================
# Funções
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
		echo "Using preinstalled Android NDK from GitHub Actions image."
	fi
}

prepare_source(){
	echo "🌿 Preparing Mesa source (Main Branch)..."
	cd "$workdir"
	rm -rf mesa
	# Clone raso do branch 'main'
	git clone --depth=1 "$mesa_repo" mesa
	cd mesa

	# --- APLICANDO CORREÇÃO PARA A619 (Revertendo lógica de cache) ---
	echo -e "${green}Applying fixes for A619 freeze (cached memory)...${nocolor}"

	# 1. Reverte a mudança específica da commit 83212054e07 em tu_query.cc (se o arquivo existir)
	if [ -f src/freedreno/vulkan/tu_query.cc ]; then
		sed -i 's/tu_bo_init_new_cached/tu_bo_init_new/g' src/freedreno/vulkan/tu_query.cc
		echo "Reverted tu_bo_init_new_cached in tu_query.cc"
	fi

	# 2. Abordagem Nuclear: Encontra onde a flag de cache é usada e a desativa.
	# Isso garante que nenhuma outra parte do código consiga habilitar o cache de CPU.
	grep -rl "VK_MEMORY_PROPERTY_HOST_CACHED_BIT" src/freedreno/vulkan/ | while read file; do
		# Substitui a lógica ternária "(condição ? CACHED_BIT : 0)" por "0"
		sed -i 's/dev->physical_device->has_cached_coherent_memory ? VK_MEMORY_PROPERTY_HOST_CACHED_BIT : 0/0/g' "$file" || true
		# Substitui apenas a flag se ela estiver solta
		sed -i 's/VK_MEMORY_PROPERTY_HOST_CACHED_BIT/0/g' "$file" || true
		echo "Disabled Cached Bit in $file"
	done

	echo -e "${green}✅ Fixes applied: Query Pools reverted & Cached Memory disabled globally.${nocolor}"
	# ------------------------------------------------------------

	commit_hash=$(git rev-parse HEAD)
	if [ -f VERSION ]; then
	    version_str=$(cat VERSION | xargs)
	else
	    version_str="unknown"
	fi

	cd "$workdir"
}

compile_mesa(){
	echo -e "${green}⚙️ Compiling Mesa (Main Branch)...${nocolor}"

	local source_dir="$workdir/mesa"
	local build_dir="$source_dir/build"
	
	local ndk_root_path
	if [ -z "${ANDROID_NDK_LATEST_HOME}" ]; then
		ndk_root_path="$workdir/$ndkver"
	else
		ndk_root_path="$ANDROID_NDK_LATEST_HOME"
	fi

	local ndk_bin_path="$ndk_root_path/toolchains/llvm/prebuilt/linux-x86_64/bin"
	local ndk_sysroot_path="$ndk_root_path/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

	local cross_file="$source_dir/android-aarch64-crossfile.txt"
	cat <<EOF > "$cross_file"
[binaries]
ar = '$ndk_bin_path/llvm-ar'
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

	cd "$source_dir"

	# Variáveis de ambiente para ajudar na compilação
	export LIBRT_LIBS=""
	export CFLAGS="-D__ANDROID__"
	export CXXFLAGS="-D__ANDROID__"

	# REMOVIDO: -Dhave_librt=false (causava erro) e -Dshared-glapi=enabled (depreciado)
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
		-Db_lto=true \
		-Dvulkan-beta=true \
		-Ddefault_library=shared \
		2>&1 | tee "$workdir/meson_log"

	if [ ! -f "$build_dir/build.ninja" ]; then
		echo -e "${red}meson setup failed — see $workdir/meson_log for details${nocolor}"
		exit 1
	fi

	ninja -C "$build_dir" 2>&1 | tee "$workdir/ninja_log"
}

package_driver(){
	local source_dir="$workdir/mesa"
	local build_dir="$source_dir/build"
	local lib_path="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"
	local package_temp="$workdir/package_temp"
	local output_suffix="no_cached_mem"

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

	local date_meta=$(date +'%b %d, %Y')
	local short_hash=${commit_hash:0:7}
	local meta_name="Turnip-Main-${short_hash}-FixA619"
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "Built from Mesa main. Includes reverts for A619 freeze (No Cached Memory). Commit $commit_hash",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF

	local zip_name="turnip_$(date +'%Y%m%d')_${short_hash}_fix_a619.zip"
	zip -9 "$workdir/$zip_name" "vulkan.ad07XX.so" meta.json
	echo -e "${green}✅ Package ready: $workdir/$zip_name${nocolor}"
}

generate_release_info() {
    echo -e "${green}Generating release info files for GitHub Actions...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
	local short_hash=${commit_hash:0:7}

    echo "Mesa-Main-FixA619-${date_tag}-${short_hash}" > tag
    
    echo "Turnip CI Build - ${date_tag} (Main + Fix A619 Freeze)" > release

    echo "Automated Turnip CI build from the latest Mesa main branch." > description
    echo "" >> description
    echo "### Build Details:" >> description
    echo "**Base:** Mesa main branch" >> description
    echo "**Patches Applied:**" >> description
    echo "1. Reverted \`tu_bo_init_new_cached\` usage in \`tu_query.cc\`." >> description
    echo "2. Globally disabled \`VK_MEMORY_PROPERTY_HOST_CACHED_BIT\`." >> description
    echo "**Purpose:** Fix system freezes on Adreno 619/6xx devices caused by broken IO coherency." >> description
    echo "**Commit:** [${short_hash}](${mesa_repo%.git}/-/commit/${commit_hash})" >> description
    
    echo -e "${green}Release info generated.${nocolor}"
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
