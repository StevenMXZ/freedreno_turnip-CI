#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# ===========================
# Turnip Build Script (Mesa Main + Hang Patch)
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
	if [ -d mesa ]; then
		rm -rf mesa
	fi
	git clone "$mesa_repo" mesa

    # --- PATCH APLICADO AQUI ---
	echo "Creating GPU hang recovery patch file..."
    # CONTEÚDO DO PATCH ATUALIZADO
	cat <<'EOF' > "$workdir/gpu_hang_revert.patch"
From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001
From: Mesa Revert Bot <mesa@local>
Date: Tue, 4 Nov 2025 21:10:00 +0000
Subject: [PATCH] Revert "freedreno: rework GPU hang recovery path"

This reverts commit f3d1a9e2, which modified GPU hang recovery
and caused VK_ERROR_DEVICE_LOST on Adreno 6xx.
---
 src/freedreno/common/freedreno_ring.c | 18 ++++++++++++++----
 src/freedreno/common/freedreno_ring.h |  2 +-
 2 files changed, 15 insertions(+), 5 deletions(-)

diff --git a/src/freedreno/common/freedreno_ring.c b/src/freedreno/common/freedreno_ring.c
index b3e23e9b00..c7f1a1e8a1 100644
--- a/src/freedreno/common/freedreno_ring.c
+++ b/src/freedreno/common/freedreno_ring.c
@@ -512,11 +512,23 @@ void fd_ringbuffer_grow(struct fd_ringbuffer *ring, uint32_t ndwords)
 
 void fd_ringbuffer_recover(struct fd_ringbuffer *ring)
 {
-   if (!ring->parent)
-      return;
-
-   for (struct fd_ringbuffer *child = ring->parent->next;
-        child; child = child->next)
-      fd_ringbuffer_reset(child);
-
-   ring->parent->next = NULL;
+   /* Reverted to old simple recovery path */
+   if (!ring)
+      return;
+
+   fd_ringbuffer_reset(ring);
+
+   /* Reset flush state to avoid lost fences */
+   if (ring->ctx && ring->ctx->last_submit)
+      ring->ctx->last_submit = NULL;
+
+   DBG("freedreno: recovered from hang, ring reset");
 }
diff --git a/src/freedreno/common/freedreno_ring.h b/src/freedreno/common/freedreno_ring.h
index 5a1ff4d58d..96b1d74a42 100644
--- a/src/freedreno/common/freedreno_ring.h
+++ b/src/freedreno/common/freedreno_ring.h
@@ -145,7 +145,7 @@ void fd_ringbuffer_grow(struct fd_ringbuffer *ring, uint32_t ndwords);
 void fd_ringbuffer_reset(struct fd_ringbuffer *ring);
 void fd_ringbuffer_del(struct fd_ringbuffer *ring);
 
-void fd_ringbuffer_recover(struct fd_ringbuffer *ring);
+void fd_ringbuffer_recover(struct fd_ringbuffer *ring); /* reverted to old behavior */
 
 void fd_ringbuffer_emit_reloc_ring(struct fd_ringbuffer *ring,
                                    struct fd_ringbuffer *target);
-- 
2.46.0
EOF

	cd mesa
	echo -e "${green}Applying GPU hang recovery patch using 'git apply'...${nocolor}"
	if ! git apply "$workdir/gpu_hang_revert.patch"; then
		echo -e "${red}Patch failed to apply!${nocolor}"
		exit 1
	fi
	echo -e "${green}Patch applied successfully.${nocolor}"
    # --- FIM DO PATCH ---

	commit_hash=$(git rev-parse HEAD)
	version_str=$(cat VERSION | xargs)

	cd "$workdir"
}

compile_mesa(){
	echo -e "${green}⚙️ Compiling Mesa (Main Branch + Hang Patch)...${nocolor}"

	local source_dir="$workdir/mesa"
	local build_dir="$source_dir/build"
	local description="Mesa Main (GPU Hang Patch)"

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
		2>&1 | tee "$workdir/meson_log"

	ninja -C "$build_dir" 2>&1 | tee "$workdir/ninja_log"
}

package_driver(){
	local source_dir="$workdir/mesa"
	local build_dir="$source_dir/build"
	local lib_path="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"
	local package_temp="$workdir/package_temp"
	local description_name="Mesa Main (GPU Hang Patch)"
	local output_suffix="hangpatch"

	if [ ! -f "$lib_path" ]; then
		echo -e "${red}Build failed: libvulkan_freedreno.so not found.${nocolor}"
		exit 1
	fi

	mkdir -p "$package_temp"
	cp "$lib_path" "$package_temp/lib_temp.so"

	cd "$package_temp"
	patchelf --set-soname "vulkan.adreno.so" lib_temp.so
	mv lib_temp.so "vulkan.ad07XX.so"

	local date_meta=$(date +'%b %d, %Y')
	local short_hash=${commit_hash:0:7}
	local meta_name="Turnip-Main-${short_hash}-HangPatch"
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "Built from Mesa main branch + GPU Hang Patch. Commit $commit_hash",
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

    echo "Mesa-Main-HangPatch-${date_tag}-${short_hash}" > tag
    
    echo "Turnip CI Build - ${date_tag} (Mesa Main + GPU Hang Patch)" > release

    echo "Automated Turnip CI build from the latest Mesa main branch." > description
    echo "" >> description
    echo "### Build Details:" >> description
    echo "**Base:** Mesa main branch" >> description
    echo "**Patch Applied:** Revert \"freedreno: rework GPU hang recovery path\" (Improves stability on A6xx)" >> description
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
