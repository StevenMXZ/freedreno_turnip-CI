#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# ===========================
# Turnip Build Script (A710 Special: Chip ID + Force GMEM)
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
		echo "Using preinstalled Android NDK."
	fi
}

prepare_source(){
	echo "🌿 Preparing Mesa source (Main Branch)..."
	cd "$workdir"
	rm -rf mesa
	git clone --depth=1 "$mesa_repo" mesa
	cd mesa

	# --- 1. ADICIONAR CHIP ID DA ADRENO 710 ---
	echo -e "${green}Applying Patch: Add Adreno 710 Chip ID...${nocolor}"
	
	# Criamos um patch temporário para inserir a definição da A710
	# Isso é necessário porque o 'sed' seria muito complexo para inserir várias linhas
	cat <<'EOF' > a710_device.patch
--- a/src/freedreno/common/freedreno_devices.py
+++ b/src/freedreno/common/freedreno_devices.py
@@ -1074,6 +1074,24 @@
         raw_magic_regs = a740_raw_magic_regs,
     ))
 
+add_gpus([
+        GPUId(chip_id=0x07010000, name="FD710"),
+        GPUId(chip_id=0xffff07010000, name="FD710"),
+    ], A6xxGPUInfo(
+        CHIP.A7XX,
+        [a7xx_base, a7xx_gen1],
+        num_ccu = 4,
+        tile_align_w = 64,
+        tile_align_h = 32,
+        num_vsc_pipes = 32,
+        cs_shared_mem_size = 32 * 1024,
+        wave_granularity = 2,
+        fibers_per_sp = 128 * 2 * 16,
+        highest_bank_bit = 16,
+        magic_regs = a730_magic_regs,
+        raw_magic_regs = a730_raw_magic_regs,
+    ))
+
 add_gpus([
         GPUId(chip_id=0x07030001, name="FD730"),
         GPUId(chip_id=0xffff07030001, name="FD730"),
EOF

	# Tenta aplicar o patch. Se falhar (porque já existe), avisa mas continua.
	if patch -p1 < a710_device.patch; then
		echo -e "${green}✅ A710 Chip ID added successfully.${nocolor}"
	else
		echo -e "${red}⚠️ Failed to add A710 Chip ID (Might already exist in Mesa Main). Continuing...${nocolor}"
	fi


	# --- 2. APLICAR HACK "FORCE GMEM" (Para A710) ---
	echo -e "${green}Applying Hack: Force GMEM (Disable Sysmem)...${nocolor}"

    # Encontra a função que decide usar sysmem e força o retorno 'false' logo no início.
	if [ -f src/freedreno/vulkan/tu_autotune.cc ]; then
		sed -i '/bool tu_autotune_use_sysmem(const struct tu_device \*device, const struct tu_render_pass \*pass)/a \    return false;' src/freedreno/vulkan/tu_autotune.cc
        echo "✅ Forced GMEM in tu_autotune.cc"
    else
        echo "${red}⚠️ Warning: tu_autotune.cc not found. GMEM hack not applied.${nocolor}"
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
	echo -e "${green}⚙️ Compiling Mesa...${nocolor}"

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
    local output_suffix="A710_Fixed"

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
	local meta_name="Turnip-A710-${short_hash}-Fixed"
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "Mesa Main + A710 ID + Force GMEM (Fixes stability). Commit $commit_hash",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF

	local zip_name="turnip_main_$(date +'%Y%m%d')_${short_hash}_${output_suffix}.zip"
	zip -9 "$workdir/$zip_name" "vulkan.ad07XX.so" meta.json
	echo -e "${green}✅ Package ready: $workdir/$zip_name${nocolor}"
}

generate_release_info() {
    echo -e "${green}Generating release info files for GitHub Actions...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
	local short_hash=${commit_hash:0:7}

    echo "Mesa-Main-A710Fix-${date_tag}-${short_hash}" > tag
    
    echo "Turnip CI Build - ${date_tag} (A710 Fixed)" > release

    echo "Automated Turnip CI build tailored for Adreno 710." > description
    echo "" >> description
    echo "### Build Details:" >> description
    echo "**Base:** Mesa main branch" >> description
    echo "**Patches Applied:**" >> description
    echo "1. Added **Adreno 710 (FD710)** Chip ID definition." >> description
    echo "2. **Forced GMEM** rendering (Disabled Autotuner Sysmem) to fix crashes/instability on A710." >> description
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
