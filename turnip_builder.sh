#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
sdkver="35"
mesa_repo_main="https://gitlab.freedesktop.org/mesa/mesa.git"
autotuner_mr_num="37802"
mesa_tag_oneui="26.0.0"

commit_main=""
commit_dgmem_sp=""
commit_oneui=""
version_main=""
version_dgmem_sp=""
version_oneui=""

clear

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
    local output_suffix=$3
    local description_name=$4
    local version_str=$5
    local commit_hash_short=$6
    local commit_hash_full=$7
    local repo_url=$8

    echo -e "${green}--- Packaging: $description_name ---${nocolor}"
    local compiled_lib="$workdir/$source_dir/$build_dir_name/src/freedreno/vulkan/libvulkan_freedreno.so"
    local package_temp_dir="$workdir/package_temp_${output_suffix}"
    
    local lib_final_name="vulkan.ad07XX.so" 
    local soname="vulkan.adreno.so" 

    local filename_base="turnip_$(date +'%Y%m%d')_${commit_hash_short}"
    local output_filename
    if [[ "$output_suffix" == "main" ]]; then
        output_filename="${filename_base}.zip"
    else
        output_filename="${filename_base}_${output_suffix}.zip"
    fi

    mkdir -p "$package_temp_dir"
    
    cp "$compiled_lib" "$package_temp_dir/lib_temp.so"
    cd "$package_temp_dir"
    
    patchelf --set-soname "$soname" lib_temp.so
    mv lib_temp.so "$lib_final_name"

	date_meta=$(date +'%b %d, %Y')
	cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "Turnip ($description_name) - $date_meta - $commit_hash_short",
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

build_mesa_main() {
    local dir_name="mesa_main"
    local build_dir="build-main"
    echo -e "${green}=== Building Mesa Main ===${nocolor}"
    git clone --depth=1 "$mesa_repo_main" "$dir_name"
    cd "$dir_name"
    commit_main=$(git rev-parse HEAD)
    version_main=$(cat VERSION | xargs)
    cd ..
    compile_mesa "$workdir/$dir_name" "$build_dir" "Mesa_Main"
    package_driver "$dir_name" "$build_dir" "main" "Mesa Main" "$version_main" "$(git -C $dir_name rev-parse --short HEAD)" "$commit_main" "$mesa_repo_main"
}

