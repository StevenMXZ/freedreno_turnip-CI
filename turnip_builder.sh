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
	
	# LIMPEZA TOTAL (Essencial para evitar erros antigos)
	if [ -d mesa ]; then rm -rf mesa; fi
	
	# Clone rápido (Depth 1 é seguro aqui pois usamos SED, não Merge)
	git clone --depth=1 "$mesa_repo" mesa
	cd mesa

    # --- FIX: OneUI / HyperOS 3 (A740 UBWC Hint) ---
    echo -e "${green}Applying OneUI/HyperOS A740 Fix (Force UBWC Hint)...${nocolor}"
    
    # O arquivo onde a instância Vulkan é criada
    local target_file="src/freedreno/vulkan/tu_instance.c"
    
    if [ -f "$target_file" ]; then
        # 1. Adiciona <stdlib.h> no topo para o comando setenv funcionar
        sed -i '1i #include <stdlib.h>' "$target_file"
        
        # 2. Injeta o setenv antes da inicialização do dispositivo físico
        # Isso força a flag 'enable_tp_ubwc_flag_hint=1' dentro do driver
        sed -i '/result = tu_physical_device_init/i setenv("FD_DEV_FEATURES", "enable_tp_ubwc_flag_hint=1", 1);' "$target_file"
    else
        echo -e "${red}Aviso: $target_file não encontrado. O fix não foi aplicado.${nocolor}"
    fi
    # -----------------------------------------------

	commit_hash=$(git rev-parse HEAD)
	if [ -f VERSION ]; then
	    version_str=$(cat VERSION | xargs)
	else
	    version_str="unknown"
	fi

	cd "$workdir"
}

compile_mesa(){
	echo -e "${green}Compiling Mesa...${nocolor}"

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

    # Configuração Release (Clean)
    # Sem as flags extras de libarchive pois estamos num ambiente limpo
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
		2>&1 | tee "$workdir/meson_log"

	ninja -C "$build_dir" 2>&1 | tee "$workdir/ninja_log"
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        echo -e "${red}Mesa build failed.${nocolor}"
        exit 1
    fi
}

package_driver(){
	local source_dir="$workdir/mesa"
	local build_dir="$source_dir/build"
	local lib_path="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"
	local package_temp="$workdir/package_temp"

    local lib_name="vulkan.ad07xx.so"

	if [ ! -f "$lib_path" ]; then
		echo -e "${red}Build failed: libvulkan_freedreno.so not found.${nocolor}"
		exit 1
	fi

	rm -rf "$package_temp"
	mkdir -p "$package_temp"
	cp "$lib_path" "$package_temp/lib_temp.so"

	cd "$package_temp"
	patchelf --set-soname "$lib_name" lib_temp.so
	mv lib_temp.so "$lib_name"

	local date_meta=$(date +'%b %d, %Y')
	local short_hash=${commit_hash:0:7}
	local meta_name="Turnip-A740-Fix-${short_hash}"
	
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "Clean Main + OneUI/HyperOS UBWC Fix (A740). Commit $short_hash",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "$lib_name"
}
EOF

	local zip_name="Turnip-A740-Fix-${short_hash}.zip"
	zip -9 "$workdir/$zip_name" "$lib_name" meta.json
	echo -e "${green}Package ready: $workdir/$zip_name${nocolor}"
}

generate_release_info() {
    echo -e "${green}Generating release info...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
	local short_hash=${commit_hash:0:7}

    echo "Turnip-A740-${date_tag}-${short_hash}" > tag
    echo "Turnip A740 Fix - ${date_tag}" > release

    echo "Turnip build com correção para OneUI/HyperOS (Adreno 740)." > description
    echo "" >> description
    echo "**Fix:** Enable UBWC Flag Hint (Forced)" >> description
    echo "**Commit:** [${short_hash}](${mesa_repo%.git}/-/commit/${commit_hash})" >> description
}

check_deps
prepare_ndk
prepare_source
compile_mesa
package_driver
generate_release_info
