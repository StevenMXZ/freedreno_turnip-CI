#!/bin/bash -e
set -o pipefail

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"

# --- CONFIGURAÇÃO ---
ndkver="android-ndk-r28"
target_sdk="36"

# REPOSITÓRIOS
base_repo="https://gitlab.freedesktop.org/robclark/mesa.git"
base_branch="tu/gen8"

hacks_repo="https://github.com/whitebelyash/mesa-tu8.git"
hacks_branch="gen8-hacks"

# Commit que quebra o DXVK (Vamos reverter ele)
bad_commit="2f0ea1c6"

commit_hash=""
version_str=""

check_deps(){
	echo "Checking system dependencies ..."
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
	echo "Preparing NDK r28..."
	mkdir -p "$workdir"
	cd "$workdir"
	if [ ! -d "$ndkver" ]; then
		echo "Downloading Android NDK $ndkver..."
		curl -L "https://dl.google.com/android/repository/${ndkver}-linux.zip" --output "${ndkver}-linux.zip" &> /dev/null
		echo "Extracting NDK..."
		unzip -q "${ndkver}-linux.zip" &> /dev/null
	fi
    export ANDROID_NDK_HOME="$workdir/$ndkver"
}

prepare_source(){
	echo "Preparing Mesa source..."
	cd "$workdir"
	if [ -d mesa ]; then rm -rf mesa; fi
	
    # 1. Clona BASE (Rob Clark - Último Commit)
    echo "Cloning Base: $base_repo ($base_branch)..."
	git clone --branch "$base_branch" "$base_repo" mesa
	cd mesa

    git config user.email "ci@turnip.builder"
    git config user.name "Turnip CI Builder"

    # 2. Prepara os HACKS
    echo "Fetching Hacks from: $hacks_repo..."
    git remote add hacks "$hacks_repo"
    git fetch hacks "$hacks_branch"
    
    # 3. SMART MERGE (Resolve conflitos automaticamente)
    echo "Attempting Merge..."
    # Tenta o merge. Se falhar, entra no bloco || (OR) para resolver.
    if ! git merge --no-edit "hacks/$hacks_branch" --allow-unrelated-histories; then
        echo -e "${red}Merge Conflict detected! Resolving intelligently...${nocolor}"
        
        # Para cada arquivo em conflito, forçamos a versão do HACK (Theirs)
        # Isso garante que a definição do A830 e os hacks entrem, sobrescrevendo o Rob Clark apenas onde necessário.
        git checkout --theirs .
        git add .
        
        # Finaliza o merge com os arquivos corrigidos
        git commit -m "Auto-resolved conflicts by accepting Hacks"
        echo -e "${green}Conflicts resolved. Hacks applied successfully.${nocolor}"
    fi

    # 4. REVERT DO COMMIT QUE MATA O DXVK
    echo -e "${green}Attempting to REVERT commit $bad_commit (Enable GS/Tess)...${nocolor}"
    
    if git revert --no-edit "$bad_commit"; then
        echo -e "${green}SUCCESS: Reverted GS/Tess disable! DXVK should work.${nocolor}"
    else
        echo -e "${red}Git revert failed (hash changed?). Trying manual SED patch...${nocolor}"
        git revert --abort || true
        # Se o revert falhar, usamos SED para apagar a verificação "&& chip != 8"
        # Isso reativa Geometry e Tessellation no código fonte na força bruta
        find src/freedreno/vulkan -name "*.cc" -print0 | xargs -0 sed -i 's/ && (pdevice->info->chip != 8)//g'
        find src/freedreno/vulkan -name "*.cc" -print0 | xargs -0 sed -i 's/ && (pdevice->info->chip == 8)//g'
        echo "Applied manual patch via SED to enable GS/Tess."
    fi

    # --- SPIRV Manual ---
    echo "Manually cloning dependencies..."
    mkdir -p subprojects
    cd subprojects
    rm -rf spirv-tools spirv-headers
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Headers.git spirv-headers
    cd .. 
    
	commit_hash=$(git rev-parse HEAD)
	version_str="API36-RobClark-Latest"
	cd "$workdir"
}

compile_mesa(){
	echo -e "${green}Compiling Mesa for SDK $target_sdk...${nocolor}"

	local source_dir="$workdir/mesa"
	local build_dir="$source_dir/build"
	local ndk_bin_path="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
	local ndk_sysroot_path="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

    # Fallback compilador (35 se 36 não existir)
    local compiler_ver="35"
    if [ ! -f "$ndk_bin_path/aarch64-linux-android${compiler_ver}-clang" ]; then compiler_ver="34"; fi
    echo "Using compiler binary: $compiler_ver (Targeting API $target_sdk)"

	local cross_file="$source_dir/android-aarch64-crossfile.txt"
	cat <<EOF > "$cross_file"
[binaries]
ar = '$ndk_bin_path/llvm-ar'
c = ['ccache', '$ndk_bin_path/aarch64-linux-android${compiler_ver}-clang', '--sysroot=$ndk_sysroot_path']
cpp = ['ccache', '$ndk_bin_path/aarch64-linux-android${compiler_ver}-clang++', '--sysroot=$ndk_sysroot_path', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
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
	export CFLAGS="-D__ANDROID__"
	export CXXFLAGS="-D__ANDROID__"

    # Opções limpas e SPIRV forçado
	meson setup "$build_dir" --cross-file "$cross_file" \
		-Dbuildtype=release \
		-Dplatforms=android \
		-Dplatform-sdk-version=$target_sdk \
		-Dandroid-stub=true \
		-Dgallium-drivers= \
		-Dvulkan-drivers=freedreno \
		-Dfreedreno-kmds=kgsl \
		-Degl=disabled \
		-Dglx=disabled \
		-Db_lto=true \
		-Dvulkan-beta=true \
		-Ddefault_library=shared \
        -Dzstd=disabled \
        --force-fallback-for=spirv-tools,spirv-headers \
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

	rm -rf "$package_temp"
	mkdir -p "$package_temp"
	cp "$lib_path" "$package_temp/lib_temp.so"

	cd "$package_temp"
	patchelf --set-soname "vulkan.adreno.so" lib_temp.so
	mv lib_temp.so "vulkan.ad07XX.so"

	local short_hash=${commit_hash:0:7}
	local meta_name="Turnip-A830-DXVK-${short_hash}"
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "Turnip Gen8 (Bleeding Edge + DXVK Fix) - SDK 36. Commit $short_hash",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF

	local zip_name="Turnip-A830-DXVK-${short_hash}.zip"
	zip -9 "$workdir/$zip_name" "vulkan.ad07XX.so" meta.json
	echo -e "${green}Package ready: $workdir/$zip_name${nocolor}"
}

generate_release_info() {
    echo -e "${green}Generating release info...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
	local short_hash=${commit_hash:0:7}

    echo "Turnip-DXVK-${date_tag}-${short_hash}" > tag
    echo "Turnip A830 (DXVK Fix) - ${date_tag}" > release
    echo "Automated Turnip Build. Features: SDK 36, Smart Merge (RobClark Latest), Reverted GS/Tess Disable." > description
}

check_deps
prepare_ndk
prepare_source
compile_mesa
package_driver
generate_release_info
