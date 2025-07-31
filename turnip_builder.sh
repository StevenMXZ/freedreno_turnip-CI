#!/bin/bash -e

#Define variables
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'
deps="meson ninja patchelf unzip curl pip flex bison zip git" # Adicionado 'git' à lista de dependências
workdir="$(pwd)/turnip_workdir"
magiskdir="$workdir/turnip_module"
ndkver="android-ndk-r28"
sdkver="34"
# ALTERAÇÃO: URL alterada de .zip para o repositório .git para permitir o merge
mesasrc="https://gitlab.freedesktop.org/mesa/mesa.git"

clear

#There are 4 functions here, simply comment to disable.
#You can insert your own function and make a pull request.
run_all(){
	check_deps
	prepare_workdir
	build_lib_for_android
	port_lib_for_magisk
	port_lib_for_adrenotools
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
	echo "Preparing work directory ..." $'\n'
		mkdir -p "$workdir" && cd "$_"

	if [ ! -d "$ndkver" ]; then
		echo "Downloading android-ndk from google server ..." $'\n'
			curl https://dl.google.com/android/repository/"$ndkver"-linux.zip --output "$ndkver"-linux.zip &> /dev/null
		echo "Exracting android-ndk ..." $'\n'
			unzip "$ndkver"-linux.zip &> /dev/null
	fi

	if [ -d "mesa" ]; then
		echo "Removing old mesa directory..."
		rm -rf mesa
	fi

	# ALTERAÇÃO CRÍTICA: Trocado o download do ZIP por 'git clone' para permitir o merge.
	echo "Cloning mesa source via git..." $'\n'
	git clone "$mesasrc"
	cd mesa

	# ADICIONADO: Lógica de merge para o Sparse Residency
	echo -e "${green}Configuring local git identity for merge...${nocolor}"
	git config user.name "CI Builder"
	git config user.email "ci@builder.com"
	
	echo -e "${green}Fetching Merge Request !32671 for sparse residency...${nocolor}"
	git fetch origin refs/merge-requests/32671/head

	echo -e "${green}Merging fetched MR into current branch...${nocolor}"
	if git merge --no-edit FETCH_HEAD; then
		echo -e "${green}Merge successful!${nocolor}\n"
	else
		echo -e "${red}Merge failed. There might be conflicts that need to be resolved manually.${nocolor}"
		exit 1
	fi
}


build_lib_for_android(){
	ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
	#Workaround for using Clang as c compiler instead of GCC
	mkdir -p "$workdir/bin"
	ln -sf "$ndk/clang" "$workdir/bin/cc"
	ln -sf "$ndk/clang++" "$workdir/bin/c++"
	export PATH="$workdir/bin:$ndk:$PATH"
	export CC=clang
	export CXX=clang++
	export AR=llvm-ar
	export RANLIB=llvm-ranlib
	export STRIP=llvm-strip
	export OBJDUMP=llvm-objdump
	export OBJCOPY=llvm-objcopy
	export LDFLAGS="-fuse-ld=lld"

	echo "Generating build files ..." $'\n'
		cat <<EOF >"android-aarch64.txt"
[binaries]
ar = '$ndk/llvm-ar'
c = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang']
cpp = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = '$ndk/ld.lld'
cpp_ld = '$ndk/ld.lld'
strip = '$ndk/aarch64-linux-android-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$ndk/pkg-config', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

		cat <<EOF >"native.txt"
[build_machine]
c = ['ccache', 'clang']
cpp = ['ccache', 'clang++']
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

		meson setup build-android-aarch64 \
			--cross-file "android-aarch64.txt" \
			--native-file "native.txt" \
			-Dbuildtype=release \
			-Dplatforms=android \
			-Dplatform-sdk-version="$sdkver" \
			-Dandroid-stub=true \
			-Dgallium-drivers= \
			-Dvulkan-drivers=freedreno \
			-Dvulkan-beta=true \
			-Dfreedreno-kmds=kgsl \
			-Db_lto=true \
			-Dstrip=true \
			-Degl=disabled 2>&1 | tee "$workdir/meson_log"

	echo "Compiling build files ..." $'\n'
		# Usando tee para ver o log em tempo real e salvar em arquivo
		ninja -C build-android-aarch64 2>&1 | tee "$workdir/ninja_log"

	# ALTERAÇÃO: Caminho corrigido de 'mesa-main' para 'mesa'
	if ! [ -a "$workdir"/mesa/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so ]; then
		echo -e "$red Build failed! $nocolor" && exit 1
	fi
}

