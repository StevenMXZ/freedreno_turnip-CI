#!/bin/bash
set -euo pipefail

# =========================
# Colors
# =========================
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# =========================
# Config
# =========================
deps="meson ninja patchelf unzip curl pip flex bison zip git ccache"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
sdkver="35"
mesa_repo="https://gitlab.freedesktop.org/mesa/mesa.git"

commit_hash=""
version_str=""

# =========================
# Dependency check
# =========================
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

# =========================
# NDK setup
# =========================
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

# =========================
# Mesa source
# =========================
prepare_source() {
    echo "Preparing Mesa source..."
    cd "$workdir"
    rm -rf mesa

    git clone "$mesa_repo" mesa
    cd mesa

    git config user.name "CI Builder"
    git config user.email "ci@builder.com"

    git fetch origin refs/merge-requests/35610/head
    git merge --no-edit FETCH_HEAD

    git fetch origin refs/merge-requests/38808/head
    git merge --no-edit FETCH_HEAD

    git fetch origin refs/merge-requests/35894/head
    git merge --no-edit FETCH_HEAD

    git fetch origin refs/merge-requests/37802/head
    git merge --no-edit FETCH_HEAD

    commit_hash="$(git rev-parse HEAD)"

    if [ -f VERSION ]; then
        version_str="$(cat VERSION | xargs)"
    else
        version_str="unknown"
    fi
}

# =========================
# Build Mesa
# =========================
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

# =========================
# Package Turnip
# =========================
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
  "name": "Turnip-CustomFeatures-${short_hash}",
  "description": "Mesa main + custom MRs",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF

    zip -9 "$workdir/Turnip-CustomFeatures-${short_hash}.zip" vulkan.ad07XX.so meta.json
    echo -e "${green}Package ready.${nocolor}"
}

# =========================
# Release info
# =========================
generate_release_info() {
    echo "Generating release metadata..."

    cd "$workdir"
    local date_tag
    date_tag="$(date +'%Y%m%d')"
    local short_hash="${commit_hash:0:7}"

    echo "Turnip-CustomFeatures-${date_tag}-${short_hash}" > tag
    echo "Turnip CI Build (${date_tag})" > release

    cat <<EOF > description
Automated Turnip CI build

Base: Mesa main
Included MRs:
- Autotuner overhaul
- VK_QCOM_multiview_per_view
- SteamDeck emulation
- Raw copy blits

Commit: ${commit_hash}
EOF
}

# =========================
# Run
# =========================
check_deps
prepare_ndk
prepare_source
compile_mesa
package_driver
generate_release_info

echo -e "${green}Done.${nocolor}"
