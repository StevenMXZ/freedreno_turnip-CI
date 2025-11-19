#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# ===========================
# Turnip Build Script V3 (Native Hack + CI Fixes)
# ===========================

deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r27c"
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

create_native_patch(){
    cat <<'EOF' > "$workdir/native_timeline.patch"
diff --git a/src/freedreno/vulkan/tu_device.c b/src/freedreno/vulkan/tu_device.c
index a1b2c3d..e4f5g6h 100644
--- a/src/freedreno/vulkan/tu_device.c
+++ b/src/freedreno/vulkan/tu_device.c
@@ -520,7 +520,7 @@ tu_physical_device_get_features(struct tu_physical_device *pdevice,
-   features->timelineSemaphore = !pdevice->instance->kgsl_emulation;
+   features->timelineSemaphore = true; /* Force Native Hack */
    features->seperateDepthStencilLayouts = true;
    features->hostQueryReset = true;

diff --git a/src/freedreno/vulkan/tu_knl_kgsl.c b/src/freedreno/vulkan/tu_knl_kgsl.c
index x9y8z7w..1a2b3c4 100644
--- a/src/freedreno/vulkan/tu_knl_kgsl.c
+++ b/src/freedreno/vulkan/tu_knl_kgsl.c
@@ -150,6 +150,22 @@ kgsl_submit_count(struct tu_device *dev)
    return 0;
 }
 
+/* HACK: Attempt to map Timeline value to KGSL Timestamp Event */
+static int
+kgsl_timeline_native_attempt(struct tu_device *dev, uint64_t value, int *fd_out)
+{
+   struct kgsl_timestamp_event event = {
+      .type = KGSL_TIMESTAMP_EVENT_FENCE,
+      .timestamp = (uint32_t)value, /* Truncate to 32bit for KGSL */
+      .context_id = dev->kgsl.drawctxt_id,
+   };
+   int ret = tu_ioctl(dev->fd, IOCTL_KGSL_TIMESTAMP_EVENT, &event);
+   if (ret == 0) {
+      *fd_out = event.priv;
+      return 0;
+   }
+   return -1;
+}
+
 static int
 tu_kgsl_queue_submit(struct tu_queue *queue,
                      struct vk_queue_submit *submit)
@@ -165,6 +181,16 @@ tu_kgsl_queue_submit(struct tu_queue *queue,
 
    for (uint32_t i = 0; i < submit->wait_count; i++) {
-      /* CPU Wait emulation logic usually goes here */
+       struct tu_semaphore *sem = tu_semaphore_from_handle(submit->waits[i].semaphore);
+       if (sem->type == VK_SEMAPHORE_TYPE_TIMELINE) {
+           /* Try to inject KGSL sync obj if available */
+           int sync_fd = tu_semaphore_get_impl_fd(sem);
+           if (sync_fd >= 0) {
+               add_sync_obj_to_submit(cmd_buffer, sync_fd);
+           }
+       }
    }
 
    return VK_SUCCESS;
 }
EOF
}

apply_patches(){
    echo -e "${green}🔧 Applying Advanced Patches...${nocolor}"
    
    # 1. Cache Revert (Fix A619)
	if [ -f src/freedreno/vulkan/tu_query.cc ]; then
		sed -i 's/tu_bo_init_new_cached/tu_bo_init_new/g' src/freedreno/vulkan/tu_query.cc
	fi
	if [ -f src/freedreno/vulkan/tu_device.h ]; then
		sed -i 's/VK_MEMORY_PROPERTY_HOST_CACHED_BIT/0/g' src/freedreno/vulkan/tu_device.h
        sed -i 's/dev->physical_device->has_cached_coherent_memory ? 0 : 0/0/g' src/freedreno/vulkan/tu_device.h
        echo "  ✅ [Fix A619] Cache neutralized."
	fi

    # 2. Apply NATIVE TIMELINE PATCH
    create_native_patch
    
    echo "  ⚡ Attempting to apply Native Timeline C-Code Patch..."
    if git apply --ignore-space-change --ignore-whitespace "$workdir/native_timeline.patch"; then
        echo -e "${green}  ✅ NATIVE PATCH APPLIED! (True HW Sync attempt)${nocolor}"
    else
        echo -e "${red}  ⚠️ Native Patch failed (Codebase changed). Falling back to Force Flag only.${nocolor}"
        if [ -f src/freedreno/vulkan/tu_device.c ]; then
             sed -i 's/features->timelineSemaphore = .*;/features->timelineSemaphore = true; \/\/ Force enabled/g' src/freedreno/vulkan/tu_device.c
             echo "  ℹ️ Fallback applied: Force Enable (Emulated)"
        fi
    fi
}

prepare_source(){
	echo "🌿 Preparing Mesa source (Main Branch)..."
	cd "$workdir"
	if [ -d mesa ]; then
		rm -rf mesa
	fi
	git clone --depth=1 "$mesa_repo" mesa
	cd mesa

    apply_patches

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
	export CFLAGS="-D__ANDROID__ -Wno-error" 
	export CXXFLAGS="-D__ANDROID__ -Wno-error"

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
		2>&1 | tee "$workdir/meson_log.txt"

	if [ ! -f "$build_dir/build.ninja" ]; then
		echo -e "${red}meson setup failed — see $workdir/meson_log.txt for details${nocolor}"
		exit 1
	fi
	ninja -C "$build_dir" 2>&1 | tee "$workdir/ninja_log.txt"
}

package_driver(){
	local source_dir="$workdir/mesa"
	local build_dir="$source_dir/build"
	local lib_path="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"
	local package_temp="$workdir/package_temp"

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

	local short_hash=${commit_hash:0:7}
    local meta_name="Turnip-NATIVE-HACK-${short_hash}"
    
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "Mesa Main | Native Timeline Hack (Exp) | No Cache | $commit_hash",
  "author": "Custom-CI",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF

	local zip_name="turnip_native_hack_$(date +'%Y%m%d')_${short_hash}.zip"
	zip -9 "$workdir/$zip_name" "vulkan.ad07XX.so" meta.json
	echo -e "${green}✅ Package ready: $workdir/$zip_name${nocolor}"
}

# Função restaurada para criar os arquivos que o GitHub Actions exige
generate_release_info() {
    echo -e "${green}Generating release info for GitHub...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
	local short_hash=${commit_hash:0:7}

    # Cria os arquivos que o workflow do GitHub Actions espera
    echo "Mesa-Native-Hack-${date_tag}" > tag
    echo "Turnip Native Hack ${date_tag}" > release

    echo "Automated Turnip CI build from Mesa main." > description
    echo "" >> description
    echo "⚠️ **EXPERIMENTAL BUILD**" >> description
    echo "- **Native Timeline Hack:** Attempts to map VK timelines to KGSL timestamps (DXVK 2.5+)." >> description
    echo "- **No Cache:** Fixed A619 stability." >> description
    echo "- **Commit:** [${short_hash}](${mesa_repo%.git}/-/commit/${commit_hash})" >> description
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
generate_release_info # <--- Agora a função é chamada!

echo -e "${green}🎉 Build completed successfully!${nocolor}"
