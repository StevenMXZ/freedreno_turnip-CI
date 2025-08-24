#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="meson ninja patchelf unzip curl pip zip git"
workdir="$(pwd)/turnip_workdir"
packagedir="$workdir/turnip_module"
ndkver="android-ndk-r29"
sdkver="33"
mesasrc="https://gitlab.freedesktop.org/mesa/mesa.git"

commit=""
commit_short=""
mesa_version=""
vulkan_version=""
clear

run_all(){
	check_deps
	prep
}

prep () {
	prepare_workdir
	build_lib_for_android
	port_lib_for_adrenotool
}

check_deps(){
	echo "Checking system for required Dependencies ..."
	for deps_chk in $deps; do
		sleep 0.25
		if command -v "$deps_chk" >/dev/null 2>&1 ; then
			echo -e "$green - $deps_chk found $nocolor"
		else
			echo -e "$red - $deps_chk not found, can't continue. $nocolor"
			deps_missing=1
		fi
	done

	if [ "$deps_missing" == "1" ]; then
		echo "Please install missing dependencies" && exit 1
	fi

	echo "Installing python Mako dependency (if missing) ..." $'\n'
	pip install mako &> /dev/null
}

prepare_workdir(){
	echo "Creating and entering work directory ..." $'\n'
	mkdir -p "$workdir" && cd "$_"

	if [ -z "${ANDROID_NDK_LATEST_HOME}" ]; then
		if [ ! -n "$(ls -d android-ndk*)" ]; then
			echo "Downloading android-ndk from Google server (~640 MB) ..." $'\n'
			curl https://dl.google.com/android/repository/"$ndkver"-linux.zip --output "$ndkver"-linux.zip &> /dev/null
			echo "Extracting android-ndk to a folder ..." $'\n'
			unzip "$ndkver"-linux.zip &> /dev/null
		fi
	else	
		echo "Using android NDK from environment"
	fi

	if [ -d mesa ]; then
		echo "Removing old Mesa ..." $'\n'
		rm -rf mesa
	fi

	echo "Cloning Mesa ..." $'\n'
	git clone --depth=1 "$mesasrc"
	cd mesa

	commit_short=$(git rev-parse --short HEAD)
	commit=$(git rev-parse HEAD)
	mesa_version=$(cat VERSION | xargs)
	version=$(awk -F'COMPLETE VK_MAKE_API_VERSION(|)' '{print $2}' <<< $(cat include/vulkan/vulkan_core.h) | xargs)
	major=$(echo $version | cut -d "," -f 2 | xargs)
	minor=$(echo $version | cut -d "," -f 3 | xargs)
	patch=$(awk -F'VK_HEADER_VERSION |\n#define' '{print $2}' <<< $(cat include/vulkan/vulkan_core.h) | xargs)
	vulkan_version="$major.$minor.$patch"
}

build_lib_for_android(){
	echo "Creating meson cross file ..." $'\n'
	if [ -z "${ANDROID_NDK_LATEST_HOME}" ]; then
		ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
	else	
		ndk="$ANDROID_NDK_LATEST_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
	fi

	cat <<EOF >"$workdir/mesa/android-aarch64"
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
	meson setup build-android-aarch64 --cross-file "$workdir"/mesa/android-aarch64 \
		-Dplatforms=android \
		-Dplatform-sdk-version=$sdkver \
		-Dandroid-stub=true \
		-Dgallium-drivers= \
		-Dvulkan-drivers=freedreno \
		-Dvulkan-beta=true \
		-Dfreedreno-kmds=kgsl \
		-Db_lto=true \
		-Dstrip=false \
		-Degl=disabled &> "$workdir"/meson_log

	echo "Compiling build files ..." $'\n'
	ninja -C build-android-aarch64 &> "$workdir"/ninja_log
}

port_lib_for_adrenotool(){
	echo "Using patchelf to match soname ..." $'\n'
	cp "$workdir"/mesa/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so "$workdir"
	cd "$workdir"
	patchelf --set-soname vulkan.adreno.so libvulkan_freedreno.so
	mv libvulkan_freedreno.so vulkan.ad07XX.so

	if ! [ -a vulkan.ad07XX.so ]; then
		echo -e "$red Build failed! $nocolor" && exit 1
	fi

	mkdir -p "$packagedir" && cd "$_"

	date=$(date +'%b %d, %Y')
	cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "Turnip - $date - $commit_short",
  "description": "Compiled from Mesa, Commit $commit_short",
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

	echo "Packing files into adrenotool package ..." $'\n'
	zip -9 "$workdir"/"$filename".zip ./*

	if ! [ -a "$workdir"/"$filename".zip ]; then
		echo -e "$red-Packing failed!$nocolor" && exit 1
	else
		echo -e "$green-All done! Zip available at $workdir/$filename.zip$nocolor"
	fi
}

run_all
