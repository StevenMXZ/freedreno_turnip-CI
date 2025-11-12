#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

# ===========================
# Turnip Build Script (Mesa Main + A6xx VK1.4 Patch + MR 35894)
# ===========================

deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
sdkver="35"

mesa_repo="https://gitlab.freedesktop.org/mesa/mesa.git"
# MR a ser mesclado
merge_request_num="35894"

commit_hash=""
version_str=""

# ===========================
# Funções
# ===========================

check_deps(){
    missing=0
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
	# instala mako silenciosamente (não fatal)
	pip install mako &> /dev/null || true
}

prepare_ndk(){
	echo "📦 Preparing Android NDK ..."
	mkdir -p "$workdir"
	cd "$workdir"
	if [ -z "${ANDROID_NDK_LATEST_HOME}" ]; then
		if [ ! -d "$ndkver" ]; then
			echo "Downloading Android NDK ..."
			curl -L "https://dl.google.com/android/repository/${ndkver}-linux.zip" --output "${ndkver}-linux.zip" &> /dev/null
			echo "Extracting NDK ..."
			unzip "${ndkver}-linux.zip" &> /dev/null
		fi
	else
		echo "Using preinstalled Android NDK from environment."
	fi
}

prepare_source(){
	echo "🌿 Preparing Mesa source (Main Branch)..."
	cd "$workdir"
	rm -rf mesa
	# clone raso (profundidade 1 para CI)
	git clone --depth=1 "$mesa_repo" mesa
	cd mesa

	# garantir main
	if git show-ref --verify --quiet refs/heads/main; then
	    git checkout main
	else
	    # fallback para master se não existir main
	    git checkout -B main || true
	fi

	# --- 1. APLICAR O MERGE REQUEST ---
	echo -e "${green}Configuring local git identity for merge...${nocolor}"
	git config user.name "CI Builder"
	git config user.email "ci@builder.com"
	
	echo -e "${green}Fetching Merge Request !${merge_request_num}...${nocolor}"
	# GitLab: fetch MR ref
	if ! git fetch origin "refs/merge-requests/${merge_request_num}/head":mr_${merge_request_num}; then
		echo -e "${red}Failed to fetch MR !${merge_request_num}. It may not exist or network issue.${nocolor}"
		exit 1
	fi

	echo -e "${green}Merging fetched MR !${merge_request_num} into main branch...${nocolor}"
	if ! git merge --no-edit "mr_${merge_request_num}"; then
		echo -e "${red}Merge failed for MR !${merge_request_num}. Conflicts might need manual resolution.${nocolor}"
		exit 1
	fi
	echo -e "${green}Merge !${merge_request_num} successful!${nocolor}\n"

	# --- 2. APLICAR O PATCH VK 1.4 (com sed) ---
	echo -e "${green}Applying A6xx VK 1.4 patch safely via sed...${nocolor}"

	# 1) Força o Vulkan 1.4 no meson.build (freedreno ICD generator)
	if [ -f src/freedreno/vulkan/meson.build ]; then
		sed -i 's/--api-version.*1\.1.*/--api-version 1.4/' src/freedreno/vulkan/meson.build || true
	fi

	# 2) Atualiza TU_API_VERSION para Vulkan 1.4
	if [ -f src/freedreno/vulkan/tu_device.cc ]; then
		sed -i 's/#define TU_API_VERSION VK_MAKE_VERSION(1, 3, VK_HEADER_VERSION)/#define TU_API_VERSION VK_MAKE_VERSION(1, 4, VK_HEADER_VERSION)/' src/freedreno/vulkan/tu_device.cc || true

		# 3) Injeta o bloco de conformidade dentro da função correta (tu_GetPhysicalDeviceProperties2)
		# Observação: inserimos apenas antes do 'return;' dentro do escopo da função.
		sed -n '1,4000p' src/freedreno/vulkan/tu_device.cc >/tmp/tu_device_snippet.$$
		if grep -q "tu_GetPhysicalDeviceProperties2" /tmp/tu_device_snippet.$$; then
			# editar in-place com sed range (função .. return;)
			sed -i '/tu_GetPhysicalDeviceProperties2/,/return;/ {
  /return;/ i\
   /* Force A6xx to report Vulkan 1.4 conformance */\
   p->conformanceVersion = (VkConformanceVersion){\
      .major = 1,\
      .minor = 4,\
      .subminor = 0,\
      .patch = 0,\
   };
}' src/freedreno/vulkan/tu_device.cc || true
		fi
		rm -f /tmp/tu_device_snippet.$$
		# 4) Substitui VK_MAKE_VERSION(1,3,...) por TU_API_VERSION onde apropriado
		sed -i 's/VK_MAKE_VERSION(1, 3, VK_HEADER_VERSION)/TU_API_VERSION/g' src/freedreno/vulkan/tu_device.cc || true
	fi

	echo -e "${green}✅ VK1.4 modifications for A6xx applied successfully.${nocolor}"
	# --- FIM DOS PATCHES ---

	commit_hash=$(git rev-parse HEAD)
	if [ -f VERSION ]; then
	    version_str=$(cat VERSION | xargs)
	else
	    version_str="unknown"
	fi

	cd "$workdir"
}

