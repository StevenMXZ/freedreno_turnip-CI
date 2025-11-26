#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# ===========================
# Turnip Build Script (Mesa Main + Unsup GPUs GMEM Patch)
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
	# Clone raso do branch 'main'
	git clone --depth=1 "$mesa_repo" mesa
	cd mesa

	# --- APLICANDO O PATCH UNSUP GPUS GMEM ---
	echo -e "${green}Applying Unsupported GPUs GMEM patch...${nocolor}"

    # Criando o arquivo de patch com o conteúdo exato que você enviou
	cat <<'EOF' > "$workdir/unsup_gpus_gmem.patch"
diff --git a/src/freedreno/vulkan/tu_autotune.cc b/src/freedreno/vulkan/tu_autotune.cc
index 23c37d2d8c4..8e079f9042e 100644
--- a/src/freedreno/vulkan/tu_autotune.cc
+++ b/src/freedreno/vulkan/tu_autotune.cc
@@ -1493,6 +1493,13 @@ tu_autotune_use_sysmem(struct tu_device *device,
    if (render_area.width * render_area.height < MIN_SYSMEM_PIXELS)
       return true;
 
+   /* For some unsupported GPUs, we need to force GMEM */
+   if (device->physical_device->info->chip == 710 ||
+       device->physical_device->info->chip == 720 ||
+       device->physical_device->info->chip == 722 ||
+       device->physical_device->info->chip == 725)
+      return false;
+
    /* If the user forced a mode, use it. */
    if (autotune->force_mode != render_mode::NONE)
       return autotune->force_mode == render_mode::SYSMEM;
EOF

    # Aplicando o patch
    if patch -p1 < "$workdir/unsup_gpus_gmem.patch"; then
        echo -e "${green}✅ Patch 'unsup_gpus_gmem' applied successfully!${nocolor}"
    else
        echo -e "${red}❌ Failed to apply patch. Check if tu_autotune.cc changed.${nocolor}"
        exit 1
    fi
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
	local output_suffix="unsup_gmem"

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
	local meta_name="Turnip-Main-${short_hash}-UnsupGMEM"
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "Mesa Main + Forced GMEM for A710/720/722/725. Commit $commit_hash",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF

	local zip_name="turnip_$(date +'%Y%m%d')_${short_hash}_${output_suffix}.zip"
	zip -9 "$workdir/$zip_name" "vulkan.ad07XX.so" meta.json
	echo -e "${green}✅ Package ready: $workdir/$zip_name${nocolor}"
}

generate_release_info() {
    echo -e "${green}Generating release info files for GitHub Actions...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
	local short_hash=${commit_hash:0:7}

    echo "Mesa-Main-UnsupGMEM-${date_tag}-${short_hash}" > tag
    echo "Turnip CI Build - ${date_tag} (Unsup GPUs GMEM)" > release

    echo "Automated Turnip CI build from the latest Mesa main branch." > description
    echo "" >> description
    echo "### Build Details:" >> description
    echo "**Base:** Mesa main branch" >> description
    echo "**Patch Applied:** Forced GMEM path for unsupported GPUs (710, 720, 722, 725)." >> description
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
