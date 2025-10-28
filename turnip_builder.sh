#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# --- Config ---
deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
sdkver="35"
mesasrc="https://gitlab.freedesktop.org/Danil/mesa.git"
target_branch="tu-newat-fixes"

# --- Variáveis Globais ---
commit_target=""
version_target=""

clear

# --- Funções Auxiliares ---
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
		echo "Please install missing dependencies" && exit 1
	fi
	pip install mako &> /dev/null || true
}

prepare_ndk(){
	echo "Preparing NDK ..."
	cd "$workdir"
	if [ -z "${ANDROID_NDK_LATEST_HOME}" ]; then
		if [ ! -d "$ndkver" ]; then
			echo "Downloading android-ndk ..."
			curl https://dl.google.com/android/repository/"$ndkver"-linux.zip --output "$ndkver"-linux.zip &> /dev/null
			echo "Exracting android-ndk ..."
			unzip "$ndkver"-linux.zip  &> /dev/null
		fi
	else
		echo "Using android ndk from github image"
	fi
}

compile_mesa() {
    local source_dir=$1
    local build_dir_name=$2
    local description=$3

    echo -e "${green}--- Compiling: $description ---${nocolor}"
    cd "$source_dir"

	local ndk_root_path
	if [ -z "${ANDROID_NDK_LATEST_HOME}" ]; then
		ndk_root_path="$workdir/$ndkver"
	else	
		ndk_root_path="$ANDROID_NDK_LATEST_HOME"
	fi
	local ndk_bin_path="$ndk_root_path/toolchains/llvm/prebuilt/linux-x86_64/bin"
	local ndk_sysroot_path="$ndk_root_path/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

	local cross_file_path="$source_dir/android-aarch64-crossfile.txt"
	cat <<EOF >"$cross_file_path"
[binaries]
ar = '$ndk_bin_path/llvm-ar'
c = ['ccache', '$ndk_bin_path/aarch64-linux-android$sdkver-clang', '--sysroot=$ndk_sysroot_path']
cpp = ['ccache', '$ndk_bin_path/aarch64-linux-android$sdkver-clang++', '--sysroot=$ndk_sysroot_path', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$ndk_bin_path/aarch64-linux-android-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$ndk_bin_path/pkg-config', '/usr/bin/pkg-config']
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

	echo "Generating build files for $description..."
	meson setup --reconfigure "$build_dir_name" --cross-file "$cross_file_path" -Dbuildtype=release -Dplatforms=android -Dplatform-sdk-version=$sdkver -Dandroid-stub=true -Dgallium-drivers= -Dvulkan-drivers=freedreno -Dvulkan-beta=true -Dfreedreno-kmds=kgsl -Db_lto=true -Degl=disabled 2>&1 | tee "$workdir/meson_log_$description"

	echo "Compiling $description..."
	ninja -C "$build_dir_name" 2>&1 | tee "$workdir/ninja_log_$description"

    local compiled_lib="$source_dir/$build_dir_name/src/freedreno/vulkan/libvulkan_freedreno.so"
	if [ ! -f "$compiled_lib" ]; then
		echo -e "${red}Build failed for $description: libvulkan_freedreno.so not found.${nocolor}"
		exit 1
	fi
    echo -e "${green}--- Finished Compiling: $description ---${nocolor}\n"
    cd "$workdir"
}

package_driver() {
    local source_dir=$1
    local build_dir_name=$2
    local description_name=$3
    local version_str=$4
    local commit_hash_short=$5
    local commit_hash_full=$6
    local repo_url=$7
    local output_suffix="dspm_dyn"

    echo -e "${green}--- Packaging: $description_name ---${nocolor}"
    local compiled_lib="$workdir/$source_dir/$build_dir_name/src/freedreno/vulkan/libvulkan_freedreno.so"
    local package_temp_dir="$workdir/package_temp_single"
    
    local lib_final_name="vulkan.ad07XX.so" 
    local soname="vulkan.adreno.so" 

    local output_filename="turnip_$(date +'%Y%m%d')_${commit_hash_short}_${output_suffix}.zip"

    mkdir -p "$package_temp_dir"
    
    cp "$compiled_lib" "$package_temp_dir/lib_temp.so"
    cd "$package_temp_dir"
    
    patchelf --set-soname "$soname" lib_temp.so
    mv lib_temp.so "$lib_final_name"

	date_meta=$(date +'%b %d, %Y')
	# --- ALTERADO: Nome simplificado para evitar problemas de caminho ---
    local meta_name="Turnip-Danil-${commit_hash_short}-DSPM"
    # --- FIM ALTERADO ---
	cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "Compiled from $description_name, Commit $commit_hash_short",
  "author": "mesa-ci",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "$version_str",
  "minApi": 27,
  "libraryName": "$lib_final_name"
}
EOF

	echo "Packing $output_filename..."
	zip -9 "$workdir/$output_filename" "$lib_final_name" meta.json
    
    if ! [ -f "$workdir/$output_filename" ]; then
		echo -e "$red Packaging failed for $description_name! $nocolor" && exit 1
	else
		echo -e "$green Package ready: $workdir/$output_filename $nocolor"
	fi

    rm -rf "$package_temp_dir"
    cd "$workdir"
    echo -e "${green}--- Finished Packaging: $description_name ---${nocolor}\n"
}