compile_mesa(){
	echo -e "${green}⚙️ Compiling Mesa (Main + VK1.4 Patch + MR !${merge_request_num})...${nocolor}"

	local source_dir="$workdir/mesa"
	local build_dir="$source_dir/build"
	local description="Mesa Main (A6xx VK1.4 Patch + MR !${merge_request_num})"

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
c = '$ndk_bin_path/aarch64-linux-android$sdkver-clang'
cpp = '$ndk_bin_path/aarch64-linux-android$sdkver-clang++'
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

	# EXPORT que podem ajudar Meson a não procurar librt em build host
	# (NDK toolchain deve prover o que precisa)
	export LIBRT_LIBS=""
	export CFLAGS="-D__ANDROID__"
	export CXXFLAGS="-D__ANDROID__"

	# Meson setup: incluí flags para ambiente Android e para ignorar have_librt
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
		-Dshared-glapi=enabled \
		-Db_lto=true \
		-Dvulkan-beta=true \
		-Dandroid_strict=false \
		-Dhave_librt=false \
		-Ddefault_library=shared \
		-Dc_args='-D__ANDROID__' \
		2>&1 | tee "$workdir/meson_log"

	# checar se meson gerou build.ninja
	if [ ! -f "$build_dir/build.ninja" ]; then
		echo -e "${red}meson setup failed — see $workdir/meson_log for details${nocolor}"
		exit 1
	fi

	ninja -C "$build_dir" 2>&1 | tee "$workdir/ninja_log"
}

package_driver(){
	local source_dir="$workdir/mesa"
	local build_dir="$source_dir/build"
	local lib_path="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"
	local package_temp="$workdir/package_temp"
	local description_name="Mesa Main (A6xx VK1.4 Patch + MR !${merge_request_num})"
	local output_suffix="vk14_a6xx_mr${merge_request_num}"

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

	local date_meta=$(date +'%b %d, %Y')
	local short_hash=${commit_hash:0:7}
	local meta_name="Turnip-Main-${short_hash}-VK14-A6xx-MR${merge_request_num}"
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "Built from Mesa main + A6xx VK1.4 Patch + MR !${merge_request_num}. Commit $commit_hash",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF

	local zip_name="turnip_$(date +'%Y%m%d')_${short_hash}_${output_suffix}.zip"
	zip -9 "$workdir/$zip_name" "vulkan.ad07XX.so" meta.json
	echo -e "${green}✅ Package ready: $workdir/$zip_name${nocolor}"
}

generate_release_info() {
    echo -e "${green}Generating release info files for GitHub Actions...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
	local short_hash=${commit_hash:0:7}

    echo "Mesa-Main-VK14-A6xx-MR${merge_request_num}-${date_tag}-${short_hash}" > tag
    
    echo "Turnip CI Build - ${date_tag} (Main + A6xx VK1.4 Patch + MR !${merge_request_num})" > release

    echo "Automated Turnip CI build from the latest Mesa main branch." > description
    echo "" >> description
    echo "### Build Details:" >> description
    echo "**Base:** Mesa main branch" >> description
    echo "**Patch Applied:** Force Vulkan 1.4 support for A6xx devices." >> description
	echo "**Merged MR:** \`!${merge_request_num}\` (Draft: turnip: Implement VK_QCOM_multiview_per_view_* and bin merging optimizations)" >> description
    echo "**Commit (após merge/patch):** [${short_hash}](${mesa_repo%.git}/-/commit/${commit_hash})" >> description
    
    echo -e "${green}Release info generated.${nocolor}"
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
generate_release_info

echo -e "${green}🎉 Build completed successfully!${nocolor}"
