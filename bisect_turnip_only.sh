#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# ===========================
# Turnip Build Script (MAIN)
# ===========================

deps="meson ninja-build patchelf unzip curl python3-pip flex bison zip git ccache"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
sdkver="35"

mesa_repo="https://gitlab.freedesktop.org/mesa/mesa.git"

commit_hash=""
version_str=""

# ===========================
# Funções
# ===========================

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

    pip install mako --break-system-packages &>/dev/null || true
}

prepare_ndk(){
    echo "📦 Preparing Android NDK ..."
    mkdir -p "$workdir"
    cd "$workdir"

    if [ -z "${ANDROID_NDK_LATEST_HOME}" ]; then
        if [ ! -d "$ndkver" ]; then
            echo "Downloading Android NDK ..."
            curl -L "https://dl.google.com/android/repository/${ndkver}-linux.zip" --output "${ndkver}-linux.zip"
            echo "Extracting NDK ..."
            unzip "${ndkver}-linux.zip" &>/dev/null
        fi
    else
        echo "Using preinstalled Android NDK from GitHub Actions."
    fi
}

prepare_source(){
    echo "🌿 Preparing Mesa source..."
    cd "$workdir"
    rm -rf mesa

    git clone "$mesa_repo" mesa
    cd mesa

    commit_hash=$(git rev-parse HEAD)

    if [ -f VERSION ]; then
        version_str=$(cat VERSION | xargs)
    else
        version_str="unknown"
    fi

    cd "$workdir"
}

compile_mesa(){
    echo -e "${green}⚙️ Compiling Mesa...${nocolor}"

    local source_dir="$workdir/mesa"
    local build_dir="$source_dir/build"

    # limpo ANTES de gerar
    rm -rf "$build_dir"
    mkdir -p "$build_dir"

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

    export LIBRT_LIBS=""
    export CFLAGS="-D__ANDROID__"
    export CXXFLAGS="-D__ANDROID__"

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
        -Dgles1=disabled \
        -Dgles2=disabled \
        -Dopengl=false \
        -Dshared-glapi=disabled \
        -Db_lto=true \
        -Ddefault_library=shared \
        2>&1 | tee "$workdir/meson_log"

    if [ ! -f "$build_dir/build.ninja" ]; then
        echo -e "${red}meson setup failed — see $workdir/meson_log${nocolor}"
        exit 1
    fi

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

    rm -rf "$package_temp"
    mkdir -p "$package_temp"
    cp "$lib_path" "$package_temp/lib_temp.so"

    cd "$package_temp"
    patchelf --set-soname "vulkan.adreno.so" lib_temp.so
    mv lib_temp.so "vulkan.ad07XX.so"

    local short_hash=${commit_hash:0:7}
    cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "Turnip-${short_hash}",
  "description": "Turnip built from Mesa commit $commit_hash",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF

    local zip_name="turnip_${short_hash}.zip"
    zip -9 "$workdir/$zip_name" "vulkan.ad07XX.so" meta.json
    echo -e "${green}✅ Package ready: $workdir/$zip_name${nocolor}"
}

# ===========================
# Execução
# ===========================

clear
check_deps
prepare_ndk
prepare_source
compile_mesa
package_driver

echo -e "${green}🎉 Build completed successfully!${nocolor}"
