#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# --- Config ---
deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
sdkver="35"
mesa_repo_main="https://gitlab.freedesktop.org/mesa/mesa.git"
mesa_repo_danil="https://gitlab.freedesktop.org/Danil/mesa.git"
danil_branch="tu-newat-fixes"
mesa_tag_patched="26.0.0" # Tag para a versão patched

# --- Variáveis Globais para Release Info ---
commit_main=""
commit_danil=""
commit_patched=""
version_main=""
version_danil=""
version_patched=""

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

# Função genérica para compilar
compile_mesa() {
    local source_dir=$1
    local build_dir_name=$2 # Ex: build-main, build-danil
    local description=$3

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

	# Criar cross file específico para este build (evita conflitos)
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
	meson setup "$build_dir_name" --cross-file "$cross_file_path" -Dbuildtype=release -Dplatforms=android -Dplatform-sdk-version=$sdkver -Dandroid-stub=true -Dgallium-drivers= -Dvulkan-drivers=freedreno -Dvulkan-beta=true -Dfreedreno-kmds=kgsl -Db_lto=true -Degl=disabled 2>&1 | tee "$workdir/meson_log_$description"

	echo "Compiling $description..."
	ninja -C "$build_dir_name" 2>&1 | tee "$workdir/ninja_log_$description"

    local compiled_lib="$source_dir/$build_dir_name/src/freedreno/vulkan/libvulkan_freedreno.so"
	if [ ! -f "$compiled_lib" ]; then
		echo -e "${red}Build failed for $description: libvulkan_freedreno.so not found.${nocolor}"
		exit 1
	fi
    echo -e "${green}--- Finished Compiling: $description ---${nocolor}\n"
    cd "$workdir" # Voltar para o diretório principal
}

# Função genérica para empacotar
package_driver() {
    local source_dir=$1       # Ex: mesa_main
    local build_dir_name=$2   # Ex: build-main
    local output_suffix=$3    # Ex: main, danil, patched_ubwc
    local description_name=$4 # Ex: Mesa Main, Danil's Fork
    local version_str=$5      # Ex: 26.0.0-devel
    local commit_hash_short=$6 # Ex: a1b2c3d
    local commit_hash_full=$7  # Ex: a1b2c3d4e5f...
    local repo_url=$8          # URL base para link do commit

    echo -e "${green}--- Packaging: $description_name ---${nocolor}"
    local compiled_lib="$workdir/$source_dir/$build_dir_name/src/freedreno/vulkan/libvulkan_freedreno.so"
    local output_filename="turnip_${output_suffix}_$(date +'%Y%m%d')_${commit_hash_short}.zip"
    local package_temp_dir="$workdir/package_temp_${output_suffix}"
    local lib_final_name="vulkan.ad07XX.so"

    mkdir -p "$package_temp_dir"
    
    cp "$compiled_lib" "$package_temp_dir/libvulkan_freedreno.so"
    cd "$package_temp_dir"
    
    patchelf --set-soname vulkan.adreno.so libvulkan_freedreno.so
    mv libvulkan_freedreno.so "$lib_final_name"

	date_meta=$(date +'%b %d, %Y')
	cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "Turnip ($description_name) - $date_meta - $commit_hash_short",
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

    rm -rf "$package_temp_dir" # Limpa a pasta temporária
    cd "$workdir" # Volta para o diretório principal
    echo -e "${green}--- Finished Packaging: $description_name ---${nocolor}\n"
}

# --- Funções de Build Específicas ---

build_mesa_main() {
    local dir_name="mesa_main"
    local build_dir="build-main"
    echo -e "${green}=== Building Mesa Main ===${nocolor}"
    git clone --depth=1 "$mesa_repo_main" "$dir_name"
    cd "$dir_name"
    commit_main=$(git rev-parse HEAD)
    version_main=$(cat VERSION | xargs)
    cd ..
    compile_mesa "$workdir/$dir_name" "$build_dir" "Mesa_Main"
    package_driver "$dir_name" "$build_dir" "main" "Mesa Main" "$version_main" "$(git -C $dir_name rev-parse --short HEAD)" "$commit_main" "$mesa_repo_main"
}

