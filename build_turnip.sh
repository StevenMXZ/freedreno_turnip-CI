#!/bin/bash -e
set -o pipefail

deps="ninja patchelf unzip curl pip flex bison zip git perl glslangValidator python3"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"

check_deps(){
	for dep in $deps; do
		if ! command -v $dep >/dev/null 2>&1; then exit 1; fi
	done
	pip install meson mako --break-system-packages &> /dev/null || true
}

prepare_ndk(){
	mkdir -p "$workdir" && cd "$workdir"
	if [ ! -d "$ndkver" ]; then
		curl -sL "https://dl.google.com/android/repository/${ndkver}-linux.zip" --output "${ndkver}-linux.zip" &> /dev/null
		unzip -q "${ndkver}-linux.zip" &> /dev/null
	fi
    export ANDROID_NDK_HOME="$workdir/$ndkver"
}

compile_mesa() {
    local repo_url="https://github.com/whitebelyash/mesa-tu8.git"
    local branch="gen8"
    local output_name="A8XX-MR37802"
    local mesa_dir="$workdir/mesa"
    local build_dir="$mesa_dir/build"

    cd "$workdir"
    rm -rf "$mesa_dir"
    git clone --depth 100 -b "$branch" "$repo_url" "$mesa_dir"
    cd "$mesa_dir"
    
    sed -i 's/ - tu8//g' src/freedreno/vulkan/tu_device.cc || true
    sed -i 's/ TUGEN8_DRV_VERSION//g' src/freedreno/vulkan/tu_device.cc || true

    local githash=$(git rev-parse --short HEAD)

    curl -sL "https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/37802.patch" -o 37802.patch
    patch -p1 --fuzz=4 < 37802.patch || true
    
    sed -i 's/typedef const native_handle_t\* buffer_handle_t;/typedef void\* buffer_handle_t;/g' include/android_stub/cutils/native_handle.h || true
    sed -i 's/, hnd->handle/, (void \*)hnd->handle/g' src/util/u_gralloc/u_gralloc_fallback.c || true
    sed -i 's/native_buffer->handle->/((const native_handle_t \*)native_buffer->handle)->/g' src/vulkan/runtime/vk_android.c || true

    mkdir -p subprojects && cd subprojects
    rm -rf spirv-tools spirv-headers
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Headers.git spirv-headers
    cd ..

    local ndk_bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local ndk_sys="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    local cver="35"
    [ ! -f "$ndk_bin/aarch64-linux-android${cver}-clang" ] && cver="34"

    cat <<EOF > android-cross.txt
[binaries]
ar = '$ndk_bin/llvm-ar'
c = ['ccache', '$ndk_bin/aarch64-linux-android${cver}-clang', '--sysroot=$ndk_sys']
cpp = ['ccache', '$ndk_bin/aarch64-linux-android${cver}-clang++', '--sysroot=$ndk_sys']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$ndk_bin/aarch64-linux-android-strip'
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
[built-in options]
c_link_args = ['-static-libstdc++']
cpp_link_args = ['-static-libstdc++']
EOF
    
    export CFLAGS="-D__ANDROID__ -Wno-error -Wno-deprecated-declarations -Wno-incompatible-pointer-types-discards-qualifiers -Wno-incompatible-pointer-types"
    export CXXFLAGS="-D__ANDROID__ -Wno-error -Wno-deprecated-declarations -Wno-incompatible-pointer-types-discards-qualifiers -Wno-incompatible-pointer-types"

    meson setup "$build_dir" --cross-file android-cross.txt \
        -Dbuildtype=release \
        -Dplatforms=android \
        -Dplatform-sdk-version=36 \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dfreedreno-kmds=kgsl \
        -Degl=disabled \
        -Dglx=disabled \
        -Dvulkan-beta=true \
        -Ddefault_library=shared \
        -Dzstd=disabled \
        -Dwerror=false \
        --force-fallback-for=spirv-tools,spirv-headers
    
    ninja -C "$build_dir"

    local lib="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"
    if [ ! -f "$lib" ]; then exit 1; fi
    
    local pkg_dir="$workdir/pkg_$output_name"
    mkdir -p "$pkg_dir"
    cp "$lib" "$pkg_dir/libvulkan_freedreno.so"
    cd "$pkg_dir"
    
    cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "Turnip A8XX MR37802",
  "description": "A8XX Branch + MR37802 (git $githash)",
  "author": "StevenMXZ",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan 1.4.347",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF
    
    ZIP_NAME="Turnip_${output_name}_v${BUILD_VERSION}.zip"
    zip -9 "/tmp/$ZIP_NAME" libvulkan_freedreno.so meta.json
    
    if ! [ -f "/tmp/$ZIP_NAME" ]; then
        echo "Failed to pack the archive!"
    else
        cp "/tmp/$ZIP_NAME" "$workdir/"
        echo "Build completed successfully! Copied $ZIP_NAME"
    fi
}

check_deps
prepare_ndk
compile_mesa
