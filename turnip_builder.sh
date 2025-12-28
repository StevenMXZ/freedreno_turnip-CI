#!/bin/bash
set -euo pipefail

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="meson ninja patchelf unzip curl pip flex bison zip git ccache"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
sdkver="35"
mesa_repo="https://gitlab.freedesktop.org/mesa/mesa.git"

commit_hash=""

check_deps() {
    echo "Checking system dependencies ..."
    local missing=0
    for dep in $deps; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo -e "${red}Missing dependency: $dep${nocolor}"
            missing=1
        else
            echo -e "${green}Found: $dep${nocolor}"
        fi
    done
    if [ "$missing" -eq 1 ]; then
        echo "Please install missing dependencies."
        exit 1
    fi
    pip install --user mako &>/dev/null || true
}

prepare_ndk() {
    echo "Preparing Android NDK ..."
    mkdir -p "$workdir"
    cd "$workdir"
    if [ -z "${ANDROID_NDK_LATEST_HOME:-}" ]; then
        if [ ! -d "$ndkver" ]; then
            echo "Downloading Android NDK..."
            curl -L "https://dl.google.com/android/repository/${ndkver}-linux.zip" -o "${ndkver}-linux.zip"
            unzip -q "${ndkver}-linux.zip"
        fi
        export ANDROID_NDK_HOME="$workdir/$ndkver"
    else
        export ANDROID_NDK_HOME="$ANDROID_NDK_LATEST_HOME"
    fi
}

prepare_source() {
    echo "Preparing Mesa source (Vanilla)..."
    cd "$workdir"
    rm -rf mesa
    
    # Clone Limpo
    git clone --depth=1 "$mesa_repo" mesa
    cd mesa

    commit_hash="$(git rev-parse HEAD)"
}

generate_crossfile() {
    echo "Generating Crossfile..."
    local ndk_bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local ndk_sysroot="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    local cross_file="$workdir/mesa/android-aarch64"

    cat <<EOF > "$cross_file"
[binaries]
ar = '$ndk_bin/llvm-ar'
c = ['ccache', '$ndk_bin/aarch64-linux-android$sdkver-clang', '--sysroot=$ndk_sysroot']
cpp = ['ccache', '$ndk_bin/aarch64-linux-android$sdkver-clang++', '--sysroot=$ndk_sysroot', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++']
strip = '$ndk_bin/aarch64-linux-android-strip'
pkgconfig = '/usr/bin/pkg-config'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8-a'
endian = 'little'
EOF
}

compile_mesa() {
    echo -e "${green}Compiling Mesa (Custom Command + Fixes)...${nocolor}"
    cd "$workdir/mesa"
    rm -rf build-android-aarch64

    # CORREÇÃO: Adicionado -Dvalgrind=disabled e mantido os fixes do libarchive
    meson setup build-android-aarch64 \
        --cross-file "$workdir/mesa/android-aarch64" \
        -Dplatforms=android \
        -Dplatform-sdk-version=$sdkver \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dvulkan-beta=true \
        -Dfreedreno-kmds=kgsl \
        -Db_lto=true \
        -Dstrip=true \
        -Degl=disabled \
        -Dvalgrind=disabled \
        -Dlibarchive:openssl=disabled \
        -Dlibarchive:nettle=disabled \
        -Dlibarchive:expat=disabled \
        -Dlibarchive:iconv=disabled \
        -Dlibarchive:xattr=false \
        -Dlibarchive:acl=false \
        2>&1 | tee "$workdir/meson_log"

    ninja -C build-android-aarch64 2>&1 | tee "$workdir/ninja_log"
    
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        echo -e "${red}Mesa build failed.${nocolor}"
        exit 1
    fi
}

package_driver() {
    echo "Packaging driver..."
    local build_dir="$workdir/mesa/build-android-aarch64"
    local lib_path="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"
    local pkg="$workdir/package_temp"

    if [ ! -f "$lib_path" ]; then
        echo -e "${red}libvulkan_freedreno.so not found.${nocolor}"
        exit 1
    fi

    rm -rf "$pkg"
    mkdir -p "$pkg"
    
    # Renomeando e ajustando Soname
    cp "$lib_path" "$pkg/vulkan.ad07xx.so"
    cd "$pkg"
    patchelf --set-soname "vulkan.ad07xx.so" vulkan.ad07xx.so
    
    local short_hash="${commit_hash:0:7}"

    # SEU JSON EXATO
    cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "Mesa Turnip Driver v26.0.0 Revision",
  "description": "Compiled from source.",
  "author": "me",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan 1.4.335",
  "minApi": 27,
  "libraryName": "vulkan.ad07xx.so"
}
EOF
    zip -9 "$workdir/Turnip-CustomJSON-${short_hash}.zip" vulkan.ad07xx.so meta.json
    echo -e "${green}Package ready: Turnip-CustomJSON-${short_hash}.zip${nocolor}"
}

check_deps
prepare_ndk
prepare_source
generate_crossfile
compile_mesa
package_driver
echo -e "${green}Done.${nocolor}"
