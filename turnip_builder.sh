#!/bin/bash
set -e

# ==============================
# Mesa Build Script (PixelyIon Fork)
# Branch: tu-newat
# Includes: custom tu_autotune.cc patch
# ==============================

green='\033[0;32m'
nocolor='\033[0m'

# --- Configuração ---
workdir="$HOME/mesa_build"
mesasrc="https://gitlab.freedesktop.org/PixelyIon/mesa.git"
target_branch="tu-newat"
builddir="$workdir/mesa/build"
installdir="$workdir/mesa/install"

# --- Funções ---
prepare_mesa_source() {
    echo "Preparing Mesa source directory (PixelyIon's Fork)..."
    cd "$workdir"
    if [ -d mesa ]; then
        echo "Removing old Mesa ..."
        rm -rf mesa
    fi

    echo "Cloning PixelyIon's Mesa repository..."
    git clone "$mesasrc" mesa
    cd mesa

    echo -e "${green}Checking out branch '$target_branch'...${nocolor}"
    git checkout "$target_branch"

    # --- Aplica o patch customizado ---
    echo -e "${green}Applying autotune modification patch...${nocolor}"
    patch -p1 <<'EOF'
diff --git a/src/freedreno/vulkan/tu_autotune.cc b/src/freedreno/vulkan/tu_autotune.cc
index 9d084349ca7..f15111813db 100644
--- a/src/freedreno/vulkan/tu_autotune.cc
+++ b/src/freedreno/vulkan/tu_autotune.cc
@@ -1140,14 +1140,6 @@ struct tu_autotune::rp_history {
                bool enough_samples = sysmem_ema.count >= MIN_LOCK_DURATION_COUNT && gmem_ema.count >= MIN_LOCK_DURATION_COUNT;
                uint64_t min_avg = MIN2(avg_sysmem, avg_gmem), max_avg = MAX2(avg_sysmem, avg_gmem);
                uint64_t percent_diff = (100 * (max_avg - min_avg)) / min_avg;
-
-               if (has_resolved && enough_samples && max_avg >= MIN_LOCK_THRESHOLD && percent_diff >= LOCK_PERCENT_DIFF) {
-                  if (avg_gmem < avg_sysmem)
-                     sysmem_prob = 0;
-                  else
-                     sysmem_prob = 100;
-                  locked = true;
-               }
             }
          }
EOF
    # -----------------------------

    commit_target=$(git rev-parse HEAD)
    version_target=$(cat VERSION | xargs)
    cd "$workdir"
}

configure_mesa_build() {
    echo -e "${green}Configuring Mesa with Meson...${nocolor}"
    cd mesa

    # Remove build antigo se existir
    [ -d build ] && rm -rf build

    meson setup build --prefix="$installdir" \
        -Dvulkan-drivers=freedreno \
        -Dgallium-drivers=freedreno \
        -Dplatforms=x11,wayland \
        -Dbuildtype=release \
        -Doptimization=3 \
        -Dshared-glapi=true \
        -Dglx=dri \
        -Dgbm=true \
        -Degl=true \
        -Dgles1=false \
        -Dgles2=true \
        -Dllvm=false \
        -Dshared-llvm=false \
        -Dvalgrind=false \
        -Dlibunwind=false \
        -Dbuild-tests=false

    cd "$workdir"
}

build_mesa() {
    echo -e "${green}Building Mesa (freedreno Vulkan)...${nocolor}"
    cd "$builddir"
    ninja -j$(nproc)
    ninja install
    echo -e "${green}Mesa build completed successfully!${nocolor}"
}

# --- Execução ---
mkdir -p "$workdir"
prepare_mesa_source
configure_mesa_build
build_mesa

echo -e "${green}All done! Patched Mesa built and installed in:${nocolor} $installdir"
