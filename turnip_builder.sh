#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# --- Config ---
deps="meson ninja patchelf unzip curl pip zip git gh"
workdir="$(pwd)/turnip_workdir"
packagedir="$workdir/turnip_module"
ndkver="android-ndk-r28"
sdkver="34"
# Alterado para o repositório git para permitir o merge do MR
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

	pip install mako &> /dev/null || true
}

prepare_workdir(){
	echo "Preparing work directory ..."
	mkdir -p "$workdir" && cd "$workdir"

	if [ -d mesa ]; then
		echo "Removing old Mesa ..."
		rm -rf mesa
	fi

	# ADICIONADO: Clonando o repositório git com histórico completo
	echo "Cloning Mesa source via git..."
	git clone "$mesasrc"
	cd mesa

	# ADICIONADO: Configuração de identidade local para o Git, necessária para o merge
	echo -e "${green}Configuring local git identity for merge...${nocolor}"
	git config user.name "CI Builder"
	git config user.email "ci@builder.com"
	
	# ADICIONADO: Lógica de merge do Merge Request para suporte a memória esparsa
	echo -e "${green}Fetching Merge Request !32671 for sparse residency...${nocolor}"
	git fetch origin refs/merge-requests/32671/head

	echo -e "${green}Merging fetched MR into current branch...${nocolor}"
	if git merge --no-edit FETCH_HEAD; then
		echo -e "${green}Merge successful!${nocolor}\n"
	else
		echo -e "${red}Merge failed. There might be conflicts that need to be resolved manually.${nocolor}"
		exit 1
	fi
	
	commit_short=$(git rev-parse --short HEAD)
	commit=$(git rev-parse HEAD)
	mesa_version=$(cat VERSION | xargs)
	# Preenchendo as variáveis de versão do vulkan
	version=$(awk -F'COMPLETE VK_MAKE_API_VERSION(|)' '{print $2}' <<< $(cat include/vulkan/vulkan_core.h) | xargs)
	major=$(echo $version | cut -d "," -f 2 | xargs)
	minor=$(echo $version | cut -d "," -f 3 | xargs)
	patch=$(awk -F'VK_HEADER_VERSION |\n#define' '{print $2}' <<< $(cat include/vulkan/vulkan_core.h) | xargs)
	vulkan_version="$major.$minor.$patch"

}

build_lib_for_android(){
	ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
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

	echo "Generating build files ..."
	cat <<EOF >"$workdir/mesa/android-aarch64.txt"
[binaries]
ar = '$ndk/llvm-ar'
c = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang']
cpp = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = '$ndk/ld.lld'
cpp_ld = '$ndk/ld.lld'
strip = '$ndk/aarch64-linux-android-strip'
# CORREÇÃO: "pkgconfig" alterado para "pkg-config"
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
	# O comando meson é executado do diretório 'mesa'
	cd "$workdir/mesa"
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

	echo "Compiling ..."
	ninja -C build-android-aarch64 2>&1 | tee "$workdir/ninja_log"

	# Retorna ao diretório de trabalho principal
	cd "$workdir"
}

package_turnip(){
	echo "Packaging Turnip ..."
	# As variáveis de versão e commit já foram preenchidas em prepare_workdir()
	
	# Prepara a pasta para o módulo Magisk
	p1="system/vendor/lib64/hw"
	mkdir -p "$packagedir" && cd "$packagedir"
	mkdir -p "$p1"
	
	# Patcheia e move o arquivo para a pasta do módulo Magisk
	cp "$workdir/mesa/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so" "$workdir"
	cd "$workdir"
	patchelf --set-soname vulkan.adreno.so libvulkan_freedreno.so
	mv libvulkan_freedreno.so vulkan.adreno.so
	cp "$workdir/vulkan.adreno.so" "$packagedir/$p1"
	
	# Cria os arquivos de metadados do Magisk
	cat <<EOF >"module.prop"
id=turnip_sparse
name=Turnip with Sparse Residency
version=${mesa_version}-MR32671
versionCode=1
author=CI-Build
description=Turnip with experimental sparse residency support.
EOF
	cat <<EOF >"customize.sh"
# placeholder
EOF
	# Move os metadados para a pasta do módulo
	mv module.prop customize.sh "$packagedir"

	echo "Packing files in to magisk module ..."
	zip -r "$workdir/turnip_magisk.zip" "$packagedir" &> /dev/null
	
	if ! [ -a "$workdir"/turnip_magisk.zip ]; then
		echo -e "$red-Packaging failed!$nocolor" && exit 1
	else
		echo -e "$green-Magisk module ready: $workdir/turnip_magisk.zip $nocolor"
	fi

	# Prepara o arquivo para o AdrenoTools
	cp "$workdir"/mesa/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so "$workdir"/vulkan.freedreno.so
	patchelf --set-soname vulkan.freedreno.so "$workdir"/vulkan.freedreno.so
	cat <<EOF > "$workdir/meta.json"
{
	"schemaVersion": 1,
	"name": "Turnip (Sparse Residency)",
	"description": "Built on $(date) with MR !32671 for sparse residency",
	"author": "CI-Build",
	"packageVersion": "1",
	"vendor": "Mesa",
	"driverVersion": "${mesa_version}-MR32671",
	"minApi": $sdkver,
	"libraryName": "vulkan.freedreno.so"
}
EOF
	zip -9 "$workdir"/turnip_adrenotools.zip "$workdir"/vulkan.freedreno.so "$workdir"/meta.json &> /dev/null
	if ! [ -a "$workdir"/turnip_adrenotools.zip ]; then
		echo -e "$red-Packaging adrenotools failed!$nocolor" && exit 1
	else
		echo -e "$green-AdrenoTools module ready: $workdir/turnip_adrenotools.zip $nocolor"
	fi
}

# NOVO: Função para gerar os arquivos de texto para a Release do GitHub
generate_release_info() {
    echo -e "${green}Generating release info files for GitHub Actions...${nocolor}"
    cd "$workdir"
    local date_str=$(date +'%b %d, %Y')
    
    echo "${mesa_version}_${commit_short}" > tag
    echo "Turnip - Mesa ${mesa_version} - ${commit_short}" > release
    echo "### Mesa version: ${mesa_version}" > description
    echo "### Base commit: [${commit_short}](https://gitlab.freedesktop.org/mesa/mesa/-/commit/${commit})" >> description
    echo "" >> description
    echo "Experimental build with Merge Request !32671 (Sparse Residency) merged." >> description
    
    echo "false" > patched
    echo "false" > experimental
}


# --- Execução ---
check_deps
prepare_workdir
build_lib_for_android
package_turnip
generate_release_info
