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
version_str=""

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
            curl -L "https://dl.google.com/android/repository/${ndkver}-linux.zip" -o "${ndkver}-linux.zip"
            unzip -q "${ndkver}-linux.zip"
        fi
        export ANDROID_NDK_HOME="$workdir/$ndkver"
    else
        export ANDROID_NDK_HOME="$ANDROID_NDK_LATEST_HOME"
    fi
}

prepare_source() {
    echo "Preparing Mesa source..."
    cd "$workdir"
    rm -rf mesa
    git clone --depth=1 "$mesa_repo" mesa
    cd mesa

    commit_hash="$(git rev-parse HEAD)"
    if [ -f VERSION ]; then
        version_str="$(cat VERSION | xargs)"
    else
        version_str="unknown"
    fi

    echo "Applying A6xx safety + exposure patches..."

    # ---- A6xx stability (disable cached coherent memory) ----
    sed -i 's/has_cached_coherent_memory = true/has_cached_coherent_memory = false/' \
        src/freedreno/vulkan/tu_device.cc || true

    grep -rl "HOST_CACHED_BIT" src/freedreno/vulkan/ | while read -r f; do
        sed -i 's/VK_MEMORY_PROPERTY_HOST_CACHED_BIT/0/g' "$f" || true
    done

    # ---- Expose maintenance7 / maintenance8 ----
    sed -i '
        s/KHR_maintenance7 = false/KHR_maintenance7 = true/
        s/KHR_maintenance8 = false/KHR_maintenance8 = true/
    ' src/freedreno/vulkan/tu_device.cc || true
}

compile_mesa() {
    echo -e "${green}Compiling Mesa (desktop-style)...${nocolor}"

    local source_dir="$workdir/mesa"
    local build_dir="$source_dir/build"
    rm -rf "$build_dir"

    local ndk_bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local ndk_sysroot="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    local cross_file="$source_dir/android-aarch64-crossfile.txt"

    cat <<EOF > "$cross_file"
[binaries]
ar = '$ndk_bin/llvm-ar'
c = ['ccache', '$ndk_bin/aarch64-linux-android$sdkver-clang', '--sysroot=$ndk_sysroot']
cpp = ['ccache', '$ndk_bin/aarch64-linux-android$sdkver-clang++', '--sysroot=$ndk_sysroot']
strip = '$ndk_bin/aarch64-linux-android-strip'
ld = '$ndk_bin/ld.lld'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'armv8-a'
endian = 'little'
EOF

    meson setup "$build_dir" "$source_dir" \
        --cross-file "$cross_file" \
        -Dbuildtype=release \
        -Dplatforms=auto \
        -Dandroid-stub=false \
        -Dvulkan-drivers=freedreno \
        -Dfreedreno-kmds=kgsl \
        -Dgallium-drivers= \
        -Degl=disabled \
        -Dglx=disabled \
        -Dvulkan-beta=true \
        -Db_lto=true \
        -Ddefault_library=shared \
        2>&1 | tee "$workdir/meson_log"

    ninja -C "$build_dir" 2>&1 | tee "$workdir/ninja_log"
}

package_driver() {
    echo "Packaging driver..."
    local build_dir="$workdir/mesa/build"
    local lib_path="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"
    local pkg="$workdir/package_temp"

    if [ ! -f "$lib_path" ]; then
        echo -e "${red}libvulkan_freedreno.so not found.${nocolor}"
        exit 1
    fi

    rm -rf "$pkg"
    mkdir -p "$pkg"
    cp "$lib_path" "$pkg/lib_temp.so"
    cd "$pkg"

    patchelf --set-soname "vulkan.adreno.so" lib_temp.so
    mv lib_temp.so vulkan.ad06XX.so

    local short_hash="${commit_hash:0:7}"

    cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "Turnip-A6xx-DesktopHack-${short_hash}",
  "description": "Mesa main + desktop-style exposure (A6xx)",
  "author": "custom",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad06XX.so"
}
EOF

    zip -9 "$workdir/Turnip-A6xx-DesktopHack-${short_hash}.zip" \
        vulkan.ad06XX.so meta.json
}

generate_release_info() {
    cd "$workdir"
    local date_tag
    date_tag="$(date +'%Y%m%d')"
    echo "Turnip-A6xx-DesktopHack-${date_tag}" > tag
}

check_deps
prepare_ndk
prepare_source
compile_mesa
package_driver
generate_release_info

echo -e "${green}Build finished successfully.${nocolor}"
