#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"
packagedir="$workdir/turnip_module"
ndkver="android-ndk-r29"
sdkver="35"
# ALTERADO: URL do repositório para o fork do Danil
mesasrc="https://gitlab.freedesktop.org/Danil/mesa.git"

base_patches=()
experimental_patches=()
failed_patches=()
commit=""
commit_short=""
mesa_version=""
vulkan_version=""
clear

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
				echo -e "$red - $deps_chk not found, can't continue. $nocolor"
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
		
		echo "Cloning mesa from Danil's fork..." $'\n'
		git clone "$mesasrc"

		cd mesa
		
		# ADICIONADO: Checkout para o branch específico
		echo -e "${green}Switching to branch 'tu-newat-fixes'...${nocolor}"
		git checkout tu-newat-fixes
		
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
	local ndk_root_path
	if [ -z "${ANDROID_NDK_LATEST_HOME}" ]; then
		ndk_root_path="$workdir/$ndkver"
	else	
		ndk_root_path="$ANDROID_NDK_LATEST_HOME"
	fi

	local ndk_bin_path="$ndk_root_path/toolchains/llvm/prebuilt/linux-x86_64/bin"
	local ndk_sysroot_path="$ndk_root_path/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

	cat <<EOF >"$workdir/mesa/android-aarch64"
[binaries]
ar = '$ndk_bin_path/llvm-ar'
c = ['ccache', '$ndk_bin_path/aarch64-linux-android$sdkver-clang', '--sysroot=$ndk_sysroot_path', '-Dandroid-strict=false']
cpp = ['ccache', '$ndk_bin_path/aarch64-linux-android$sdkver-clang++', '--sysroot=$ndk_sysroot_path', '-Dandroid-strict=false', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
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

	echo "Generating build files ..." $'\n'
	cd "$workdir/mesa"
	meson setup build-android-aarch64 \
		--cross-file "android-aarch64" \
		-Dbuildtype=release \
		-Dplatforms=android \
		-Dplatform-sdk-version=$sdkver \
		-Dandroid-stub=true \
		-Dgallium-drivers= \
		-Dvulkan-drivers=freedreno \
		-Dvulkan-beta=true \
		-Dfreedreno-kmds=kgsl \
		-Db_lto=true \
		-Dstrip=false \
		-Degl=disabled 2>&1 | tee "$workdir/meson_log"

	echo "Compiling build files ..." $'\n'
	ninja -C build-android-aarch64 2>&1 | tee "$workdir/ninja_log"

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
  "description": "Compiled from Mesa (Danil's fork, tu-newat-fixes), Commit $commit_short$suffix",
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
	cd "$packagedir"
	zip -9 "$workdir"/"$filename$suffix".zip ./*

	cd "$workdir"

	if [ -z "$1" ]; then
		echo "Turnip - $mesa_version - $date" > release
		echo "${mesa_version}_${commit_short}" > tag
		echo  "$filename$suffix" > filename
		echo "### Base commit : [$commit_short](https://gitlab.freedesktop.org/Danil/mesa/-/commit/$commit)" > description
		echo "false" > patched
		echo "false" > experimental
	else		
		if [ $1 == "patched" ]; then 
			echo "## Upstreams / Patches" >> description
			# ...
		else 
			echo "### Upstreams / Patches (Experimental)" >> description
			# ...
		fi
	fi

	if (( ${#failed_patches[@]} )); then
		echo "" >> description
		echo "#### Patches that failed to apply" >> description
		patch_to_description ${failed_patches[@]}
	fi
	
	if ! [ -a "$workdir"/"$filename$suffix".zip ];
		then echo -e "$red-Packing failed!$nocolor" && exit 1
		else echo -e "$green-All done, you can take your zip from this folder;$nocolor" && echo "$workdir"/
	fi
}

run_all
