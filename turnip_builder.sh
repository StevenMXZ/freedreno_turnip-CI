#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# --- Config ---
deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
sdkver="35"
# ALTERADO: URL de volta para o fork do Danil
mesasrc="https://gitlab.freedesktop.org/Danil/mesa.git"
# ALTERADO: Branch a ser compilado
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
	# Cria o diretório de trabalho principal aqui se não existir
	mkdir -p "$workdir"
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

prepare_mesa_source() {
    echo "Preparing Mesa source directory (Danil's Fork)..."
    cd "$workdir"
    if [ -d mesa ]; then
		echo "Removing old Mesa ..."
		rm -rf mesa
	fi
    
    echo "Cloning Danil's Mesa repository..."
	# Clone completo para permitir checkout de branch
	git clone "$mesasrc" mesa
	cd mesa

    # Checkout para o branch desejado
    echo -e "${green}Checking out branch '$target_branch'...${nocolor}"
    git checkout "$target_branch"

    commit_target=$(git rev-parse HEAD)
    version_target=$(cat VERSION | xargs)
    cd "$workdir" # Voltar para o diretório principal
}

compile_mesa() {
    local source_dir="$workdir/mesa"
    local build_dir_name="build"
    local description="Danil's Fork ($target_branch)"

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
	meson setup --reconfigure "$build_dir_name" --cross-file "$cross_file_path" -Dbuildtype=release -Dplatforms=android -Dplatform-sdk-version=$sdkver -Dandroid-stub=true -Dgallium-drivers= -Dvulkan-drivers=freedreno -Dvulkan-beta=true -Dfreedreno-kmds=kgsl -Db_lto=true -Degl=disabled 2>&1 | tee "$workdir/meson_log"

	echo "Compiling $description..."
	ninja -C "$build_dir_name" 2>&1 | tee "$workdir/ninja_log"

    local compiled_lib="$source_dir/$build_dir_name/src/freedreno/vulkan/libvulkan_freedreno.so"
	if [ ! -f "$compiled_lib" ]; then
		echo -e "${red}Build failed: libvulkan_freedreno.so not found.${nocolor}"
		exit 1
	fi
    echo -e "${green}--- Finished Compiling: $description ---${nocolor}\n"
    cd "$workdir"
}

package_driver() {
    local source_dir="$workdir/mesa"
    local build_dir_name="build"
    local description_name="Danil's Fork ($target_branch)" # Descrição atualizada
    local version_str=$version_target
    local commit_hash_short=$(git -C $source_dir rev-parse --short HEAD)
    local commit_hash_full=$commit_target
    local repo_url=$mesasrc # URL do fork do Danil

    echo -e "${green}--- Packaging: $description_name ---${nocolor}"
    local compiled_lib="$source_dir/$build_dir_name/src/freedreno/vulkan/libvulkan_freedreno.so"
    local package_temp_dir="$workdir/package_temp_single"
    
    local lib_final_name="vulkan.ad07XX.so" 
    local soname="vulkan.adreno.so" 

    # Nome do arquivo ZIP sem sufixo extra
    local output_filename="turnip_$(date +'%Y%m%d')_${commit_hash_short}.zip"

    mkdir -p "$package_temp_dir"
    
    cp "$compiled_lib" "$package_temp_dir/lib_temp.so"
    cd "$package_temp_dir"
    
    patchelf --set-soname "$soname" lib_temp.so
    mv lib_temp.so "$lib_final_name"

	date_meta=$(date +'%b %d, %Y')
    local meta_name="Turnip-Danil-${commit_hash_short}" # Nome curto atualizado
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

generate_release_info() {
    echo -e "${green}Generating release info files for GitHub Actions...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
    local target_commit_short=$(git -C mesa rev-parse --short HEAD)

    # Tag baseada na data e commit
    echo "Danil-${date_tag}-${target_commit_short}" > tag
    echo "Turnip CI Build - ${date_tag} (Danil's Fork)" > release

    echo "Automated Turnip CI build from Danil's Mesa fork." > description
    echo "" >> description
    echo "### Build Details:" >> description
    echo "**Base:** Danil's Mesa fork, branch \`$target_branch\`" >> description
    echo "**Commit:** [${target_commit_short}](${repo_url%.git}/-/commit/${commit_target})" >> description # Usa repo_url para link correto
    
    echo -e "${green}Release info generated.${nocolor}"
}


# --- Execução Principal ---
check_deps
prepare_ndk
prepare_mesa_source
compile_mesa
package_driver
generate_release_info

echo -e "${green}Build completed successfully!${nocolor}"