build_danil_patched_dspm_dyn() {
    local dir_name="mesa_danil_patched_dspm_dyn"
    local build_dir="build-danil-patched-dspm-dyn"
    local description="Danil's Fork $target_branch (Patched: Disable SPM Dynamic Input)"
    local patch_file_name="0002-Disable-single-prim-mode-for-dynamic-input-attachmen.patch"
    echo -e "${green}=== Building $description ===${nocolor}"
    git clone "$mesasrc" "$dir_name"
    cd "$dir_name"
    
    echo -e "${green}Checking out branch '$target_branch'...${nocolor}"
    git checkout "$target_branch"
    
    echo "Creating $patch_file_name file..."
    cat << 'EOF' > "$workdir/$patch_file_name"
From 997218fbf9e22e3b038df29bb4d82bc33e897bdd Mon Sep 17 00:00:00 2001
From: Dhruv Mark Collins <mark@igalia.com>
Date: Tue, 28 Oct 2025 19:11:20 +0000
Subject: [PATCH 2/2] Disable single prim mode for dynamic input attachments

---
 src/freedreno/vulkan/tu_pipeline.cc | 3 +--
 1 file changed, 1 insertion(+), 2 deletions(-)

diff --git a/src/freedreno/vulkan/tu_pipeline.cc b/src/freedreno/vulkan/tu_pipeline.cc
index bfb16340229..726b422577e 100644
--- a/src/freedreno/vulkan/tu_pipeline.cc
+++ b/src/freedreno/vulkan/tu_pipeline.cc
@@ -3567,8 +3567,7 @@ tu6_emit_prim_mode_sysmem(struct tu_cs *cs,
     * for advanced_blend in sysmem mode if a feedback loop is detected.
     */
    enum a6xx_single_prim_mode sysmem_prim_mode =
-      (raster_order_attachment_access || feedback_loops ||
-       fs->fs.dynamic_input_attachments_used) ?
+      (raster_order_attachment_access || feedback_loops) ?
       FLUSH_PER_OVERLAP_AND_OVERWRITE : NO_FLUSH;
 
    if (sysmem_prim_mode == FLUSH_PER_OVERLAP_AND_OVERWRITE)
-- 
2.49.0

EOF

    echo "Applying $patch_file_name..."
    if git apply "$workdir/$patch_file_name"; then
        echo -e "${green}Patch applied successfully!${nocolor}\n"
    else
        echo -e "${red}Failed to apply $patch_file_name to branch $target_branch.${nocolor}"
        exit 1
    fi

    commit_target=$(git rev-parse HEAD)
    version_target=$(cat VERSION | xargs)
    cd ..
    compile_mesa "$workdir/$dir_name" "$build_dir" "$description"
    package_driver "$dir_name" "$build_dir" "$description" "$version_target" "$(git -C $dir_name rev-parse --short HEAD)" "$commit_target" "$mesasrc"
}


generate_release_info() {
    echo -e "${green}Generating release info files for GitHub Actions...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
    local target_commit_short=$(git -C mesa_danil_patched_dspm_dyn rev-parse --short HEAD)

    echo "Danil-${date_tag}-${target_commit_short}" > tag
    echo "Turnip CI Build - ${date_tag} (Danil's Fork + Disable SPM Dynamic Input Patch)" > release

    echo "Automated Turnip CI build." > description
    echo "" >> description
    echo "### Build Details:" >> description
    echo "**Base:** Danil's Mesa fork, branch \`$target_branch\`" >> description
    echo "**Patch Applied:** Disable single prim mode for dynamic input attachments." >> description
    echo "**Commit:** [${target_commit_short}](${mesasrc%.git}/-/commit/${commit_target})" >> description
    
    echo -e "${green}Release info generated.${nocolor}"
}


# --- Execução Principal ---
check_deps
mkdir -p "$workdir" 
prepare_ndk

build_danil_patched_dspm_dyn

generate_release_info

echo -e "${green}Build completed successfully!${nocolor}"