port_lib_for_magisk(){
	echo "Using patchelf to match soname ..." $'\n'
		# ALTERAÇÃO: Caminho corrigido de 'mesa-main' para 'mesa'
		cp "$workdir"/mesa/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so "$workdir"
		cd "$workdir"
		patchelf --set-soname vulkan.adreno.so libvulkan_freedreno.so
		mv libvulkan_freedreno.so vulkan.adreno.so

	echo "Prepare magisk module structure ..." $'\n'
		p1="system/vendor/lib64/hw"
		mkdir -p "$magiskdir" && cd "$_"
		mkdir -p "$p1"

		meta="META-INF/com/google/android"
		mkdir -p "$meta"

		cat <<EOF >"$meta/update-binary"
#################
# Initialization
#################
umask 022
ui_print() { echo "\$1"; }
OUTFD=\$2
ZIPFILE=\$3
. /data/adb/magisk/util_functions.sh
install_module
exit 0
EOF

		cat <<EOF >"$meta/updater-script"
#MAGISK
EOF

		cat <<EOF >"module.prop"
id=turnip_sparse
name=Turnip with Sparse Residency
version=$(cat $workdir/mesa/VERSION)-MR32671
versionCode=1
author=MrMiy4mo-CI
description=Turnip with experimental sparse residency support.
EOF

		cat <<EOF >"customize.sh"
# placeholder
EOF

	echo "Copy necessary files from work directory ..." $'\n'
		cp "$workdir"/vulkan.adreno.so "$magiskdir"/"$p1"

	echo "Packing files in to magisk module ..." $'\n'
		zip -r "$workdir"/turnip_magisk.zip ./* &> /dev/null
		if ! [ -a "$workdir"/turnip_magisk.zip ];
			then echo -e "$red-Packing failed!$nocolor" && exit 1
			else echo -e "$green-All done, the Magisk module saved to;$nocolor" && echo "$workdir"/turnip_magisk.zip
		fi
}

port_lib_for_adrenotools(){
	libname=vulkan.freedreno.so
	echo "Using patchelf to match soname for AdrenoTools" $'\n'
		# ALTERAÇÃO: Caminho corrigido de 'mesa-main' para 'mesa'
		cp "$workdir"/mesa/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so "$workdir"/$libname
		cd "$workdir"
		patchelf --set-soname $libname $libname
	echo "Preparing meta.json for AdrenoTools" $'\n'
		cat <<EOF > "meta.json"
{
	"schemaVersion": 1,
	"name": "Turnip (Sparse Residency)",
	"description": "Built on $(date) with MR !32671 for sparse residency",
	"author": "MrMiy4mo-CI, kethen",
	"packageVersion": "1",
	"vendor": "Mesa",
	"driverVersion": "$(cat $workdir/mesa/VERSION)-MR32671",
	"minApi": $sdkver,
	"libraryName": "$libname"
}
EOF

	zip -9 "$workdir"/turnip_adrenotools.zip $libname meta.json &> /dev/null
	if ! [ -a "$workdir"/turnip_adrenotools.zip ];
		then echo -e "$red-Packing turnip_adrenotools.zip failed!$nocolor" && exit 1
		else echo -e "$green-All done, the AdrenoTools module saved to;$nocolor" && echo "$workdir"/turnip_adrenotools.zip
	fi
}

run_all
