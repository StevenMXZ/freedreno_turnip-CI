#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
sdkver="35"
mesa_repo="https://gitlab.freedesktop.org/mesa/mesa.git"

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
	echo "Preparing NDK ..."
	mkdir -p "$workdir"
	cd "$workdir"
	if [ -z "${ANDROID_NDK_LATEST_HOME}" ]; then
		if [ ! -d "$ndkver" ]; then
			echo "Downloading Android NDK ..."
			curl -L "https://dl.google.com/android/repository/${ndkver}-linux.zip" --output "${ndkver}-linux.zip" &> /dev/null
			echo "Extracting NDK ..."
			unzip -q "${ndkver}-linux.zip" &> /dev/null
		fi
        export ANDROID_NDK_HOME="$workdir/$ndkver"
	else
		echo "Using preinstalled Android NDK."
        export ANDROID_NDK_HOME="$ANDROID_NDK_LATEST_HOME"
	fi
}

prepare_source(){
	echo "Preparing Mesa source..."
	cd "$workdir"
	
	# Limpeza inicial total
	if [ -d mesa ]; then rm -rf mesa; fi
	
	# Clone limpo (sem depth=1 para facilitar o fetch da MR do autotuner depois)
	git clone "$mesa_repo" mesa
	cd mesa

    git config user.name "CI Builder"
    git config user.email "ci@builder.com"

	commit_hash=$(git rev-parse HEAD)
	if [ -f VERSION ]; then
	    version_str=$(cat VERSION | xargs)
	else
	    version_str="unknown"
	fi

	cd "$workdir"
}

# Função genérica para compilar e empacotar
do_build_cycle(){
    local build_name="$1"
    local zip_tag="$2"
    
    echo -e "${green}>>> Starting Build: $build_name${nocolor}"

	local source_dir="$workdir/mesa"
	local build_dir="$source_dir/build"
	
    # Limpa build anterior
    rm -rf "$build_dir"
	
	local ndk_root_path="$ANDROID_NDK_HOME"
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
pkg-config = '/usr/bin/pkg-config'

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
		-Dvulkan-beta=false \
		-Ddefault_library=shared \
		2>&1 | tee "$workdir/meson_log_${zip_tag}"

	ninja -C "$build_dir" 2>&1 | tee "$workdir/ninja_log_${zip_tag}"
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        echo -e "${red}Build $build_name failed.${nocolor}"
        exit 1
    fi

    # Empacotamento
	local lib_path="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"
	local package_temp="$workdir/package_temp"
    local lib_name="vulkan.ad07xx.so" 

	rm -rf "$package_temp"
	mkdir -p "$package_temp"
	cp "$lib_path" "$package_temp/lib_temp.so"

	cd "$package_temp"
	patchelf --set-soname "$lib_name" lib_temp.so
	mv lib_temp.so "$lib_name"

    # Pega o hash atual (pode mudar se for MR)
    local current_hash=$(git rev-parse --short HEAD)
	local meta_name="Turnip-${zip_tag}-${current_hash}"
	
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "Variant: $build_name. Hash: $current_hash",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "$lib_name"
}
EOF

	local zip_name="Turnip-${zip_tag}-${current_hash}.zip"
	zip -9 "$workdir/$zip_name" "$lib_name" meta.json
	echo -e "${green}Package ready: $workdir/$zip_name${nocolor}"
    cd "$workdir"
}

# --- Lógica Principal ---

check_deps
prepare_ndk
prepare_source

# 1. BUILD SYSMEM (Aplica patch tu_cmd_buffer.cc)
echo -e "${green}=== 1/4: Building Sysmem Version ===${nocolor}"
cd "$workdir/mesa"
git checkout . 
git clean -fd

file_sysmem="src/freedreno/vulkan/tu_cmd_buffer.cc"
if [ -f "$file_sysmem" ]; then
    echo "Applying Sysmem patch..."
    sed -i '/if (TU_DEBUG(SYSMEM)) {/i \   return true;' "$file_sysmem"
else
    echo -e "${red}Erro: Arquivo $file_sysmem não encontrado!${nocolor}"
fi
do_build_cycle "Sysmem (Forced)" "Sysmem"


# 2. BUILD ONEUI FIX (Aplica patch freedreno_devices.py)
echo -e "${green}=== 2/4: Building OneUI/HyperOS Fix Version ===${nocolor}"
cd "$workdir/mesa"
git checkout .
git clean -fd

file_devs="src/freedreno/common/freedreno_devices.py"
if [ -f "$file_devs" ]; then
    echo "Applying OneUI/HyperOS Fix patch..."
    sed -i 's/\[a7xx_base, a7xx_gen2\]/\[a7xx_base, a7xx_gen2, GPUProps(enable_tp_ubwc_flag_hint = True)\]/' "$file_devs"
else
    echo -e "${red}Erro: Arquivo $file_devs não encontrado!${nocolor}"
fi
do_build_cycle "OneUI-Fix" "OneUI_Fix"


# 3. BUILD A6XX + SYSMEM (Patch A6xx + Patch Sysmem)
echo -e "${green}=== 3/4: Building A6xx + Sysmem Version ===${nocolor}"
cd "$workdir/mesa"
git checkout .
git clean -fd

echo "Applying A6xx Stability Patches..."
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

echo "Applying Sysmem patch (on top of A6xx)..."
if [ -f "$file_sysmem" ]; then
    sed -i '/if (TU_DEBUG(SYSMEM)) {/i \   return true;' "$file_sysmem"
fi
do_build_cycle "A6xx-Sysmem" "A6xx_Sysmem"


# 4. BUILD AUTOTUNER (MR !37802)
echo -e "${green}=== 4/4: Building Autotuner (MR !37802) ===${nocolor}"
cd "$workdir/mesa"
git checkout .
git clean -fd

echo "Fetching MR !37802..."
git fetch origin refs/merge-requests/37802/head
git checkout FETCH_HEAD

do_build_cycle "Autotuner" "Autotuner"


# Finalização
echo -e "${green}All 4 builds completed!${nocolor}"
cd "$workdir"
ls -lh *.zip
