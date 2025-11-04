#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
sdkver="35"
mesa_repo="https://gitlab.freedesktop.org/mesa/mesa.git"

# 🔁 commits base
good_commit="47619ef5"   # estável
target_branch="main"     # última versão da Mesa

check_deps(){
    echo "🔍 Checking system dependencies ..."
    for dep in $deps; do
        if ! command -v $dep >/dev/null 2>&1; then
            echo -e "$red Missing dependency: $dep$nocolor"
            missing=1
        else
            echo -e "$green Found: $dep$nocolor"
        fi
    done
    if [ "$missing" == "1" ]; then
        echo "Please install missing dependencies." && exit 1
    fi
    pip install mako &> /dev/null || true
}

prepare_ndk(){
    echo "📦 Preparing Android NDK ..."
    cd "$workdir"
    if [ -z "${ANDROID_NDK_LATEST_HOME}" ]; then
        if [ ! -d "$ndkver" ]; then
            echo "Downloading Android NDK ..."
            curl -L "https://dl.google.com/android/repository/${ndkver}-linux.zip" --output "${ndkver}-linux.zip" &> /dev/null
            echo "Extracting NDK ..."
            unzip "${ndkver}-linux.zip" &> /dev/null
        fi
    else
        echo "Using preinstalled Android NDK from GitHub Actions image."
    fi
}

prepare_source(){
    echo "🌿 Cloning Mesa latest and reverting changes after $good_commit ..."
    cd "$workdir"
    rm -rf mesa
    git clone --depth=1 "$mesa_repo" mesa
    cd mesa

    # Busca o histórico completo para o revert funcionar
    git fetch origin --unshallow || true
    git fetch origin --tags
    git checkout "$target_branch"

    git config user.name "mesa-ci"
    git config user.email "mesa-ci@users.noreply.github.com"

    echo "🔄 Reverting commits introduced after $good_commit ..."
    git revert --no-edit "$good_commit"..HEAD || true

    commit_hash=$(git rev-parse HEAD)
    version_str=$(cat VERSION | xargs)
    cd "$workdir"
}

compile_mesa(){
    echo -e "${green}⚙️ Compiling Mesa (Turnip)...${nocolor}"

    local source_dir="$workdir/mesa"
    local build_dir="$source_dir/build"

    local ndk_root_path
    if [ -z "${ANDROID_NDK_LATEST_HOME}" ]; then
        ndk_root_path="$workdir/$ndkver"
    else
        ndk_root_path="$ANDROID_NDK_LATEST_HOME"
    fi

    local ndk_bin_path="$ndk_root_path/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local ndk_sysroot_path="$ndk_root_path/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

    local cross_file="$source_dir/android-aarch64-crossfile.txt"
    cat <<EOF > "$cross_file"
[binaries]
ar = '$ndk_bin_path/llvm-ar'
c = ['ccache', '$ndk_bin_path/aarch64-linux-android$sdkver-clang', '--sysroot=$ndk_sysroot_path']
cpp = ['ccache', '$ndk_bin_path/aarch64-linux-android$sdkver-clang++', '--sysroot=$ndk_sysroot_path', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$ndk_bin_path/aarch64-linux-android-strip'
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

    cd "$source_dir"
    meson setup "$build_dir" --cross-file "$cross_file" \
        -Dbuildtype=release \
        -Dplatforms=android \
        -Dplatform-sdk-version=$sdkver \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dfreedreno-kmds=kgsl \
        -Degl=disabled \
        -Dglx=disabled \
        -Dshared-glapi=enabled \
        -Db_lto=true \
        -Dvulkan-beta=true \
        2>&1 | tee "$workdir/meson_log"

    ninja -C "$build_dir" 2>&1 | tee "$workdir/ninja_log"
}

package_driver(){
    local source_dir="$workdir/mesa"
    local build_dir="$source_dir/build"
    local lib_path="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"
    local package_temp="$workdir/package_temp"

    if [ ! -f "$lib_path" ]; then
        echo -e "${red}Build failed: libvulkan_freedreno.so not found.${nocolor}"
        exit 1
    fi

    mkdir -p "$package_temp"
    cp "$lib_path" "$package_temp/lib_temp.so"

    cd "$package_temp"
    patchelf --set-soname "vulkan.adreno.so" lib_temp.so
    mv lib_temp.so "vulkan.ad07XX.so"

    local date_meta=$(date +'%b %d, %Y')
    local short_hash=${commit_hash:0:7}
    cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "Turnip (Revert HEAD) - $date_meta - $short_hash",
  "description": "Turnip built from HEAD with reverts after $good_commit to fix Unreal freezes.",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF

    local zip_name="turnip_revert_$(date +'%Y%m%d')_${short_hash}.zip"
    zip -9 "$workdir/$zip_name" "vulkan.ad07XX.so" meta.json
    echo -e "${green}✅ Package ready: $workdir/$zip_name${nocolor}"
}

generate_release_info(){
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
    local short_hash=${commit_hash:0:7}
    echo "Turnip-Revert-${date_tag}-${short_hash}" > tag
    echo "Turnip Revert Build - ${date_tag}" > release
    echo "Build reverting Mesa commits after ${good_commit} to avoid Unreal freezes." > description
}

clear
check_deps
mkdir -p "$workdir"
prepare_ndk
prepare_source
compile_mesa
package_driver
generate_release_info
echo -e "${green}🎉 Build completed successfully!${nocolor}"
