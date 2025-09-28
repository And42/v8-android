#!/bin/bash

set -e # fail on any error
set -o verbose # print commands as they are executed

if [ $# -ne 3 ]; then
    echo "Error: Exactly 3 arguments are required"
    echo "Usage: $0 <ARG_PLATFORM_BITS=\"32\"|\"64\"> <ARG_V8_BRANCH> <ARG_NDK_RELEASE>"
    echo "Example usage: $0 \"64\" \"branch-heads/13.6\" \"r28c\""
    exit 1
fi

ARG_PLATFORM_BITS=$1 # example: "64"
ARG_V8_BRANCH=$2 # example: "branch-heads/13.6"
ARG_NDK_RELEASE=$3 # example: "r28c"

WORKING_DIRECTORY="/home/v8-building"
DEPOT_TOOLS_DIRECTORY="${WORKING_DIRECTORY}/depot_tools"
ARTIFACTS_DIRECTORY="${WORKING_DIRECTORY}/artifacts"

echo
echo "Arguments:"
echo "  ARG_PLATFORM_BITS: ${ARG_PLATFORM_BITS}"
echo "  ARG_V8_BRANCH: ${ARG_V8_BRANCH}"
echo "  ARG_NDK_RELEASE: ${ARG_NDK_RELEASE}"
echo

echo
echo "Installing system packages"
echo

apt-get update

apt-get install --assume-yes \
    git \
    unzip \
    zip \
    curl \
    wget \
    python3 \
    lsb-release \
    sudo \
    file \
    lib32gcc-s1 \
    lib32stdc++6

# git - cloning repos
# unzip - unpacking android ndk
# zip - packing artifacts
# curl, wget - downloading depot tools data and ndk
# python3 - needed for v8 scripts
# lsb-release, file - to find missing dependencies for v8 building
# sudo - to install missing dependencies for v8 building
# lib32gcc-s1, lib32stdc++6 - to build 32-bit android

echo
echo "Creating working directory"
echo

mkdir -p "${WORKING_DIRECTORY}" # create the folder and don't fail if it already exists
cd "${WORKING_DIRECTORY}"

echo
echo "Creating artifacts directory"
echo

mkdir -p "${ARTIFACTS_DIRECTORY}"

echo
echo "Setting up depot tools"
echo

git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "${DEPOT_TOOLS_DIRECTORY}"

export PATH="${DEPOT_TOOLS_DIRECTORY}:$PATH"

pushd "${DEPOT_TOOLS_DIRECTORY}"

    ./gclient

popd

echo
echo "Fetching V8"
echo

fetch v8

pushd v8

    echo
    echo "Switching to the target v8 branch"
    echo

    git checkout "${ARG_V8_BRANCH}"
    gclient sync
    gclient sync --deps=all || true # needed for third_party/catapult. Throws an error but we don't care. Otherwise, v8 config generation fails

    echo
    echo "Installing V8 build dependencies"
    echo

    # setup a default keyboard layout to avoid interactive dialog inside build deps
    echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections
    echo 'keyboard-configuration keyboard-configuration/layout select English (US)' | debconf-set-selections
    echo 'keyboard-configuration keyboard-configuration/layoutcode select us' | debconf-set-selections

    ./build/install-build-deps.sh

popd

echo
echo "Setting up NDK"
echo

wget --output-document=ndk.zip --progress=dot:giga https://dl.google.com/android/repository/android-ndk-r26d-linux.zip
unzip ndk.zip -d ndk-temp
mkdir ndk
cp --recursive ndk-temp/*/. ndk
rm -rf ndk-temp ndk.zip

pushd v8

    # According to v8 devs it's not possible to build a single .so file via arguments: https://stackoverflow.com/a/71221645.
    # So, we are building the monolithic static library instead

    echo
    echo "Generating v8 configuration"
    echo

    if [[ "${ARG_PLATFORM_BITS}" = "32" ]]; then
        OUT_DIR="arm32.release"

        # x32
        python3 tools/dev/v8gen.py -b android.arm.release "${OUT_DIR}" -- \
            is_component_build=false \
            icu_use_data_file=false \
            v8_enable_sandbox=false \
            v8_enable_i18n_support=false `# check` \
            v8_use_external_startup_data=false \
            v8_monolithic=true \
            android_ndk_root=\"${WORKING_DIRECTORY}/ndk\" \
            use_custom_libcxx=false
    else
        OUT_DIR="arm64.release"

        # x64
        python3 tools/dev/v8gen.py -b android.arm.release "${OUT_DIR}" -- \
            target_cpu=\"arm64\" \
            v8_target_cpu=\"arm64\" \
            is_component_build=false \
            icu_use_data_file=false \
            v8_enable_sandbox=false \
            v8_enable_i18n_support=false `# check` \
            v8_use_external_startup_data=false \
            v8_monolithic=true \
            android_ndk_root=\"${WORKING_DIRECTORY}/ndk\" \
            use_custom_libcxx=false
    fi

    echo
    echo "Listing build flags"
    echo

    BUILD_FLAGS_FILE="${ARTIFACTS_DIRECTORY}/v8_build_flags.txt"
    gn desc "out.gn/${OUT_DIR}" //:v8_monolith defines >> "${BUILD_FLAGS_FILE}"
    cat "${BUILD_FLAGS_FILE}"

    echo
    echo "Building v8"
    echo

    ninja -C "out.gn/${OUT_DIR}" v8_monolith

    echo
    echo "Copying artifacts"
    echo

    cp "out.gn/${OUT_DIR}/obj/libv8_monolith.a" "${ARTIFACTS_DIRECTORY}/libv8_monolith.a"
    zip -r "${ARTIFACTS_DIRECTORY}/include.zip" include

popd

    # ../ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android21-clang++ \
    #     -shared -o "out.gn/arm64.release/libv8_monolith.so" \
    #   -Wl,--gc-sections \
    #   -Wl,--strip-all \
    #   -Wl,--exclude-libs,ALL \
    #     -Wl,--whole-archive \
    #     "out.gn/arm64.release/obj/libv8_monolith.a" \
    #     -Wl,--no-whole-archive \
    #     -llog -landroid -lm -ldl


    # use_sysroot=false
    # v8_enable_lite_mode=true - for not jit