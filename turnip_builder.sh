#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"
packagedir="$workdir/turnip_module"
ndkver="android-ndk-r29"
sdkver="33"
mesasrc="https://gitlab.freedesktop.org/mesa/mesa.git"

#array of string => commit/branch;patch args
base_patches=(
	"disable_VK_KHR_workgroup_memory_explicit_layout;../../patches/disable_KHR_workgroup_memory_explicit_layout.patch;"
)
experimental_patches=(
	"force_sysmem_no_autotuner;../../patches/force_sysmem_no_autotuner.patch;"
)
failed_patches=()
commit=""
commit_short=""
mesa_version=""
vulkan_version=""
clear

# there are 4 functions here, simply comment to disable.
# you can insert your own function and make a pull request.
run_all(){
	check_deps
	prep

	if (( ${#base_patches[@]} )); then
		prep "patched"
	fi
 
	if (( ${#experimental_patches[@]} )); then
		prep "experimental"
	fi
}

prep () {
	prepare_workdir "$1"
	build_lib_for_android
	port_lib_for_adrenotool "$1"
}

check_deps(){
	echo "Checking system for required Dependencies ..."
	for deps_chk in $deps;
		do
			sleep 0.25
			if command -v "$deps_chk" >/dev/null 2>&1 ; then
				echo -e "$green - $deps_chk found $nocolor"
			else
				echo -e "$red - $deps_chk not found, can't countinue. $nocolor"
				deps_missing=1
			fi;
		done

		if [ "$deps_missing" == "1" ]
			then echo "Please install missing dependencies" && exit 1
		fi

	echo "Installing python Mako dependency (if missing) ..." $'\n'
	pip install mako &> /dev/null
}

prepare_workdir(){
	echo "Creating and entering to work directory ..." $'\n'
	mkdir -p "$workdir" && cd "$_"

	if [ -z "${ANDROID_NDK_LATEST_HOME}" ]; then
		if [ ! -n "$(ls -d android-ndk*)" ]; then
			echo "Downloading android-ndk from google server (~640 MB) ..." $'\n'
			curl https://dl.google.com/android/repository/"$ndkver"-linux.zip --output "$ndkver"-linux.zip &> /dev/null
			###
			echo "Exracting android-ndk to a folder ..." $'\n'
			unzip "$ndkver"-linux.zip  &> /dev/null
		fi
	else	
		echo "Using android ndk from github image"
	fi

	if [ -z "$1" ]; then
		if [ -d mesa ]; then
			echo "Removing old mesa ..." $'\n'
			rm -rf mesa
		fi
		
		echo "Cloning mesa ..." $'\n'
		git clone --depth=1 "$mesasrc"

		cd mesa

		# --- PATCH 1: ADICIONAR SUPORTE EXPERIMENTAL AO A710 ---
		echo -e "${green}Creating patch for A710 support...${nocolor}"
		# Usando um 'here document' para criar o arquivo de patch em tempo real
		cat << 'EOF' > a710_support.patch
diff -uNr mesa-vulkan-freedreno-25.0.3/src/freedreno/common/freedreno_devices.py mesa-vulkan-freedreno-25.0.3-exp710/src/freedreno/common/freedreno_devices.py
--- mesa-vulkan-freedreno-25.0.3/src/freedreno/common/freedreno_devices.py	2025-04-02 13:35:11.000000000 -0300
+++ mesa-vulkan-freedreno-25.0.3-exp710/src/freedreno/common/freedreno_devices.py	2025-04-21 20:40:27.570841169 -0300
@@ -1057,6 +1057,24 @@
     ))
 
 add_gpus([
+        GPUId(chip_id=0x07010000, name="FD710"), # KGSL, no speedbin data
+        GPUId(chip_id=0xffff07010000, name="FD710"), # Default no-speedbin fallback
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
+add_gpus([
         GPUId(chip_id=0x07030001, name="FD730"), # KGSL, no speedbin data
         GPUId(chip_id=0xffff07030001, name="FD730"), # Default no-speedbin fallback
     ], A6xxGPUInfo(
diff -uNr mesa-vulkan-freedreno-25.0.3/src/freedreno/drm-shim/freedreno_noop.c mesa-vulkan-freedreno-25.0.3-exp710/src/freedreno/drm-shim/freedreno_noop.c
--- mesa-vulkan-freedreno-25.0.3/src/freedreno/drm-shim/freedreno_noop.c	2025-04-02 13:35:11.000000000 -0300
+++ mesa-vulkan-freedreno-25.0.3-exp710/src/freedreno/drm-shim/freedreno_noop.c	2025-04-21 20:40:28.371145184 -0300
@@ -235,6 +235,11 @@
       .gmem_size = 1024 * 1024 + 512 * 1024,
    },
    {
+      .gpu_id = 710,
+      .chip_id = 0x07010000,
+      .gmem_size = 2 * 1024 * 1024,
+   },
+   {
       .gpu_id = 730,
       .chip_id = 0x07030001,
       .gmem_size = 2 * 1024 * 1024,
EOF
		
		echo -e "${green}Applying A710 support patch...${nocolor}"
		git apply a710_support.patch
		echo -e "${green}A710 patch applied successfully!${nocolor}\n"
		
		# --- PATCH 2: FORÇAR GMEM ---
		echo -e "${green}Applying patch: Force GMEM...${nocolor}"
		sed -i '/bool tu_autotune_use_sysmem(const struct tu_device \*device, const struct tu_render_pass \*pass)/a \    return false;' src/freedreno/vulkan/tu_autotune.cc
		echo -e "${green}Force GMEM patch applied successfully!${nocolor}"
		
		commit_short=$(git rev-parse --short HEAD)
		commit=$(git rev-parse HEAD)
		mesa_version=$(cat VERSION | xargs)
		version=$(awk -F'COMPLETE VK_MAKE_API_VERSION(|)' '{print $2}' <<< $(cat include/vulkan/vulkan_core.h) | xargs)
		major=$(echo $version | cut -d "," -f 2 | xargs)
		minor=$(echo $version | cut -d "," -f 3 | xargs)
		patch=$(awk -F'VK_HEADER_VERSION |\n#define' '{print $2}' <<< $(cat include/vulkan/vulkan_core.h) | xargs)
		vulkan_version="$major.$minor.$patch"
	else		
		cd mesa

		if [ $1 == "patched" ]; then 
			apply_patches ${base_patches[@]}
		else 
			apply_patches ${experimental_patches[@]}
		fi
		
	fi
}

apply_patches() {
	local arr=("$@")
	for patch in "${arr[@]}"; do
		echo "Applying patch $patch"
		patch_source="$(echo $patch | cut -d ";" -f 2 | xargs)"
		patch_args=$(echo $patch | cut -d ";" -f 3 | xargs)
		if [[ $patch_source == *"../.."* ]]; then
			if git apply $patch_args "$patch_source"; then
				echo "Patch applied successfully"
			else
				echo "Failed to apply $patch"
				failed_patches+=("$patch")

			fi
		else 
			patch_file="${patch_source#*\/}"
			curl --output "../$patch_file".patch -k --retry-delay 30 --retry 5 -f --retry-all-errors https://gitlab.freedesktop.org/mesa/mesa/-/"$patch_source".patch
			sleep 1

			if git apply $patch_args "../$patch_file".patch ; then
				echo "Patch applied successfully"
			else
				echo "Failed to apply $patch"
				failed_patches+=("$patch")
				
			fi
		fi
	done
}

patch_to_description() {
	local arr=("$@")
	for patch in "${arr[@]}"; do
		patch_name="$(echo $patch | cut -d ";" -f 1 | xargs)"
		patch_source="$(echo $patch | cut -d ";" -f 2 | xargs)"
		patch_args="$(echo $patch | cut -d ";" -f 3 | xargs)"
		if [[ $patch_source == *"../.."* ]]; then
			echo "- $patch_name, $patch_source, $patch_args" >> description
		else 
			echo "- $patch_name, [$patch_source](https://gitlab.freedesktop.org/mesa/mesa/-/$patch_source), $patch_args" >> description
		fi
	done
}

build_lib_for_android(){
	echo "Creating meson cross file ..." $'\n'
	if [ -z "${ANDROID_NDK_LATEST_HOME}" ]; then
		ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
	else	
		ndk="$ANDROID_NDK_LATEST_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
	fi

	cat <<EOF >"android-aarch64"
[binaries]
ar = '$ndk/llvm-ar'
c = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang']
cpp = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$ndk/aarch64-linux-android-strip'
pkgconfig = ['env', 'PKG_CONFIG_LIBDIR=NDKDIR/pkgconfig', '/usr/bin/pkg-config']
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

	echo "Generating build files ..." $'\n'
	meson setup build-android-aarch64 --cross-file "$workdir"/mesa/android-aarch64 -Dbuildtype=release -Dplatforms=android -Dplatform-sdk-version=$sdkver -Dandroid-stub=true -Dgallium-drivers= -Dvulkan-drivers=freedreno -Dvulkan-beta=true -Dfreedreno-kmds=kgsl -Db_lto=true -Degl=disabled 2>&1 | tee "$workdir"/meson_log

	echo "Compiling build files ..." $'\n'
	ninja -C build-android-aarch64 2>&1 | tee "$workdir"/ninja_log

	local compiled_lib="$workdir/mesa/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so"
	if [ ! -f "$compiled_lib" ]; then
		echo -e "${red}--------------------------------------------------------------------${nocolor}"
		echo -e "${red}COMPILATION FAILED: The file libvulkan_freedreno.so was not created.${nocolor}"
		echo -e "${red}Check the compilation log above for the specific C++ error message.${nocolor}"
		echo -e "${red}--------------------------------------------------------------------${nocolor}"
		exit 1
	fi
}

port_lib_for_adrenotool(){
	echo "Using patchelf to match soname ..."  $'\n'
	cp "$workdir"/mesa/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so "$workdir"
	cd "$workdir"
	patchelf --set-soname vulkan.adreno.so libvulkan_freedreno.so
	mv libvulkan_freedreno.so vulkan.ad07XX.so

	mkdir -p "$packagedir" && cd "$_"

	date=$(date +'%b %d, %Y')
	suffix=""

	if [ ! -z "$1" ]; then
		suffix="_$1"
	fi

	cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "Turnip - $date - $commit_short$suffix",
  "description": "Compiled from Mesa, Commit $commit_short$suffix",
  "author": "mesa",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "$mesa_version/vk$vulkan_version",
  "minApi": 27,
  "libraryName": "vulkan.ad07XX.so"
}
EOF

	filename=turnip_"$(date +'%b-%d-%Y')"_"$commit_short"
	echo "Copy necessary files from work directory ..." $'\n'
	cp "$workdir"/vulkan.ad07XX.so "$packagedir"

	echo "Packing files in to adrenotool package ..." $'\n'
	zip -9 "$workdir"/"$filename$suffix".zip ./*

	cd "$workdir"

	if [ -z "$1" ]; then
		echo "Turnip - $mesa_version - $date" > release
		echo "$mesa_version"_"$commit_short" > tag
		echo  $filename > filename
		echo "### Base commit : [$commit_short](https://gitlab.freedesktop.org/mesa/mesa/-/commit/$commit_short)" > description
		echo "false" > patched
		echo "false" > experimental
	else		
		if [ $1 == "patched" ]; then 
			echo "## Upstreams / Patches" >> description
			echo "These have not been merged by Mesa officially yet and may introduce bugs or" >> description
			echo "we revert stuff that breaks games but still got merged in (see --reverse)" >> description
			patch_to_description ${base_patches[@]}
			echo "true" > patched
			echo "" >> description
			echo "_Upstreams / Patches are only applied to the patched version (\_patched.zip)_" >> description
			echo "_If a patch is not present anymore, it's most likely because it got merged, is not needed anymore or was breaking something._" >> description
		else 
			echo "### Upstreams / Patches (Experimental)" >> description
			echo "Include previously listed patches + experimental ones" >> description
			patch_to_description ${experimental_patches[@]}
			echo "true" > experimental
			echo "" >> description
			echo "_Experimental patches are only applied to the experimental version (\_experimental.zip)_" >> description
		fi
	fi

	if (( ${#failed_patches[@]} )); then
		echo "" >> description
		echo "#### Patches that failed to apply" >> description
		patch_to_description ${failed_patches[@]}
	fi
	
	if ! [ -a "$workdir"/"$filename".zip ];
		then echo -e "$red-Packing failed!$nocolor" && exit 1
		else echo -e "$green-All done, you can take your zip from this folder;$nocolor" && echo "$workdir"/
	fi
}

run_all
