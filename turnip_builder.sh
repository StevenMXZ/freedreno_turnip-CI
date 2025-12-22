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
