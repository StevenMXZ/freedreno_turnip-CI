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

compile_mesa() {
    local source_dir=$1
    local build_dir_name=$2
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
    cd "$workdir"
}

package_driver() {
    local source_dir=$1
    local build_dir_name=$2
    local output_suffix=$3 # main, danil, oneui
    local description_name=$4
    local version_str=$5
    local commit_hash_short=$6
    local commit_hash_full=$7
    local repo_url=$8

    echo -e "${green}--- Packaging: $description_name ---${nocolor}"
    local compiled_lib="$workdir/$source_dir/$build_dir_name/src/freedreno/vulkan/libvulkan_freedreno.so"
    local package_temp_dir="$workdir/package_temp_${output_suffix}"
    local lib_final_name="vulkan.ad07XX.so" # Nome final dentro do zip
    
    local filename_base="turnip_$(date +'%Y%m%d')_${commit_hash_short}"
    local output_filename
    if [[ "$output_suffix" == "main" ]]; then
        output_filename="${filename_base}.zip"
    else
        output_filename="${filename_base}_${output_suffix}.zip"
    fi

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

    rm -rf "$package_temp_dir"
    cd "$workdir"
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
    version_patched="$mesa_tag_patched"
    cd ..
    compile_mesa "$workdir/$dir_name" "$build_dir" "Mesa_Patched"
    package_driver "$dir_name" "$build_dir" "oneui" "Mesa $mesa_tag_patched (Patched: OneUI/UBWC)" "$version_patched" "$(git -C $dir_name rev-parse --short HEAD)" "$commit_patched" "$mesa_repo_main"
}

# --- Geração de Info para Release ---
generate_release_info() {
    echo -e "${green}Generating release info files for GitHub Actions...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
    local main_commit_short=$(git -C mesa_main rev-parse --short HEAD)
    local danil_commit_short=$(git -C mesa_danil rev-parse --short HEAD)
    local patched_commit_short=$(git -C mesa_patched rev-parse --short HEAD)

    # Tag para a release
    echo "Mesa-${date_tag}-${main_commit_short}" > tag
    # Nome da release
    echo "Turnip CI Build - ${date_tag}" > release

    # Criação do arquivo de descrição
    echo "Automated Turnip CI build." > description
    echo "" >> description
    echo "### Included Drivers:" >> description
    echo "" >> description
    
    # Descrição Build 1: Mesa Main
    echo "**1. Latest Mesa Main (turnip\_<date>\_${main_commit_short}.zip):**" >> description
    echo "   - Standard Turnip driver built from the latest Mesa main branch." >> description
    echo "   - Version: \`$version_main\`" >> description
    echo "   - Commit: [${main_commit_short}](${mesa_repo_main%.git}/-/commit/${commit_main})" >> description
    echo "" >> description
    
    # Descrição Build 2: Danil's Fork
    echo "**2. Danil's Fork (turnip\_danil\_<date>\_${danil_commit_short}.zip):**" >> description
    echo "   - Build from Danil's fork, branch \`$danil_branch\`. Includes potential fixes/improvements (e.g., for Autotune based on branch name)." >> description
    echo "   - Version: \`$version_danil\`" >> description
    echo "   - Commit: [${danil_commit_short}](${mesa_repo_danil%.git}/-/commit/${commit_danil})" >> description
    echo "" >> description
    
    # Descrição Build 3: Turnip OneUI (Patched)
    echo "**3. Turnip OneUI Patched (turnip\_oneui\_<date>\_${patched_commit_short}.zip):**" >> description
    echo "   - Based on Mesa tag \`$version_patched\`, patched to enable \`enable_tp_ubwc_flag_hint=True\`." >> description
    echo "   - Aims for better compatibility on Adreno 740 devices running Samsung OneUI." >> description
    echo "   - Commit (base): [${patched_commit_short}](${mesa_repo_main%.git}/-/commit/${commit_patched})" >> description
    
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
