#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# ===========================
# Turnip Build Script (Mesa Main + A6xx VK1.4 Patch)
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
	# Clone completo é necessário para 'git apply'
	git clone "$mesa_repo" mesa
	
    # --- PATCH APLICADO AQUI ---
	echo "Creating A6xx Vulkan 1.4 patch file..."
	cat <<'EOF' > "$workdir/vk14_a6xx.patch"
--- a/src/freedreno/vulkan/meson.build
+++ b/src/freedreno/vulkan/meson.build
@@ -208,7 +208,7 @@
   output : 'freedreno_icd.@0@.json'.format(host_machine.cpu()),
   command : [
     prog_python, '@INPUT0@',
-    '--api-version', '1.1', '--xml', '@INPUT1@',
+    '--api-version', '1.4', '--xml', '@INPUT1@',
     '--lib-path', join_paths(get_option('prefix'), get_option('libdir'),
                              'libvulkan_freedreno.so'),
     '--out', '@OUTPUT@',
@@ -226,7 +226,7 @@
   output : _dev_icdname,
   command : [
     prog_python, '@INPUT0@',
-    '--api-version', '1.1', '--xml', '@INPUT1@',
+    '--api-version', '1.4', '--xml', '@INPUT1@',
     '--lib-path', meson.current_build_dir() / 'libvulkan_freedreno.so',
     '--out', '@OUTPUT@',
   ],
--- a/src/freedreno/vulkan/tu_device.cc
+++ b/src/freedreno/vulkan/tu_device.cc
@@ -76,7 +76,7 @@
    return 0;
 }
 
-#define TU_API_VERSION VK_MAKE_VERSION(1, 3, VK_HEADER_VERSION)
+#define TU_API_VERSION VK_MAKE_VERSION(1, 4, VK_HEADER_VERSION)
 
 VKAPI_ATTR VkResult VKAPI_CALL
 tu_EnumerateInstanceVersion(uint32_t *pApiVersion)
@@ -770,20 +770,12 @@
    snprintf(p->driverInfo, VK_MAX_DRIVER_INFO_SIZE,
             "Mesa " PACKAGE_VERSION MESA_GIT_SHA1);
    if (pdevice->info->chip >= 7) {
       p->conformanceVersion = (VkConformanceVersion) {
          .major = 1,
          .minor = 4,
          .subminor = 0,
          .patch = 0,
       };
    } else {
+      /* HACK: Force A6xx to report 1.4 conformance */
       p->conformanceVersion = (VkConformanceVersion) {
-         .major = 1,
-         .minor = 2,
-         .subminor = 7,
-         .patch = 1,
+         .major = 1,
+         .minor = 4,
+         .subminor = 0,
+         .patch = 0,
       };
    }
 
@@ -793,9 +785,8 @@
 
    props->apiVersion =
       (pdevice->info->a6xx.has_hw_multiview || TU_DEBUG(NOCONFORM)) ?
-         ((pdevice->info->chip >= 7) ? TU_API_VERSION :
-            VK_MAKE_VERSION(1, 3, VK_HEADER_VERSION))
+         /* HACK: Force A6xx to use the main TU_API_VERSION (1.4) */
+         (TU_API_VERSION)
          : VK_MAKE_VERSION(1, 0, VK_HEADER_VERSION);
    props->driverVersion = vk_get_driver_version();
    props->vendorID = 0x5143;
EOF

	cd mesa
	echo -e "${green}Applying A6xx VK 1.4 patch using 'git apply'...${nocolor}"
	if ! git apply "$workdir/vk14_a6xx.patch"; then
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
	echo -e "${green}⚙️ Compiling Mesa (Main Branch + A6xx VK1.4 Patch)...${nocolor}"

	local source_dir="$workdir/mesa"
	local build_dir="$source_dir/build"
	local description="Mesa Main (A6xx VK1.4 Patch)"

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
	local description_name="Mesa Main (A6xx VK1.4 Patch)"
	local output_suffix="vk14_a6xx"

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
	local meta_name="Turnip-Main-${short_hash}-VK14-A6xx"
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "Built from Mesa main branch + A6xx VK1.4 Patch. Commit $commit_hash",
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

    echo "Mesa-Main-VK14-A6xx-${date_tag}-${short_hash}" > tag
    
    echo "Turnip CI Build - ${date_tag} (Mesa Main + A6xx VK1.4 Patch)" > release

    echo "Automated Turnip CI build from the latest Mesa main branch." > description
    echo "" >> description
    echo "### Build Details:" >> description
    echo "**Base:** Mesa main branch" >> description
    echo "**Patch Applied:** Force Vulkan 1.4 support for A6xx devices." >> description
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