build_mesa_main_dgmem_sp() {
    local dir_name="mesa_dgmem_sp"
    local build_dir="build-dgmem-sp"
    echo -e "${green}=== Building Mesa Main + Disable GMEM Single Prim Patch ===${nocolor}"
    git clone --depth=1 "$mesa_repo_main" "$dir_name"
    cd "$dir_name"
    
    echo "Creating Disable GMEM Single Prim patch file..."
    cat << 'EOF' > "$workdir/0001-Disable-GMEM-in-single-prim-mode.patch"
From 94a051bc7c78635617a1584a7accb94cc5b6ee7e Mon Sep 17 00:00:00 2001
From: Dhruv Mark Collins <mark@igalia.com>
Date: Tue, 28 Oct 2025 19:09:58 +0000
Subject: [PATCH 1/2] Disable GMEM in single prim mode

---
 src/freedreno/vulkan/tu_autotune.cc | 4 ++--
 1 file changed, 2 insertions(+), 2 deletions(-)

diff --git a/src/freedreno/vulkan/tu_autotune.cc b/src/freedreno/vulkan/tu_autotune.cc
index 9d084349ca7..3c13572cad0 100644
--- a/src/freedreno/vulkan/tu_autotune.cc
+++ b/src/freedreno/vulkan/tu_autotune.cc
@@ -1695,8 +1695,8 @@ tu_autotune::get_optimal_mode(struct tu_cmd_buffer *cmd_buffer, rp_ctx_t *rp_ctx
     * SINGLE_PRIM_MODE(FLUSH_PER_OVERLAP_AND_OVERWRITE) or even SINGLE_PRIM_MODE(FLUSH), then that should cause
     * significantly increased SYSMEM bandwidth (though we haven't quantified it).
     */
-   if (rp_state->sysmem_single_prim_mode)
-      return render_mode::GMEM;
+   // if (rp_state->sysmem_single_prim_mode)
+   //    return render_mode::GMEM;
 
    /* If the user is using a fragment density map, then this will cause less FS invocations with GMEM, which has a
     * hard-to-measure impact on performance because it depends on how heavy the FS is in addition to how many
-- 
2.49.0

EOF

    echo "Applying Disable GMEM Single Prim patch..."
    if git apply "$workdir/0001-Disable-GMEM-in-single-prim-mode.patch"; then
        echo -e "${green}Patch applied successfully!${nocolor}\n"
    else
        echo -e "${red}Failed to apply Disable GMEM Single Prim patch.${nocolor}"
        cd ..
        commit_dgmem_sp=""
        version_dgmem_sp="N/A (skipped)"
        return
    fi

    commit_dgmem_sp=$(git rev-parse HEAD)
    version_dgmem_sp=$(cat VERSION | xargs)
    cd ..
    compile_mesa "$workdir/$dir_name" "$build_dir" "Mesa_DGmemSP"
    package_driver "$dir_name" "$build_dir" "dgmem_sp" "Mesa Main (Patched: DGmemSP)" "$version_dgmem_sp" "$(git -C $dir_name rev-parse --short HEAD)" "$commit_dgmem_sp" "$mesa_repo_main"
}

build_mesa_oneui_patched() {
    local dir_name="mesa_oneui"
    local build_dir="build-oneui"
    echo -e "${green}=== Building Patched Mesa ($mesa_tag_oneui) for OneUI ===${nocolor}"
    git clone "$mesa_repo_main" "$dir_name"
    cd "$dir_name"
    git checkout "$mesa_tag_oneui"
    
    echo "Applying OneUI patch: enable_tp_ubwc_flag_hint = True..."
	sed -i 's/enable_tp_ubwc_flag_hint = False,/enable_tp_ubwc_flag_hint = True,/' src/freedreno/common/freedreno_devices.py
	echo "Patch applied."

    commit_oneui=$(git rev-parse HEAD)
    version_oneui="$mesa_tag_oneui"
    cd ..
    compile_mesa "$workdir/$dir_name" "$build_dir" "Mesa_OneUI"
    package_driver "$dir_name" "$build_dir" "oneui" "Mesa $mesa_tag_oneui (Patched: OneUI)" "$version_oneui" "$(git -C $dir_name rev-parse --short HEAD)" "$commit_oneui" "$mesa_repo_main"
}

generate_release_info() {
    echo -e "${green}Generating release info files for GitHub Actions...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
    local main_commit_short=$(git -C mesa_main rev-parse --short HEAD)
    local dgmem_sp_commit_short=""
    if [ -d "mesa_dgmem_sp" ] && [ -n "$commit_dgmem_sp" ]; then
       dgmem_sp_commit_short=$(git -C mesa_dgmem_sp rev-parse --short HEAD)
    fi
    local oneui_commit_short=$(git -C mesa_oneui rev-parse --short HEAD)

    echo "Mesa-${date_tag}-${main_commit_short}" > tag
    echo "Turnip CI Build - ${date_tag}" > release

    echo "Automated Turnip CI build." > description
    echo "" >> description
    echo "### Included Drivers:" >> description
    echo "" >> description
    
    echo "**1. Latest Mesa Main (turnip\_<date>\_${main_commit_short}.zip):**" >> description
    echo "   - Standard Turnip driver built from the latest Mesa main branch." >> description
    echo "   - Version: \`$version_main\`" >> description
    echo "   - Commit: [${main_commit_short}](${mesa_repo_main%.git}/-/commit/${commit_main})" >> description
    echo "" >> description
    
    echo "**2. Main + DGmemSP Patch (turnip\_dgmem\_sp\_<date>\_${dgmem_sp_commit_short}.zip):**" >> description
    echo "   - Build from latest Mesa main branch + Patch to disable GMEM in single prim mode." >> description
    if [ -n "$dgmem_sp_commit_short" ]; then
        echo "   - Version: \`$version_dgmem_sp\`" >> description
        echo "   - Base Commit: [${dgmem_sp_commit_short}](${mesa_repo_main%.git}/-/commit/${commit_dgmem_sp})" >> description
    else
        echo "   - *Build skipped due to patch failure.*" >> description
    fi
    echo "" >> description
    
    echo "**3. Turnip OneUI Patched (turnip\_oneui\_<date>\_${oneui_commit_short}.zip):**" >> description
    echo "   - Based on Mesa tag \`$version_oneui\`, patched to enable \`enable_tp_ubwc_flag_hint=True\`." >> description
    echo "   - Aims for better compatibility on certain Adreno devices running Samsung OneUI." >> description
    echo "   - Commit (base): [${oneui_commit_short}](${mesa_repo_main%.git}/-/commit/${commit_oneui})" >> description
    
    echo -e "${green}Release info generated.${nocolor}"
}

check_deps
mkdir -p "$workdir"
prepare_ndk

build_mesa_main
build_mesa_main_dgmem_sp
build_mesa_oneui_patched

generate_release_info

echo -e "${green}All builds completed successfully!${nocolor}"
