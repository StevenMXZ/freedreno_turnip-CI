#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# --- Config ---
deps="meson ninja patchelf unzip curl pip zip git gh"
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

# --- Funções ---
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

	# Python Mako
	pip install mako &> /dev/null || true
}

prepare_workdir(){
	echo "Preparing work directory ..."
	mkdir -p "$workdir" && cd "$workdir"

	if [ -d mesa ]; then
		echo "Removing old Mesa ..."
		rm -rf mesa
	fi

	echo "Cloning Mesa ..."
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
	echo "Creating meson cross file ..."
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

	echo "Generating build files ..."
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

	echo "Compiling ..."
	ninja -C build-android-aarch64 &> "$workdir"/ninja_log
}

package_turnip(){
	echo "Packaging Turnip ..."
	cp "$workdir"/mesa/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so "$workdir"
	cd "$workdir"
	patchelf --set-soname vulkan.adreno.so libvulkan_freedreno.so
	mv libvulkan_freedreno.so vulkan.ad07XX.so

	mkdir -p "$packagedir" && cd "$packagedir"
	cp "$workdir"/vulkan.ad07XX.so .

	date_str=$(date +'%b-%d-%Y')
	filename="turnip_${date_str}_$commit_short.zip"

	zip -9 "$workdir/$filename" ./*

	if ! [ -f "$workdir/$filename" ]; then
		echo -e "$red Packaging failed! $nocolor" && exit 1
	else
		echo -e "$green Package ready: $workdir/$filename $nocolor"
	fi
}

create_github_release(){
	echo "Creating GitHub release ..."
	TAG_NAME="turnip-$commit_short"

	# Cria tag se não existir
	if ! git rev-parse "$TAG_NAME" >/dev/null 2>&1; then
		git tag -a "$TAG_NAME" -m "Turnip release $TAG_NAME"
		git push origin "$TAG_NAME"
	fi

	# Cria release via gh CLI
	gh release create "$TAG_NAME" "$workdir/$filename" \
		--title "Turnip $mesa_version - $commit_short" \
		--notes "Automated Turnip release from Mesa commit $commit_short"
}

# --- Execução ---
check_deps
prepare_workdir
build_lib_for_android
package_turnip
create_github_release
