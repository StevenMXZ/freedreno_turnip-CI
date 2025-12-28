#!/bin/bash
set -euo pipefail

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# Dependências (ccache é opcional, mas recomendado)
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
    
    # Clona o Mesa Main
    git clone --depth=1 "$mesa_repo" mesa
    cd mesa

    # ========================================================
    # PATCH: REMOVER SUPORTE A BGRA (Revert BGRA)
    # ========================================================
    echo -e "${green}Applying Patch: Removing BGRA support from vk_android.c...${nocolor}"
    
    local target_file="src/vulkan/runtime/vk_android.c"

    if [ -f "$target_file" ]; then
        # 1. Remove o case AHARDWAREBUFFER_FORMAT_B8G8R8A8_UNORM e a linha seguinte (return)
        sed -i '/case AHARDWAREBUFFER_FORMAT_B8G8R8A8_UNORM:/,+1d' "$target_file"

        # 2. Remove o case VK_FORMAT_B8G8R8A8_UNORM e a linha seguinte (return)
        sed -i '/case VK_FORMAT_B8G8R8A8_UNORM:/,+1d' "$target_file"
        
        # Verificação simples
        if grep -q "B8G8R8A8" "$target_file"; then
            echo -e "${red}AVISO: O patch pode ter falhado, ainda encontrei referências a B8G8R8A8.${nocolor}"
        else
            echo -e "${green}Patch aplicado com sucesso! BGRA removido.${nocolor}"
        fi
    else
        echo -e "${red}ERRO: Arquivo $target_file não encontrado! O layout do Mesa mudou?${nocolor}"
        exit 1
    fi
    # ========================================================

    commit_hash="$(git rev-parse HEAD)"
    if [ -f VERSION ]; then
        version_str="$(cat VERSION | xargs)"
    else
        version_str="unknown"
    fi
}

compile_mesa() {
    echo -e "${green}Compiling Mesa (Main - No BGRA)...${nocolor}"
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
        -Dvulkan-beta=true \
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
    patchelf --set-soname "vulkan.adreno.so" lib_temp.so
    mv lib_temp.so vulkan.ad07XX.so
    local short_hash="${commit_hash:0:7}"

    cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "Turnip-Main-NoBGRA-${short_hash}",
  "description": "Mesa Main with BGRA support forcefully reverted in vk_android.c",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF
    zip -9 "$workdir/Turnip-Main-NoBGRA-${short_hash}.zip" vulkan.ad07XX.so meta.json
    echo -e "${green}Package ready.${nocolor}"
}

generate_release_info() {
    cd "$workdir"
    local date_tag="$(date +'%Y%m%d')"
    local short_hash="${commit_hash:0:7}"
    echo "Turnip-NoBGRA-${date_tag}-${short_hash}" > tag
    echo "Turnip CI Build (${date_tag})" > release
    cat <<EOF > description
Automated Turnip CI build

**Base:** Mesa Main
**Patch:** Removed AHARDWAREBUFFER_FORMAT_B8G8R8A8_UNORM from vk_android.c
**SDK:** 35

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