build_danil_fork() {
    local dir_name="mesa_danil"
    local build_dir="build-danil"
    echo -e "${green}=== Building Danil's Fork ===${nocolor}"
    git clone "$mesa_repo_danil" "$dir_name"
    cd "$dir_name"
    git checkout "$danil_branch"
    commit_danil=$(git rev-parse HEAD)
    version_danil=$(cat VERSION | xargs)
    cd ..
    compile_mesa "$workdir/$dir_name" "$build_dir" "Danil_Fork"
    package_driver "$dir_name" "$build_dir" "danil" "Danil's Fork ($danil_branch)" "$version_danil" "$(git -C $dir_name rev-parse --short HEAD)" "$commit_danil" "$mesa_repo_danil"
}

build_mesa_patched() {
    local dir_name="mesa_patched"
    local build_dir="build-patched"
    echo -e "${green}=== Building Patched Mesa ($mesa_tag_patched) ===${nocolor}"
    git clone "$mesa_repo_main" "$dir_name"
    cd "$dir_name"
    git checkout "$mesa_tag_patched"
    
    echo "Applying patch: enable_tp_ubwc_flag_hint = True..."
	sed -i 's/enable_tp_ubwc_flag_hint = False,/enable_tp_ubwc_flag_hint = True,/' src/freedreno/common/freedreno_devices.py
	echo "Patch applied."

    commit_patched=$(git rev-parse HEAD)
    version_patched="$mesa_tag_patched" # A versão é a tag
    cd ..
    compile_mesa "$workdir/$dir_name" "$build_dir" "Mesa_Patched"
    package_driver "$dir_name" "$build_dir" "patched_ubwc" "Mesa $mesa_tag_patched (Patched: UBWC Hint)" "$version_patched" "$(git -C $dir_name rev-parse --short HEAD)" "$commit_patched" "$mesa_repo_main"
}

# --- Geração de Info para Release ---
generate_release_info() {
    echo -e "${green}Generating release info files for GitHub Actions...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
    local main_commit_short=$(git -C mesa_main rev-parse --short HEAD)

    # Tag baseada na data e commit principal
    echo "Mesa-${date_tag}-${main_commit_short}" > tag
    echo "Turnip CI Build - ${date_tag}" > release

    # Descrição detalhada
    echo "Automated Turnip CI build." > description
    echo "" >> description
    echo "### Included Drivers:" >> description
    echo "" >> description
    echo "**1. Mesa Main:**" >> description
    echo "   - Version: \`$version_main\`" >> description
    echo "   - Commit: [${main_commit_short}](${mesa_repo_main%.git}/-/commit/${commit_main})" >> description
    echo "" >> description
    echo "**2. Danil's Fork:**" >> description
    echo "   - Branch: \`$danil_branch\`" >> description
    echo "   - Version: \`$version_danil\`" >> description
    echo "   - Commit: [$(git -C mesa_danil rev-parse --short HEAD)](${mesa_repo_danil%.git}/-/commit/${commit_danil})" >> description
    echo "" >> description
    echo "**3. Mesa Patched (UBWC Hint):**" >> description
    echo "   - Base Tag: \`$version_patched\`" >> description
    echo "   - Patch: \`enable_tp_ubwc_flag_hint = True\`" >> description
    echo "   - Commit: [$(git -C mesa_patched rev-parse --short HEAD)](${mesa_repo_main%.git}/-/commit/${commit_patched})" >> description
    
    echo -e "${green}Release info generated.${nocolor}"
}

# --- Execução Principal ---
check_deps
mkdir -p "$workdir"
prepare_ndk

# Executa os builds em sequência
build_mesa_main
build_danil_fork
build_mesa_patched

# Gera os arquivos para a release do GitHub
generate_release_info

echo -e "${green}All builds completed successfully!${nocolor}"
