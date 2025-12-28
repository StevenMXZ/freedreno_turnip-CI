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
    echo "Preparing Mesa source..."
    cd "$workdir"
    rm -rf mesa
    
    # 1. Clona Mesa Main
    git clone "$mesa_repo" mesa
    cd mesa

    git config user.name "CI Builder"
    git config user.email "ci@builder.com"

    # 2. MERGE MR 37802 (Autotuner Overhaul)
    echo -e "${green}Merging MR 37802 (Autotuner Overhaul)...${nocolor}"
    git fetch origin refs/merge-requests/37802/head
    git merge --no-edit FETCH_HEAD || {
        echo -e "${red}Failed to merge MR 37802. Conflicts likely.${nocolor}"
        exit 1
    }

    # 3. PATCH: REMOVER SUPORTE A BGRA (Revert BGRA - Fix Unity)
    echo -e "${green}Applying Patch: Removing BGRA support from vk_android.c...${nocolor}"
    local vk_android="src/vulkan/runtime/vk_android.c"
    if [ -f "$vk_android" ]; then
        sed -i '/case AHARDWAREBUFFER_FORMAT_B8G8R8A8_UNORM:/,+1d' "$vk_android"
        sed -i '/case VK_FORMAT_B8G8R8A8_UNORM:/,+1d' "$vk_android"
    else
        echo -e "${red}Critical: vk_android.c not found!${nocolor}"
        exit 1
    fi

    # 4. PATCH: FIX A6XX (Stability / No Cache)
    echo -e "${green}Applying A6xx Stability Fix (Nuclear)...${nocolor}"
    
    # Remove cache de queries
    if [ -f src/freedreno/vulkan/tu_query.cc ]; then
        sed -i 's/tu_bo_init_new_cached/tu_bo_init_new/g' src/freedreno/vulkan/tu_query.cc
    fi
    if [ -f src/freedreno/vulkan/tu_query_pool.cc ]; then
        sed -i 's/tu_bo_init_new_cached/tu_bo_init_new/g' src/freedreno/vulkan/tu_query_pool.cc
    fi
    
    # Força has_cached_coherent_memory = false
    if [ -f src/freedreno/vulkan/tu_device.cc ]; then
        sed -i 's/physical_device->has_cached_coherent_memory = .*/physical_device->has_cached_coherent_memory = false;/' src/freedreno/vulkan/tu_device.cc || true
    fi
    
    # Remove a flag CACHED_BIT de todo o código vulkan
    grep -rl "VK_MEMORY_PROPERTY_HOST_CACHED_BIT" src/freedreno/vulkan/ | while read -r file; do
        sed -i 's/dev->physical_device->has_cached_coherent_memory ? VK_MEMORY_PROPERTY_HOST_CACHED_BIT : 0/0/g' "$file" || true
        sed -i 's/VK_MEMORY_PROPERTY_HOST_CACHED_BIT/0/g' "$file" || true
    done

    commit_hash="$(git rev-parse HEAD)"
    if [ -f VERSION ]; then
        version_str="$(cat VERSION | xargs)"
    else
        version_str="unknown"
    fi
}

compile_mesa() {
    echo -e "${green}Compiling Mesa...${nocolor}"
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
cpp = ['ccache', '$ndk_bin/aarch64-linux-android$sdkver-clang++', '--sysroot=$ndk_sysroot', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables']
strip = '$ndk_bin/aarch64-linux-android-strip'
ld = '$ndk_bin/ld.lld'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8-a'
endian = 'little'
EOF

    export LIBRT_LIBS=""
    export CFLAGS="-D__ANDROID__"
    export CXXFLAGS="-D__ANDROID__"

    meson setup "$build_dir" "$source_dir" \
        --cross-file "$cross_file" \
        -Dbuildtype=release \
        -Dplatforms=android \
        -Dplatform-sdk-version="$sdkver" \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dfreedreno-kmds=kgsl \
        -Degl=disabled \
        -Dglx=disabled \
        -Dshared-glapi=enabled \
        -Dvulkan-beta=false \
        -Db_lto=true \
        -Ddefault_library=shared \
        2>&1 | tee "$workdir/meson_log"

    ninja -C "$build_dir" 2>&1 | tee "$workdir/ninja_log"
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        echo -e "${red}Mesa build failed.${nocolor}"
        exit 1
    fi
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
    
    # Importante: Definir o Soname corretamente para vulkan.adreno.so
    # Isso ajuda o driver a ser carregado corretamente e evitar o fallback para 1.3.121
    patchelf --set-soname "vulkan.adreno.so" lib_temp.so
    mv lib_temp.so vulkan.ad07XX.so
    
    local short_hash="${commit_hash:0:7}"

    cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "Turnip-SuperFix-${short_hash}",
  "description": "Main + MR37802 + NoBGRA + A6xxFix. SDK 35.",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF
    zip -9 "$workdir/Turnip-SuperFix-${short_hash}.zip" vulkan.ad07XX.so meta.json
    echo -e "${green}Package ready: Turnip-SuperFix-${short_hash}.zip${nocolor}"
}

generate_release_info() {
    cd "$workdir"
    local date_tag="$(date +'%Y%m%d')"
    local short_hash="${commit_hash:0:7}"
    echo "Turnip-SuperFix-${date_tag}-${short_hash}" > tag
    echo "Turnip CI Build (${date_tag})" > release
    cat <<EOF > description
Automated Turnip CI build

**Base:** Mesa Main
**Merge:** MR !37802 (Autotuner Overhaul)
**Fix 1:** Revert BGRA Support (vk_android.c)
**Fix 2:** A6xx Stability (No Cache)

Commit: ${commit_hash}
EOF
}

check_deps
prepare_ndk
prepare_source
compile_mesa
package_driver
generate_release_info
echo -e "${green}Done.${nocolor}"
