#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
sdkver="35"
# REPO ALTERADO PARA O DO ROBCLARK
mesa_repo="https://gitlab.freedesktop.org/robclark/mesa.git"
mesa_branch="tu/gen8"

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
	echo "Preparing NDK ..."
	mkdir -p "$workdir"
	cd "$workdir"
	if [ -z "${ANDROID_NDK_LATEST_HOME}" ]; then
		if [ ! -d "$ndkver" ]; then
			echo "Downloading Android NDK ..."
			curl -L "https://dl.google.com/android/repository/${ndkver}-linux.zip" --output "${ndkver}-linux.zip" &> /dev/null
			echo "Extracting NDK ..."
			unzip -q "${ndkver}-linux.zip" &> /dev/null
		fi
        export ANDROID_NDK_HOME="$workdir/$ndkver"
	else
		echo "Using preinstalled Android NDK."
        export ANDROID_NDK_HOME="$ANDROID_NDK_LATEST_HOME"
	fi
}

prepare_source(){
	echo "Preparing Mesa source..."
	cd "$workdir"
	if [ -d mesa ]; then rm -rf mesa; fi
	
    # Clone do repositório específico
    echo "Cloning from $mesa_repo branch $mesa_branch..."
	git clone "$mesa_repo" mesa
	cd mesa
    git checkout "$mesa_branch"

    # --- CORREÇÃO DO ERRO DE IDENTIDADE ---
    echo "Configuring Git Identity..."
    git config user.email "ci@turnip.builder"
    git config user.name "Turnip CI Builder"

    # --- APLICANDO O PATCH A830 ---
    echo "Applying A830 Patch..."
    
    # Criando o arquivo de patch localmente com o conteúdo fornecido
    cat <<'EOF' > ../a830_all.patch
From e5a31b484dea5f49d4abad8fcd552afea43e444f Mon Sep 17 00:00:00 2001
From: whitebelyash <whbexiumwork@gmail.com>
Date: Tue, 6 Jan 2026 20:12:50 +0400
Subject: [PATCH 1/7] [HACK]: turnip: changes to get A830 working on KGSL in
 some extent

Signed-off-by: whitebelyash <whbexiumwork@gmail.com>
---
 src/freedreno/common/freedreno_devices.py | 2 +-
 src/freedreno/vulkan/tu_knl_kgsl.cc       | 4 ++++
 2 files changed, 5 insertions(+), 1 deletion(-)

diff --git a/src/freedreno/common/freedreno_devices.py b/src/freedreno/common/freedreno_devices.py
index 6a3625b..5d04a70 100644
--- a/src/freedreno/common/freedreno_devices.py
+++ b/src/freedreno/common/freedreno_devices.py
@@ -1463,7 +1463,7 @@ a8xx_gen2 = GPUProps(
 
 # Totally fake, just to get cffdump to work:
 add_gpus([
-        GPUId(chip_id=0x44050000, name="FD830"),
+        GPUId(chip_id=0x44050001, name="FD830"),
     ], A6xxGPUInfo(
         CHIP.A8XX,
         [a7xx_base, a7xx_gen3, a8xx_base],
diff --git a/src/freedreno/vulkan/tu_knl_kgsl.cc b/src/freedreno/vulkan/tu_knl_kgsl.cc
index e3a4969..9e5b504 100644
--- a/src/freedreno/vulkan/tu_knl_kgsl.cc
+++ b/src/freedreno/vulkan/tu_knl_kgsl.cc
@@ -1845,6 +1845,10 @@ tu_knl_kgsl_load(struct tu_instance *instance, int fd)
       device->ubwc_config.bank_swizzle_levels = 0x6;
       device->ubwc_config.macrotile_mode = FDL_MACROTILE_8_CHANNEL;
       break;
+   case 0x5:
+      device->ubwc_config.bank_swizzle_levels = 0x6;
+      device->ubwc_config.macrotile_mode = FDL_MACROTILE_8_CHANNEL;
+      break; 
    default:
       return vk_errorf(instance, VK_ERROR_INITIALIZATION_FAILED,
                        "unknown UBWC version 0x%x", ubwc_version);
-- 
2.52.0


From 533c4f093b7923e0c95374689806bdf496ff2075 Mon Sep 17 00:00:00 2001
From: whitebelyash <whbexiumwork@gmail.com>
Date: Tue, 6 Jan 2026 20:19:59 +0400
Subject: [PATCH 2/7] turnip: split A830 defs

Apparently there are two versions of A830 in the wild

Signed-off-by: whitebelyash <whbexiumwork@gmail.com>
---
 src/freedreno/common/freedreno_devices.py | 24 ++++++++++++++++++++++-
 1 file changed, 23 insertions(+), 1 deletion(-)

diff --git a/src/freedreno/common/freedreno_devices.py b/src/freedreno/common/freedreno_devices.py
index 5d04a70..7f4caeb 100644
--- a/src/freedreno/common/freedreno_devices.py
+++ b/src/freedreno/common/freedreno_devices.py
@@ -1463,7 +1463,29 @@ a8xx_gen2 = GPUProps(
 
 # Totally fake, just to get cffdump to work:
 add_gpus([
-        GPUId(chip_id=0x44050001, name="FD830"),
+        GPUId(chip_id=0x44050000, name="FD830"),
     ], A6xxGPUInfo(
         CHIP.A8XX,
         [a7xx_base, a7xx_gen3, a8xx_base],
         num_ccu = 6,
         num_slices = 3,
         tile_align_w = 64,
         tile_align_h = 32,
         tile_max_w = 16384,
         tile_max_h = 16384,
         num_vsc_pipes = 32,
         cs_shared_mem_size = 32 * 1024,
         wave_granularity = 2,
         fibers_per_sp = 128 * 2 * 16,
         magic_regs = dict(
         ),
         raw_magic_regs = [
         ],
     ))
 
+# Not really sure how it's different from the upper one:
+add_gpus([
+        GPUId(chip_id=0x44050001, name="FD830v2"),
     ], A6xxGPUInfo(
         CHIP.A8XX,
         [a7xx_base, a7xx_gen3, a8xx_base],
-- 
2.52.0


From 0bdc89babf3d99c98735bb16a3d889dda2f468e9 Mon Sep 17 00:00:00 2001
From: whitebelyash <whbexiumwork@gmail.com>
Date: Tue, 6 Jan 2026 23:45:46 +0400
Subject: [PATCH 3/7] turnip: use gen2 config for A830

Apparently it's fine with this

Signed-off-by: whitebelyash <whbexiumwork@gmail.com>
---
 src/freedreno/common/freedreno_devices.py | 95 ++++++++++++++---------
 1 file changed, 57 insertions(+), 38 deletions(-)

diff --git a/src/freedreno/common/freedreno_devices.py b/src/freedreno/common/freedreno_devices.py
index 7f4caeb..1319208 100644
--- a/src/freedreno/common/freedreno_devices.py
+++ b/src/freedreno/common/freedreno_devices.py
@@ -1439,6 +1439,25 @@ a8xx_base = GPUProps(
         has_rt_workaround = False,
     )
 
+a8xx_gen1 = GPUProps(
+        reg_size_vec4 = 96,
+        sysmem_vpc_attr_buf_size = 131072,
+        sysmem_vpc_pos_buf_size = 65536,
+        sysmem_vpc_bv_pos_buf_size = 32768,
+        sysmem_ccu_color_cache_fraction = CCUColorCacheFraction.FULL.value,
+        sysmem_per_ccu_color_cache_size = 128 * 1024,
+        sysmem_ccu_depth_cache_fraction = CCUColorCacheFraction.THREE_QUARTER.value,
+        sysmem_per_ccu_depth_cache_size = 192 * 1024,
+        gmem_vpc_attr_buf_size = 49152,
+        gmem_vpc_pos_buf_size = 24576,
+        gmem_vpc_bv_pos_buf_size = 32768,
+        gmem_ccu_color_cache_fraction = CCUColorCacheFraction.EIGHTH.value,
+        gmem_per_ccu_color_cache_size = 8 * 1024,
+        gmem_ccu_depth_cache_fraction = CCUColorCacheFraction.FULL.value,
+        gmem_per_ccu_depth_cache_size = 127 * 1024,
+        has_fs_tex_prefetch = False,
+)
+
 a8xx_gen2 = GPUProps(
         reg_size_vec4 = 128,
         sysmem_vpc_attr_buf_size = 131072,
@@ -1461,12 +1480,46 @@ a8xx_gen2 = GPUProps(
         has_attachment_shading_rate = False,
 )
 
+# For a8xx, the chicken bit and most other non-ctx reg
+# programming moves into the kernel, and what remains
+# should be easier to share between devices
+a8xx_gen2_raw_magic_regs = [
+        [A6XXRegs.REG_A8XX_GRAS_UNKNOWN_8228, 0x00000000],
+        [A6XXRegs.REG_A8XX_GRAS_UNKNOWN_8229, 0x00000000],
+        [A6XXRegs.REG_A8XX_GRAS_UNKNOWN_822A, 0x00000000],
+        [A6XXRegs.REG_A8XX_GRAS_UNKNOWN_822B, 0x00000000],
+        [A6XXRegs.REG_A8XX_GRAS_UNKNOWN_822C, 0x00000000],
+        [A6XXRegs.REG_A8XX_GRAS_UNKNOWN_822D, 0x00000000],
+
+        [A6XXRegs.REG_A6XX_RB_UNKNOWN_8818,   0x00000000],
+        [A6XXRegs.REG_A6XX_RB_UNKNOWN_8819,   0x00000000],
+        [A6XXRegs.REG_A6XX_RB_UNKNOWN_881A,   0x00000000],
+        [A6XXRegs.REG_A6XX_RB_UNKNOWN_881B,   0x00000000],
+        [A6XXRegs.REG_A6XX_RB_UNKNOWN_881C,   0x00000000],
+        [A6XXRegs.REG_A6XX_RB_UNKNOWN_881D,   0x00000000],
+        [A6XXRegs.REG_A6XX_RB_UNKNOWN_881E,   0x00000000],
+        [A6XXRegs.REG_A7XX_RB_LRZ_CNTL2,      0x00000000],
+        [A6XXRegs.REG_A8XX_RB_RESOLVE_CNTL_5, 0x00000001],
+
+        [A6XXRegs.REG_A7XX_SP_UNKNOWN_AB01,   0x00000001],
+        [A6XXRegs.REG_A7XX_SP_HLSQ_MODE_CNTL, 0x00000000],
+        [A6XXRegs.REG_A8XX_SP_UNKNOWN_AB23,   0x00000000],
+
+        [A6XXRegs.REG_A6XX_TPL1_PS_ROTATION_CNTL, 0x00000004],
+        [A6XXRegs.REG_A6XX_TPL1_PS_SWIZZLE_CNTL, 0x00000000],
+
+        [A6XXRegs.REG_A8XX_VPC_UNKNOWN_9313,  0x00000000],
+
+        [A6XXRegs.REG_A8XX_PC_UNKNOWN_980B, 0x00800280],
+        [A6XXRegs.REG_A8XX_PC_MODE_CNTL,    0x00003f00],
+    ]
+
 # Totally fake, just to get cffdump to work:
 add_gpus([
         GPUId(chip_id=0x44050000, name="FD830"),
     ], A6xxGPUInfo(
         CHIP.A8XX,
-        [a7xx_base, a7xx_gen3, a8xx_base],
+        [a7xx_base, a7xx_gen3, a8xx_base, a8xx_gen1],
         num_ccu = 6,
         num_slices = 3,
         tile_align_w = 64,
@@ -1479,8 +1532,7 @@ add_gpus([
         fibers_per_sp = 128 * 2 * 16,
         magic_regs = dict(
         ),
-        raw_magic_regs = [
-        ],
+        raw_magic_regs = a8xx_gen2_raw_magic_regs,
     ))
 
 # Not really sure how it's different from the upper one:
@@ -1488,7 +1540,7 @@ add_gpus([
         GPUId(chip_id=0x44050001, name="FD830v2"),
     ], A6xxGPUInfo(
         CHIP.A8XX,
-        [a7xx_base, a7xx_gen3, a8xx_base],
+        [a7xx_base, a7xx_gen3, a8xx_base, a8xx_gen1],
         num_ccu = 6,
         num_slices = 3,
         tile_align_w = 64,
@@ -1501,43 +1553,10 @@ add_gpus([
         fibers_per_sp = 128 * 2 * 16,
         magic_regs = dict(
         ),
-        raw_magic_regs = [
-        ],
+        raw_magic_regs = a8xx_gen2_raw_magic_regs,
     ))
 
-# For a8xx, the chicken bit and most other non-ctx reg
-# programming moves into the kernel, and what remains
-# should be easier to share between devices
-a8xx_gen2_raw_magic_regs = [
-        [A6XXRegs.REG_A8XX_GRAS_UNKNOWN_8228, 0x00000000],
-        [A6XXRegs.REG_A8XX_GRAS_UNKNOWN_8229, 0x00000000],
-        [A6XXRegs.REG_A8XX_GRAS_UNKNOWN_822A, 0x00000000],
-        [A6XXRegs.REG_A8XX_GRAS_UNKNOWN_822B, 0x00000000],
-        [A6XXRegs.REG_A8XX_GRAS_UNKNOWN_822C, 0x00000000],
-        [A6XXRegs.REG_A8XX_GRAS_UNKNOWN_822D, 0x00000000],
-
-        [A6XXRegs.REG_A6XX_RB_UNKNOWN_8818,   0x00000000],
-        [A6XXRegs.REG_A6XX_RB_UNKNOWN_8819,   0x00000000],
-        [A6XXRegs.REG_A6XX_RB_UNKNOWN_881A,   0x00000000],
-        [A6XXRegs.REG_A6XX_RB_UNKNOWN_881B,   0x00000000],
-        [A6XXRegs.REG_A6XX_RB_UNKNOWN_881C,   0x00000000],
-        [A6XXRegs.REG_A6XX_RB_UNKNOWN_881D,   0x00000000],
-        [A6XXRegs.REG_A6XX_RB_UNKNOWN_881E,   0x00000000],
-        [A6XXRegs.REG_A7XX_RB_LRZ_CNTL2,      0x00000000],
-        [A6XXRegs.REG_A8XX_RB_RESOLVE_CNTL_5, 0x00000001],
-
-        [A6XXRegs.REG_A7XX_SP_UNKNOWN_AB01,   0x00000001],
-        [A6XXRegs.REG_A7XX_SP_HLSQ_MODE_CNTL, 0x00000000],
-        [A6XXRegs.REG_A8XX_SP_UNKNOWN_AB23,   0x00000000],
-
-        [A6XXRegs.REG_A6XX_TPL1_PS_ROTATION_CNTL, 0x00000004],
-        [A6XXRegs.REG_A6XX_TPL1_PS_SWIZZLE_CNTL, 0x00000000],
 
-        [A6XXRegs.REG_A8XX_VPC_UNKNOWN_9313,  0x00000000],
-
-        [A6XXRegs.REG_A8XX_PC_UNKNOWN_980B, 0x00800280],
-        [A6XXRegs.REG_A8XX_PC_MODE_CNTL,    0x00003f00],
-    ]
 
 add_gpus([
         GPUId(chip_id=0xffff44050A31, name="Adreno (TM) 840"),
-- 
2.52.0


From cbb327dabdd47bee833e1481cc2d741e6d07e424 Mon Sep 17 00:00:00 2001
From: whitebelyash <whbexiumwork@gmail.com>
Date: Thu, 8 Jan 2026 23:04:28 +0400
Subject: [PATCH 4/7] turnip: add ubwc 0x6 handling for 8xx gen2

Signed-off-by: whitebelyash <whbexiumwork@gmail.com>
---
 src/freedreno/vulkan/tu_knl_kgsl.cc | 6 +++++-
 1 file changed, 5 insertions(+), 1 deletion(-)

diff --git a/src/freedreno/vulkan/tu_knl_kgsl.cc b/src/freedreno/vulkan/tu_knl_kgsl.cc
index 9e5b504..2518a83 100644
--- a/src/freedreno/vulkan/tu_knl_kgsl.cc
+++ b/src/freedreno/vulkan/tu_knl_kgsl.cc
@@ -1848,7 +1848,11 @@ tu_knl_kgsl_load(struct tu_instance *instance, int fd)
    case 0x5:
       device->ubwc_config.bank_swizzle_levels = 0x6;
       device->ubwc_config.macrotile_mode = FDL_MACROTILE_8_CHANNEL;
-      break; 
+      break;
+   case 0x6:
+      device->ubwc_config.bank_swizzle_levels = 0x6;
+      device->ubwc_config.macrotile_mode = FDL_MACROTILE_8_CHANNEL;
+      break;
    default:
       return vk_errorf(instance, VK_ERROR_INITIALIZATION_FAILED,
                        "unknown UBWC version 0x%x", ubwc_version);
-- 
2.52.0


From 98724a952b92e7b3ce9233fdb316990ed109b719 Mon Sep 17 00:00:00 2001
From: whitebelyash <whbexiumwork@gmail.com>
Date: Thu, 8 Jan 2026 23:34:25 +0400
Subject: [PATCH 5/7] [HACK]: turnip: add maybe working Adreno 825 support

Signed-off-by: whitebelyash <whbexiumwork@gmail.com>
---
 src/freedreno/common/freedreno_devices.py | 22 ++++++++++++++++++++--
 1 file changed, 20 insertions(+), 2 deletions(-)

diff --git a/src/freedreno/common/freedreno_devices.py b/src/freedreno/common/freedreno_devices.py
index 1319208..5b3f62f 100644
--- a/src/freedreno/common/freedreno_devices.py
+++ b/src/freedreno/common/freedreno_devices.py
@@ -1555,8 +1555,26 @@ add_gpus([
         ),
         raw_magic_regs = a8xx_gen2_raw_magic_regs,
     ))
-
-
+# Completely experimental, added blindly
+add_gpus([
+        GPUId(chip_id=0x44030000, name="FD825"),
+    ], A6xxGPUInfo(
+        CHIP.A8XX,
+        [a7xx_base, a7xx_gen3, a8xx_base, a8xx_gen1],
+        num_ccu = 6,
+        num_slices = 3,
+        tile_align_w = 64,
+        tile_align_h = 32,
+        tile_max_w = 16384,
+        tile_max_h = 16384,
+        num_vsc_pipes = 32,
+        cs_shared_mem_size = 32 * 1024,
+        wave_granularity = 2,
+        fibers_per_sp = 128 * 2 * 16,
+        magic_regs = dict(
+        ),
+        raw_magic_regs = a8xx_gen2_raw_magic_regs,
+    ))
 
 add_gpus([
         GPUId(chip_id=0xffff44050A31, name="Adreno (TM) 840"),
-- 
2.52.0


From 0e26fb558c5822c771666dd18059ea114b9eb025 Mon Sep 17 00:00:00 2001
From: whitebelyash <whbexiumwork@gmail.com>
Date: Fri, 9 Jan 2026 14:40:52 +0400
Subject: [PATCH 6/7] [HACK, DO NOT USE] turnip: skip all tessellation draws

These cause GPU faults and were disabled in "upstream" by hiding the features. DXVK requires them, so let's just skip tess draws instead

Signed-off-by: whitebelyash <whbexiumwork@gmail.com>
---
 src/freedreno/vulkan/tu_cmd_buffer.cc | 32 +++++++++++++++++++++++++++
 1 file changed, 32 insertions(+)

diff --git a/src/freedreno/vulkan/tu_cmd_buffer.cc b/src/freedreno/vulkan/tu_cmd_buffer.cc
index d8a2f46..7d349f0 100644
--- a/src/freedreno/vulkan/tu_cmd_buffer.cc
+++ b/src/freedreno/vulkan/tu_cmd_buffer.cc
@@ -8542,6 +8542,10 @@ tu_CmdDraw(VkCommandBuffer commandBuffer,
    VK_FROM_HANDLE(tu_cmd_buffer, cmd, commandBuffer);
    struct tu_cs *cs = &cmd->draw_cs;
 
+   bool has_tess = cmd->state.shaders[MESA_SHADER_TESS_CTRL]->variant;
+   if (has_tess)
+      return;
+
    tu6_emit_vs_params(cmd, 0, firstVertex, firstInstance);
 
    tu6_draw_common<CHIP>(cmd, cs, false, vertexCount);
@@ -8571,6 +8575,8 @@ tu_CmdDrawMultiEXT(VkCommandBuffer commandBuffer,
       return;
 
    bool has_tess = cmd->state.shaders[MESA_SHADER_TESS_CTRL]->variant;
+   if (has_tess)
+      return;
 
    uint32_t max_vertex_count = 0;
    if (has_tess) {
@@ -8616,6 +8622,10 @@ tu_CmdDrawIndexed(VkCommandBuffer commandBuffer,
    VK_FROM_HANDLE(tu_cmd_buffer, cmd, commandBuffer);
    struct tu_cs *cs = &cmd->draw_cs;
 
+   bool has_tess = cmd->state.shaders[MESA_SHADER_TESS_CTRL]->variant;
+   if (has_tess)
+      return;
+
    tu6_emit_vs_params(cmd, 0, vertexOffset, firstInstance);
 
    tu6_draw_common<CHIP>(cmd, cs, true, indexCount);
@@ -8649,6 +8659,8 @@ tu_CmdDrawMultiIndexedEXT(VkCommandBuffer commandBuffer,
       return;
 
    bool has_tess = cmd->state.shaders[MESA_SHADER_TESS_CTRL]->variant;
+   if (has_tess)
+      return;
 
    uint32_t max_index_count = 0;
    if (has_tess) {
@@ -8712,6 +8724,10 @@ tu_CmdDrawIndirect(VkCommandBuffer commandBuffer,
    VK_FROM_HANDLE(tu_buffer, buf, _buffer);
    struct tu_cs *cs = &cmd->draw_cs;
 
+   bool has_tess = cmd->state.shaders[MESA_SHADER_TESS_CTRL]->variant;
+   if (has_tess)
+      return;
+
    tu6_emit_empty_vs_params<CHIP>(cmd);
 
    if (cmd->device->physical_device->info->props.indirect_draw_wfm_quirk)
@@ -8743,6 +8759,10 @@ tu_CmdDrawIndexedIndirect(VkCommandBuffer commandBuffer,
    VK_FROM_HANDLE(tu_buffer, buf, _buffer);
    struct tu_cs *cs = &cmd->draw_cs;
 
+   bool has_tess = cmd->state.shaders[MESA_SHADER_TESS_CTRL]->variant;
+   if (has_tess)
+      return;
+
    tu6_emit_empty_vs_params<CHIP>(cmd);
 
    if (cmd->device->physical_device->info->props.indirect_draw_wfm_quirk)
@@ -8779,6 +8799,10 @@ tu_CmdDrawIndirectCount(VkCommandBuffer commandBuffer,
    VK_FROM_HANDLE(tu_buffer, count_buf, countBuffer);
    struct tu_cs *cs = &cmd->draw_cs;
 
+   bool has_tess = cmd->state.shaders[MESA_SHADER_TESS_CTRL]->variant;
+   if (has_tess)
+      return;
+
    tu6_emit_empty_vs_params<CHIP>(cmd);
 
    /* It turns out that the firmware we have for a650 only partially fixed the
@@ -8818,6 +8842,10 @@ tu_CmdDrawIndexedIndirectCount(VkCommandBuffer commandBuffer,
    VK_FROM_HANDLE(tu_buffer, count_buf, countBuffer);
    struct tu_cs *cs = &cmd->draw_cs;
 
+   bool has_tess = cmd->state.shaders[MESA_SHADER_TESS_CTRL]->variant;
+   if (has_tess)
+      return;
+
    tu6_emit_empty_vs_params<CHIP>(cmd);
 
    draw_wfm(cmd);
@@ -8853,6 +8881,10 @@ tu_CmdDrawIndirectByteCountEXT(VkCommandBuffer commandBuffer,
    VK_FROM_HANDLE(tu_buffer, buf, _counterBuffer);
    struct tu_cs *cs = &cmd->draw_cs;
 
+   bool has_tess = cmd->state.shaders[MESA_SHADER_TESS_CTRL]->variant;
+   if (has_tess)
+      return;
+
    /* All known firmware versions do not wait for WFI's with CP_DRAW_AUTO.
     * Plus, for the common case where the counter buffer is written by
     * vkCmdEndTransformFeedback, we need to wait for the CP_WAIT_MEM_WRITES to
-- 
2.52.0


From 674cda5b2ca36e83afb497e4d05dccf84a7d521b Mon Sep 17 00:00:00 2001
From: whitebelyash <whbexiumwork@gmail.com>
Date: Fri, 9 Jan 2026 14:45:11 +0400
Subject: [PATCH 7/7] [HACK] turnip: re-enable GS/TS on gen8

Signed-off-by: whitebelyash <whbexiumwork@gmail.com>
---
 src/freedreno/vulkan/tu_device.cc | 12 ++++++------
 1 file changed, 6 insertions(+), 6 deletions(-)

diff --git a/src/freedreno/vulkan/tu_device.cc b/src/freedreno/vulkan/tu_device.cc
index 977944e..8ee852b 100644
--- a/src/freedreno/vulkan/tu_device.cc
+++ b/src/freedreno/vulkan/tu_device.cc
@@ -381,8 +381,8 @@ tu_get_features(struct tu_physical_device *pdevice,
    features->fullDrawIndexUint32 = true;
    features->imageCubeArray = true;
    features->independentBlend = true;
-   features->geometryShader = !pdevice->info->props.is_a702 && (pdevice->info->chip != 8);
-   features->tessellationShader = !pdevice->info->props.is_a702 && (pdevice->info->chip != 8);
+   features->geometryShader = !pdevice->info->props.is_a702;
+   features->tessellationShader = !pdevice->info->props.is_a702;
    features->sampleRateShading = true;
    features->dualSrcBlend = true;
    features->logicOp = true;
@@ -405,7 +405,7 @@ tu_get_features(struct tu_physical_device *pdevice,
    features->pipelineStatisticsQuery = true;
    features->vertexPipelineStoresAndAtomics = true;
    features->fragmentStoresAndAtomics = true;
-   features->shaderTessellationAndGeometryPointSize = !pdevice->info->props.is_a702 && (pdevice->info->chip != 8);
+   features->shaderTessellationAndGeometryPointSize = !pdevice->info->props.is_a702;
    features->shaderImageGatherExtended = true;
    features->shaderStorageImageExtendedFormats = true;
    features->shaderStorageImageMultisample = false;
@@ -651,7 +651,7 @@ tu_get_features(struct tu_physical_device *pdevice,
 
/* VK_EXT_extended_dynamic_state3 */
    features->extendedDynamicState3PolygonMode = true;
-   features->extendedDynamicState3TessellationDomainOrigin = !pdevice->info->props.is_a702 && (pdevice->info->chip != 8);
+   features->extendedDynamicState3TessellationDomainOrigin = !pdevice->info->props.is_a702;
    features->extendedDynamicState3DepthClampEnable = true;
    features->extendedDynamicState3DepthClipEnable = true;
    features->extendedDynamicState3LogicOpEnable = true;
@@ -858,7 +858,7 @@ tu_get_physical_device_properties_1_1(struct tu_physical_device *pdevice,
    if (pdevice->info->props.has_getfiberid) {
       p->subgroupSupportedStages |= VK_SHADER_STAGE_ALL_GRAPHICS;
       p->subgroupSupportedOperations |= VK_SUBGROUP_FEATURE_QUAD_BIT;
-      if (pdevice->info->chip == 8) {
+      if (false) {
          p->subgroupSupportedStages &= ~(VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT |
                                          VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT |
                                          VK_SHADER_STAGE_GEOMETRY_BIT);
@@ -1096,7 +1096,7 @@ tu_get_properties(struct tu_physical_device *pdevice,
    props->maxVertexInputAttributeOffset = 4095;
    props->maxVertexInputBindingStride = 2048;
    props->maxVertexOutputComponents = pdevice->info->props.is_a702 ? 64 : 128;
-   if (!pdevice->info->props.is_a702 && (pdevice->info->chip != 8)) {
+   if (!pdevice->info->props.is_a702) {
       props->maxTessellationGenerationLevel = 64;
       props->maxTessellationPatchSize = 32;
       props->maxTessellationControlPerVertexInputComponents = 128;
-- 
2.52.0
EOF
    
    # Aplica o patch
    git am ../a830_all.patch || {
        echo -e "${red}Failed to apply patch!${nocolor}"
        exit 1
    }
    
	commit_hash=$(git rev-parse HEAD)
	if [ -f VERSION ]; then
	    version_str=$(cat VERSION | xargs)
	else
	    version_str="unknown"
	fi

	cd "$workdir"
}

compile_mesa(){
	echo -e "${green}Compiling Mesa...${nocolor}"

	local source_dir="$workdir/mesa"
	local build_dir="$source_dir/build"
	
	local ndk_root_path="$ANDROID_NDK_HOME"
	local ndk_bin_path="$ndk_root_path/toolchains/llvm/prebuilt/linux-x86_64/bin"
	local ndk_sysroot_path="$ndk_root_path/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

	local cross_file="$source_dir/android-aarch64-crossfile.txt"
	cat <<EOF > "$cross_file"
[binaries]
ar = '$ndk_bin_path/llvm-ar'
c = ['ccache', '$ndk_bin_path/aarch64-linux-android$sdkver-clang', '--sysroot=$ndk_sysroot_path']
cpp = ['ccache', '$ndk_bin_path/aarch64-linux-android$sdkver-clang++', '--sysroot=$ndk_sysroot_path', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$ndk_bin_path/aarch64-linux-android-strip'
pkg-config = '/usr/bin/pkg-config'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

	cd "$source_dir"

	export LIBRT_LIBS=""
	export CFLAGS="-D__ANDROID__"
	export CXXFLAGS="-D__ANDROID__"

    # ZSTD e Libarchive desativados para compatibilidade
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
		-Ddefault_library=shared \
        -Dzstd=disabled \
        -Dlibarchive=disabled \
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
	local meta_name="Turnip-A830-${short_hash}"
	cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$meta_name",
  "description": "Turnip A830 (Robclark/tu/gen8) + Patch. Commit $short_hash",
  "author": "mesa-ci",
  "driverVersion": "$version_str",
  "libraryName": "vulkan.ad07XX.so"
}
EOF

	local zip_name="Turnip-A830-${short_hash}.zip"
	zip -9 "$workdir/$zip_name" "vulkan.ad07XX.so" meta.json
	echo -e "${green}Package ready: $workdir/$zip_name${nocolor}"
}

generate_release_info() {
    echo -e "${green}Generating release info...${nocolor}"
    cd "$workdir"
    local date_tag=$(date +'%Y%m%d')
	local short_hash=${commit_hash:0:7}

    echo "Turnip-A830-${date_tag}-${short_hash}" > tag
    echo "Turnip A830 Build - ${date_tag}" > release

    echo "Automated Turnip Build for Adreno 830." > description
    echo "" >> description
    echo "### Build Details:" >> description
    echo "**Base:** robclark/mesa (tu/gen8)" >> description
    echo "**Patches:** A830 Enabler (Gen8 Support)" >> description
    echo "**Commit:** [${short_hash}](${mesa_repo%.git}/-/commit/${commit_hash})" >> description
}

check_deps
prepare_ndk
prepare_source
compile_mesa
package_driver
generate_release_info