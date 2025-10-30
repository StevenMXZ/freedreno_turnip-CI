#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# --- Config ---
deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
sdkver="35"
mesasrc="https://gitlab.freedesktop.org/PixelyIon/mesa.git"
target_branch="tu-newat"

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
	mkdir -p "$workdir"
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

prepare_mesa_source() {
    echo "Preparing Mesa source directory (PixelyIon's Fork)..."
    cd "$workdir"
    if [ -d mesa ]; then
		echo "Removing old Mesa ..."
		rm -rf mesa
	fi
    
    echo "Cloning PixelyIon's Mesa repository..."
	git clone "$mesasrc" mesa
	cd mesa

    echo -e "${green}Checking out branch '$target_branch'...${nocolor}"
    git checkout "$target_branch"

    # --- NOVO PATCH ADICIONADO ---
    local patch_file_name="0001-Remove-autotune-lock.patch"
    echo "Creating $patch_file_name file..."
    cat << 'EOF' > "$workdir/$patch_file_name"
diff --git a/src/freedreno/vulkan/tu_autotune.cc b/src/freedreno/vulkan/tu_autotune.cc
index 9d084349ca7..f15111813db 100644
--- a/src/freedreno/vulkan/tu_autotune.cc
+++ b/src/freedreno/vulkan/tu_autotune.cc
@@ -1140,14 +1140,6 @@ struct tu_autotune::rp_history {
                bool enough_samples = sysmem_ema.count >= MIN_LOCK_DURATION_COUNT && gmem_ema.count >= MIN_LOCK_DURATION_COUNT;
                uint64_t min_avg = MIN2(avg_sysmem, avg_gmem), max_avg = MAX2(avg_sysmem, avg_gmem);
                uint64_t percent_diff = (100 * (max_avg - min_avg)) / min_avg;
-
-               if (has_resolved && enough_samples && max_avg >= MIN_LOCK_THRESHOLD && percent_diff >= LOCK_PERCENT_DIFF) {
-                  if (avg_gmem < avg_sysmem)
-                     sysmem_prob = 0;
-                  else
-                     sysmem_prob = 100;
-                  locked = true;
-               }
         
    }
          }
EOF

    echo "Applying $patch_file_name..."
    if git apply "$workdir/$patch_file_name"; then
        echo -e "${green}Patch applied successfully!${nocolor}\n"
    else
        echo -e "${red}Failed to apply $patch_file_name to branch $target_branch.${nocolor}"
        exit 1
    fi
    # --- FIM DO PATCH ---

    commit_target=$(git rev-parse HEAD)
    version_target=$(cat VERSION | xargs)
    cd "$workdir"
}

compile_mesa() {
    local source_dir="$workdir/mesa"
    local build_dir_name="build"
    local description="PixelyIon's Fork ($target_branch) + No AT Lock Patch"

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
	meson setup --reconfigure "$build_dir_name" --cross-file "$cross_file_path" -Dbuildtype=release -Dplatforms=android -Dplatform-sdk-version=$sdkver -Dandroid-stub=true -Dgallium-drivers= -Dvulkan-drivers=freedreno -Dvulkan-beta=true -Dfreedreno-kmds=kgsl -Db_lto=true -Degl=disabled 2>&1 | tee "$workdir/meson_log"

	echo "Compiling $description..."
	ninja -C "$build_dir_name" 2>&1 | tee "$workdir/ninja_log"

    local compiled_lib="$source_dir/$build_dir_name/src/freedreno/vulkan/libvulkan_freedreno.so"
	if [ ! -f "$compiled_lib" ]; then
		echo -e "${red}Build failed: libvulkan_freedreno.so not found.${nocolor}"
		exit 1
	fi
    echo -e "${green}--- Finished Compiling: $description ---${nocolor}\n"
    cd "$workdir"
}

package_driver() {
    local source_dir="$workdir/mesa"
    local build_dir_name="build"
    local description_name="PixelyIon's Fork ($target_branch) + No AT Lock Patch"
    local version_str=$version_target
    local commit_hash_short=$(git -C $source_dir rev-parse --short HEAD)
    local commit_hash_full=$commit_target
    local repo_url=$mesasrc
    local output_suffix="no_at_lock"

    echo -e "${green}--- Packaging: $description_name ---${nocolor}"
    local compiled_lib="$source_dir/$build_dir_name/src/freedreno/vulkan/libvulkan_freedreno.so"
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
    local meta_name="Turnip-PixelyIon-${commit_hash_short}-NoATLock"
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

generate_release_info() {
    echo -e "${green}Generating release info files for GitHub Actions...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
    local target_commit_short=$(git -C mesa rev-parse --short HEAD)

    echo "PixelyIon-NoATLock-${date_tag}-${target_commit_short}" > tag
    echo "Turnip CI Build - ${date_tag} (PixelyIon's Fork + No AT Lock Patch)" > release

    echo "Automated Turnip CI build from PixelyIon's Mesa fork." > description
    echo "" >> description
    echo "### Build Details:" >> description
    echo "**Base:** PixelyIon's Mesa fork, branch \`$target_branch\`" >> description
    echo "**Patch Applied:** Remove autotune lock logic from \`tu_autotune.cc\`." >> description
    echo "**Commit:** [${target_commit_short}](${mesasrc%.git}/-/commit/${commit_target})" >> description
    
    echo -e "${green}Release info generated.${nocolor}"
}


# --- Execução Principal ---
check_deps
prepare_ndk
prepare_mesa_source
compile_mesa
package_driver
generate_release_info

echo -e "${green}Build completed successfully!${nocolor}"
