#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
sdkver="35"  # Android 15
mesa_repo_main="https://gitlab.freedesktop.org/mesa/mesa.git"

commit_main=""
version_main=""

clear

check_deps(){
    echo "Checking system dependencies ..."
    missing=0
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
            echo "Extracting android-ndk ..."
            unzip "$ndkver"-linux.zip &> /dev/null
        fi
    else
        echo "Using android ndk from environment"
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
c = ['$ndk_bin_path/aarch64-linux-android$sdkver-clang', '--sysroot=$ndk_sysroot_path']
cpp = ['$ndk_bin_path/aarch64-linux-android$sdkver-clang++', '--sysroot=$ndk_sysroot_path']
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
    meson setup --reconfigure "$build_dir_name" --cross-file "$cross_file_path" \
        -Dbuildtype=release \
        -Dplatforms=android \
        -Dplatform-sdk-version=$sdkver \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dvulkan-beta=true \
        -Dfreedreno-kmds=kgsl \
        -Db_lto=false \
        -Degl=disabled 2>&1 | tee "$workdir/meson_log_$description"

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
    local output_suffix=$3
    local description_name=$4
    local version_str=$5
    local commit_hash_short=$6
    local commit_hash_full=$7
    local repo_url=$8

    echo -e "${green}--- Packaging: $description_name ---${nocolor}"
    local compiled_lib="$workdir/$source_dir/$build_dir_name/src/freedreno/vulkan/libvulkan_freedreno.so"
    local package_temp_dir="$workdir/package_temp_${output_suffix}"

    local filename_base="turnip_$(date +'%Y%m%d')_${commit_hash_short}"
    local output_filename="${filename_base}.zip"

    mkdir -p "$package_temp_dir"
    cp "$compiled_lib" "$package_temp_dir/libvulkan_freedreno.so"

    cd "$package_temp_dir"
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
  "minApi": 35,
  "libraryName": "libvulkan_freedreno.so"
}
EOF

    echo "Packing $output_filename..."
    zip -9 "$workdir/$output_filename" libvulkan_freedreno.so meta.json

    if ! [ -f "$workdir/$output_filename" ]; then
        echo -e "$red Packaging failed for $description_name! $nocolor" && exit 1
    else
        echo -e "$green Package ready: $workdir/$output_filename $nocolor"
    fi

    rm -rf "$package_temp_dir"
    cd "$workdir"
    echo -e "${green}--- Finished Packaging: $description_name ---${nocolor}\n"
}

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

generate_release_info() {
    echo -e "${green}Generating release info files...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
    local main_commit_short=$(git -C mesa_main rev-parse --short HEAD)

    echo "Mesa-${date_tag}-${main_commit_short}" > tag
    echo "Turnip CI Build - Android 15 - ${date_tag}" > release

    echo "Automated Turnip CI build." > description
    echo "" >> description
    echo "### Included Drivers:" >> description
    echo "" >> description
    echo "**1. Latest Mesa Main (turnip_<date>_${main_commit_short}.zip):**" >> description
    echo "   - Standard Turnip driver built from the latest Mesa main branch." >> description
    echo "   - Version: \`$version_main\`" >> description
    echo "   - Commit: [${main_commit_short}](${mesa_repo_main%.git}/-/commit/${commit_main})" >> description
    echo -e "${green}Release info generated.${nocolor}"
}

check_deps
mkdir -p "$workdir"
prepare_ndk

build_mesa_main
generate_release_info

echo -e "${green}All builds for Android 15 completed successfully!${nocolor}"
