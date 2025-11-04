#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
sdkver="35"

mesa_repo="https://gitlab.freedesktop.org/mesa/mesa.git"

# commits
target_commit="93f24f0b"
revert_commits=("fde529a55e3" "5bd6fd5c105" "e31b1b649c4")

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
  fi
}

prepare_source(){
  echo "🌿 Cloning Mesa and checking out $target_commit ..."
  cd "$workdir"
  rm -rf mesa || true
  git clone "$mesa_repo" mesa
  cd mesa
  git checkout "$target_commit"

  echo "🔄 Reverting suspected commits..."
  for c in "${revert_commits[@]}"; do
    git revert --no-edit "$c" || echo "⚠️ Could not revert $c (might already be gone)"
  done

  commit_hash=$(git rev-parse HEAD)
  version_str=$(cat VERSION | xargs)
}

compile_mesa(){
  echo -e "${green}⚙️ Compiling Mesa...${nocolor}"

  local source_dir="$workdir/mesa"
  local build_dir="$source_dir/build"

  local ndk_root_path="${ANDROID_NDK_LATEST_HOME:-$workdir/$ndkver}"
  local ndk_bin_path="$ndk_root_path/toolchains/llvm/prebuilt/linux-x86_64/bin"
  local ndk_sysroot_path="$ndk_root_path/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

  local cross_file="$source_dir/android-aarch64-crossfile.txt"
  cat <<EOF > "$cross_file"
[binaries]
ar = '$ndk_bin_path/llvm-ar'
c = ['ccache', '$ndk_bin_path/aarch64-linux-android$sdkver-clang', '--sysroot=$ndk_sysroot_path']
cpp = ['ccache', '$ndk_bin_path/aarch64-linux-android$sdkver-clang++', '--sysroot=$ndk_sysroot_path', '-fno-exceptions']
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
    -Dvulkan-drivers=freedreno \
    -Dfreedreno-kmds=kgsl \
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
  "name": "Turnip (Revert Test) - $date_meta - $short_hash",
  "description": "Built from Mesa commit $target_commit with reverts of suspected barrier commits.",
  "author": "mesa-ci",
  "libraryName": "vulkan.ad07XX.so"
}
EOF

  local zip_name="turnip_revert_${short_hash}.zip"
  zip -9 "$workdir/$zip_name" "vulkan.ad07XX.so" meta.json
  echo -e "${green}✅ Package ready: $workdir/$zip_name${nocolor}"
}

# === Execução ===
check_deps
mkdir -p "$workdir"
prepare_ndk
prepare_source
compile_mesa
package_driver
