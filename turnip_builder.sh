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
    # ALTERADO: Sufixo para o nome do arquivo ZIP
    local output_suffix="log_at"

    echo -e "${green}--- Packaging: $description_name ---${nocolor}"
    local compiled_lib="$workdir/$source_dir/$build_dir_name/src/freedreno/vulkan/libvulkan_freedreno.so"
    local package_temp_dir="$workdir/package_temp_single"
    
    local lib_final_name="vulkan.ad07XX.so" 
    local soname="vulkan.adreno.so" 

    # Nome do arquivo ZIP com sufixo
    local output_filename="turnip_$(date +'%Y%m%d')_${commit_hash_short}_${output_suffix}.zip"

    mkdir -p "$package_temp_dir"
    
    cp "$compiled_lib" "$package_temp_dir/lib_temp.so"
    cd "$package_temp_dir"
    
    patchelf --set-soname "$soname" lib_temp.so
    mv lib_temp.so "$lib_final_name"

	date_meta=$(date +'%b %d, %Y')
    local meta_name="Turnip-Danil-${commit_hash_short}-LogAT" # Nome curto para meta.json
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

# --- Função ÚNICA de Build ---
# Renomeada para clareza
build_danil_patched_log_at() {
    local dir_name="mesa_danil_patched_log_at"
    local build_dir="build-danil-patched-log-at"
    local description="Danil's Fork $target_branch (Patched: Log AT Mode)"
    # ALTERADO: Nome do arquivo patch
    local patch_file_name="0001-Log-AT-forced-prim-mode.patch"
    echo -e "${green}=== Building $description ===${nocolor}"
    git clone "$mesasrc" "$dir_name"
    cd "$dir_name"
    
    echo -e "${green}Checking out branch '$target_branch'...${nocolor}"
    git checkout "$target_branch"
    
    # ALTERADO: Conteúdo do patch
    echo "Creating $patch_file_name file..."
    cat << 'EOF' > "$workdir/$patch_file_name"
From cda5eea32ce03e297d607ae3a2a2e589c83f0504 Mon Sep 17 00:00:00 2001
From: Dhruv Mark Collins <mark@igalia.com>
Date: Tue, 28 Oct 2025 21:54:34 +0000
Subject: [PATCH] Log AT forced + prim mode

---
 src/freedreno/vulkan/tu_autotune.cc | 9 ++++++---
 src/freedreno/vulkan/tu_pipeline.cc | 7 ++++++-
 2 files changed, 12 insertions(+), 4 deletions(-)

diff --git a/src/freedreno/vulkan/tu_autotune.cc b/src/freedreno/vulkan/tu_autotune.cc
index 9d084349ca7..62a16e08318 100644
--- a/src/freedreno/vulkan/tu_autotune.cc
+++ b/src/freedreno/vulkan/tu_autotune.cc
@@ -1695,17 +1695,20 @@ tu_autotune::get_optimal_mode(struct tu_cmd_buffer *cmd_buffer, rp_ctx_t *rp_ctx
     * SINGLE_PRIM_MODE(FLUSH_PER_OVERLAP_AND_OVERWRITE) or even SINGLE_PRIM_MODE(FLUSH), then that should cause
     * significantly increased SYSMEM bandwidth (though we haven't quantified it).
     */
-   if (rp_state->sysmem_single_prim_mode)
+   if (rp_state->sysmem_single_prim_mode) {
+      mesa_loge("Using GMEM due to SINGLE_PRIM_MODE(FLUSH[_PER_OVERLAP_AND_OVERWRITE]) in subpass");
       return render_mode::GMEM;
+   }
 
    /* If the user is using a fragment density map, then this will cause less FS invocations with GMEM, which has a
     * hard-to-measure impact on performance because it depends on how heavy the FS is in addition to how many
     * invocations there were and the density. Let's assume the user knows what they're doing when they added the map,
     * because if SYSMEM is actually faster then they could've just not used the fragment density map.
     */
-   if (pass->has_fdm)
+   if (pass->has_fdm) {
+      mesa_loge("Using GMEM due to fragment density map usage");
       return render_mode::GMEM;
-
+   }
    /* SYSMEM is always a safe default mode when we can't fully engage the autotuner. From testing, we know that for an
     * incorrect decision towards SYSMEM tends to be far less impactful than an incorrect decision towards GMEM, which
     * can cause significant performance issues.
diff --git a/src/freedreno/vulkan/tu_pipeline.cc b/src/freedreno/vulkan/tu_pipeline.cc
index bfb16340229..4c6ee7c5e35 100644
--- a/src/freedreno/vulkan/tu_pipeline.cc
+++ b/src/freedreno/vulkan/tu_pipeline.cc
@@ -3571,8 +3571,13 @@ tu6_emit_prim_mode_sysmem(struct tu_cs *cs,
        fs->fs.dynamic_input_attachments_used) ?
       FLUSH_PER_OVERLAP_AND_OVERWRITE : NO_FLUSH;
 
-   if (sysmem_prim_mode == FLUSH_PER_OVERLAP_AND_OVERWRITE)
+   if (sysmem_prim_mode == FLUSH_PER_OVERLAP_AND_OVERWRITE) {
+      mesa_loge("Enabling sysmem single prim mode due to %s",
+                raster_order_attachment_access ? "raster order attachment access" :
+                feedback_loops ? "attachment feedback loops" :
+                "dynamic input attachments");
       *sysmem_single_prim_mode = true;
+   }
 
    tu_cs_emit_regs(cs, A6XX_GRAS_SC_CNTL(.ccusinglecachelinesize = 2,
                                          .single_prim_mode = sysmem_prim_mode));
-- 
2.49.0

EOF

    # ALTERADO: Aplica o novo patch
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
    # ALTERADO: Passa a descrição correta e o sufixo
    package_driver "$dir_name" "$build_dir" "$description" "$version_target" "$(git -C $dir_name rev-parse --short HEAD)" "$commit_target" "$mesasrc"
}


# --- Geração de Info para Release ---
generate_release_info() {
    echo -e "${green}Generating release info files for GitHub Actions...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
    local target_commit_short=$(git -C mesa_danil_patched_log_at rev-parse --short HEAD)

    # Tag baseada na data e commit
    echo "Danil-${date_tag}-${target_commit_short}" > tag
    # ALTERADO: Nome da release
    echo "Turnip CI Build - ${date_tag} (Danil's Fork + Log AT Mode Patch)" > release

    echo "Automated Turnip CI build." > description
    echo "" >> description
    echo "### Build Details:" >> description
    echo "**Base:** Danil's Mesa fork, branch \`$target_branch\`" >> description
    # ALTERADO: Descrição do patch
    echo "**Patch Applied:** Add logging for Autotuner forced modes and single prim mode." >> description
    echo "**Commit:** [${target_commit_short}](${mesasrc%.git}/-/commit/${commit_target})" >> description
    
    echo -e "${green}Release info generated.${nocolor}"
}


# --- Execução Principal ---
check_deps
mkdir -p "$workdir" 
prepare_ndk

# Executa apenas o build desejado
build_danil_patched_log_at # Função renomeada

generate_release_info

echo -e "${green}Build completed successfully!${nocolor}"
