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
mesa_repo_danil="https://gitlab.freedesktop.org/Danil/mesa.git" # Mantido caso precise reativar
autotuner_mr_num="37802"
mesa_tag_patched="26.0.0"

# --- Variáveis Globais ---
commit_main=""
commit_autotuner_mr=""
commit_patched=""
version_main=""
version_autotuner_mr=""
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
	meson setup --reconfigure "$build_dir_name" --cross-file "$cross_file_path" -Dbuildtype=release -Dplatforms=android -Dplatform-sdk-version=$sdkver -Dandroid-stub=true -Dgallium-drivers= -Dvulkan-drivers=freedreno -Dvulkan-beta=true -Dfreedreno-kmds=kgsl -Db_lto=true -Degl=disabled 2>&1 | tee "$workdir/meson_log_$description"

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
    local output_suffix=$3 # main, autotuner_mr, oneui
    local description_name=$4
    local version_str=$5
    local commit_hash_short=$6
    local commit_hash_full=$7
    local repo_url=$8

    echo -e "${green}--- Packaging: $description_name ---${nocolor}"
    local compiled_lib="$workdir/$source_dir/$build_dir_name/src/freedreno/vulkan/libvulkan_freedreno.so"
    local package_temp_dir="$workdir/package_temp_${output_suffix}"
    
    local lib_final_name
    case "$output_suffix" in
        main)
            lib_final_name="vulkan.adreno.main.so"
            ;;
        autotuner_mr)
            lib_final_name="vulkan.adreno.autotuner.so"
            ;;
        oneui)
            lib_final_name="vulkan.adreno.oneui.so"
            ;;
        *)
            lib_final_name="vulkan.adreno.${output_suffix}.so"
            ;;
    esac
    
    local filename_base="turnip_$(date +'%Y%m%d')_${commit_hash_short}"
    local output_filename
    if [[ "$output_suffix" == "main" ]]; then
        output_filename="${filename_base}.zip"
    else
        output_filename="${filename_base}_${output_suffix}.zip"
    fi

    mkdir -p "$package_temp_dir"
    
    cp "$compiled_lib" "$package_temp_dir/lib_temp.so"
    cd "$package_temp_dir"
    
    patchelf --set-soname "$lib_final_name" lib_temp.so
    mv lib_temp.so "$lib_final_name"

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

build_mesa_main_autotuner_mr() {
    local dir_name="mesa_autotuner_mr"
    local build_dir="build-autotuner-mr"
    echo -e "${green}=== Building Mesa Main + Autotuner MR !${autotuner_mr_num} ===${nocolor}"
    git clone "$mesa_repo_main" "$dir_name"
    cd "$dir_name"
    
	echo -e "${green}Configuring local git identity for merge...${nocolor}"
	git config user.name "CI Builder"
	git config user.email "ci@builder.com"
	
	echo -e "${green}Fetching Merge Request !${autotuner_mr_num}...${nocolor}"
	git fetch origin "refs/merge-requests/${autotuner_mr_num}/head"
	echo -e "${green}Merging fetched MR into current branch...${nocolor}"
	if git merge --no-edit FETCH_HEAD; then
		echo -e "${green}Merge successful!${nocolor}\n"
	else
		echo -e "${red}Merge failed for MR !${autotuner_mr_num}. Conflicts might need manual resolution.${nocolor}"
        echo -e "${yellow}Skipping Autotuner MR build due to merge failure.${nocolor}"
        cd ..
        commit_autotuner_mr="" 
        version_autotuner_mr="N/A"
        return 
	fi

    commit_autotuner_mr=$(git rev-parse HEAD)
    version_autotuner_mr=$(cat VERSION | xargs)
    cd ..
    compile_mesa "$workdir/$dir_name" "$build_dir" "Mesa_Autotuner_MR"
    package_driver "$dir_name" "$build_dir" "autotuner_mr" "Mesa Main + Autotuner MR" "$version_autotuner_mr" "$(git -C $dir_name rev-parse --short HEAD)" "$commit_autotuner_mr" "$mesa_repo_main"
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
    # ALTERADO: Descrição removendo "UBWC"
    package_driver "$dir_name" "$build_dir" "oneui" "Mesa $mesa_tag_patched (Patched: OneUI)" "$version_patched" "$(git -C $dir_name rev-parse --short HEAD)" "$commit_patched" "$mesa_repo_main"
}

# --- Geração de Info para Release ---
generate_release_info() {
    echo -e "${green}Generating release info files for GitHub Actions...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
    local main_commit_short=$(git -C mesa_main rev-parse --short HEAD)
    local autotuner_commit_short=""
    if [ -d "mesa_autotuner_mr" ] && [ -n "$commit_autotuner_mr" ]; then
       autotuner_commit_short=$(git -C mesa_autotuner_mr rev-parse --short HEAD)
    fi
    local patched_commit_short=$(git -C mesa_patched rev-parse --short HEAD)

    echo "Mesa-${date_tag}-${main_commit_short}" > tag
    echo "Turnip CI Build - ${date_tag}" > release

    echo "Automated Turnip CI build." > description
    echo "" >> description
    echo "### Included Drivers:" >> description
    echo "" >> description
    
    echo "**1. Latest Mesa Main (turnip\_<date>\_${main_commit_short}.zip):**" >> description
    echo "   - Standard Turnip driver built from the latest Mesa main branch." >> description
    echo "   - Version: \`$version_main\`" >> description
    echo "   - Commit: [${main_commit_short}](${mesa_repo_main%.git}/-/commit/${commit_main})" >> description
    echo "" >> description
    
    echo "**2. Main + New Autotuner MR (turnip\_autotuner\_mr\_<date>\_${autotuner_commit_short}.zip):**" >> description
    echo "   - Build from latest Mesa main branch + Merged Request !${autotuner_mr_num} (new autotuner logic)." >> description
    if [ -n "$autotuner_commit_short" ]; then
        echo "   - Version: \`$version_autotuner_mr\`" >> description
        echo "   - Merged Commit: [${autotuner_commit_short}](${mesa_repo_main%.git}/-/commit/${commit_autotuner_mr})" >> description
    else
        echo "   - *Build skipped due to merge conflicts.*" >> description
    fi
    echo "" >> description
    
    # ALTERADO: Descrição removendo "UBWC"
    echo "**3. Turnip OneUI Patched (turnip\_oneui\_<date>\_${patched_commit_short}.zip):**" >> description
    echo "   - Based on Mesa tag \`$version_patched\`, patched to enable \`enable_tp_ubwc_flag_hint=True\`." >> description
    echo "   - Aims for better compatibility on certain Adreno devices running Samsung OneUI." >> description # Ajuste na descrição
    echo "   - Commit (base): [${patched_commit_short}](${mesa_repo_main%.git}/-/commit/${commit_patched})" >> description
    
    echo -e "${green}Release info generated.${nocolor}"
}


# --- Execução Principal ---
check_deps
mkdir -p "$workdir"
prepare_ndk

build_mesa_main
build_mesa_main_autotuner_mr
build_mesa_patched

generate_release_info

echo -e "${green}All builds completed successfully!${nocolor}"
