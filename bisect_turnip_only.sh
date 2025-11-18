#!/bin/bash -e

GOOD_COMMIT="47619ef5389c44cb92066c20409e6a9617d685fb"
BAD_COMMIT="93f24f0bd02916d9ce4cc452312c19e9cca5d299"

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
sdkver="35"
mesa_repo="https://gitlab.freedesktop.org/mesa/mesa.git"

deps="meson ninja patchelf unzip curl pip flex bison zip git ccache"

echo "🔍 Checking dependencies..."
for d in $deps; do
    if ! command -v $d >/dev/null 2>&1; then
        echo -e "$red Missing: $d$nocolor"
        exit 1
    fi
done

mkdir -p "$workdir"
cd "$workdir"

echo "🌿 Cloning Mesa..."
rm -rf mesa
git clone "$mesa_repo" mesa
cd mesa

echo "📌 Getting Turnip-only commit list..."
commit_list=$(git log --oneline --reverse $GOOD_COMMIT..$BAD_COMMIT -- src/freedreno | awk '{print $1}')

echo "📝 Found commits touching Turnip:"
echo "$commit_list"
echo

for commit in $commit_list; do
    echo -e "$green============================================$nocolor"
    echo -e "🔄 Testing commit: $commit"
    echo -e "$green============================================$nocolor"

    git reset --hard
    git checkout "$commit"

    commit_hash=$(git rev-parse HEAD)
    version_str=$(cat VERSION | xargs 2>/dev/null || echo "unknown")

    echo "📦 Preparing NDK..."
    cd "$workdir"
    if [ ! -d "$ndkver" ]; then
        curl -L "https://dl.google.com/android/repository/${ndkver}-linux.zip" -o ndk.zip
        unzip ndk.zip >/dev/null
    fi

    ndk="$workdir/$ndkver"
    bin="$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin"
    sys="$ndk/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

    echo "⚙️ Building Mesa Turnip..."
    src="$workdir/mesa"
    build="$src/build"
    rm -rf "$build"

    cross="$src/android-aarch64-crossfile.txt"
    cat <<EOF > "$cross"
[binaries]
c = ['ccache', '$bin/aarch64-linux-android${sdkver}-clang', '--sysroot=$sys']
cpp = ['ccache', '$bin/aarch64-linux-android${sdkver}-clang++', '--sysroot=$sys']
ar = '$bin/llvm-ar'
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$bin/aarch64-linux-android-strip'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

    cd "$src"
    meson setup "$build" \
        --cross-file "$cross" \
        -Dbuildtype=release \
        -Dplatforms=android \
        -Dandroid-stub=true \
        -Dplatform-sdk-version=$sdkver \
        -Dgallium-drivers= \
        -Dfreedreno-kmds=kgsl \
        -Dshared-glapi=enabled \
        -Dvulkan-beta=true \
        -Dvulkan-drivers=freedreno \
        -Db_lto=true \
        -Ddefault_library=shared

    ninja -C "$build"

    lib="$build/src/freedreno/vulkan/libvulkan_freedreno.so"

    if [ ! -f "$lib" ]; then
        echo -e "$red ❌ Build failed for $commit $nocolor"
        continue
    fi

    echo "📦 Packaging driver..."

    pkg="$workdir/pkg_$commit"
    rm -rf "$pkg"
    mkdir "$pkg"

    cp "$lib" "$pkg/lib_temp.so"
    cd "$pkg"
    patchelf --set-soname "vulkan.adreno.so" lib_temp.so
    mv lib_temp.so vulkan.ad07XX.so

    cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "Turnip-Bisect-$commit",
  "description": "Turnip built from Mesa commit $commit",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF

    zip_name="turnip_bisect_${commit}.zip"
    zip -9 "$workdir/$zip_name" vulkan.ad07XX.so meta.json

    echo -e "$green✅ Built & packaged: $zip_name$nocolor"
done

echo -e "$green🎉 Bisect finished!$nocolor"
