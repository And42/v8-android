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
NDK_DIRECTORY="${WORKING_DIRECTORY}/ndk"

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

wget --output-document=ndk.zip --progress=dot:giga "https://dl.google.com/android/repository/android-ndk-${ARG_NDK_RELEASE}-linux.zip"
unzip -q ndk.zip -d ndk-temp
mkdir "${NDK_DIRECTORY}"
cp --recursive ndk-temp/*/. "${NDK_DIRECTORY}"
rm --recursive --force ndk-temp ndk.zip

pushd v8

    # According to v8 devs it's not possible to build a single .so file via arguments: https://stackoverflow.com/a/71221645.
    # So, we are building the monolithic static library instead

    echo
    echo "Generating v8 configuration"
    echo

    COMMON_GEN_ARGS=(
        # disable icu external file to not deal with filesystem
        "icu_use_data_file=false"

        # disable sandbox - not sure 100% if we need it or not, but in the previous version of v8 it was disabled, so disabling it for now
        "v8_enable_sandbox=false"

        # disable internationalization support for now - maybe will need it later
        "v8_enable_i18n_support=false"

        # disable webassembly - we don't use it.
        # disabling it reduces the size of the resulting library:
        #   libv8_monolith.a: 464 308 704 bytes -> 358 764 498 bytes = 105 544 206 bytes smaller ~ 101 MiB smaller = 22.7% smaller
        #   libv8_monolith.so: 23 583 472 bytes -> 18 019 528 bytes = 5 563 944 bytes smaller ~ 5.3 MiB smaller = 23.6% smaller
        "v8_enable_webassembly=false"

        # bundle external data (example: snapshot blob) into the v8 library to not deal with filesystem
        "v8_use_external_startup_data=false"

        # enable more optimizations - according to v8 devs this should be true for every release build shipped to end users
        "is_official_build=true"

        # pgo = profile guided optimizations - these optimizations are turned on when is_official_build=true,
        # but they need special files to optimize code and we don't have those files. So we disable this feature
        "chrome_pgo_phase=0"

        # enables linking time optimizations when set to "true" - it is set to true automatically when is_official_build=true.
        # couldn't make it work due some clang incompatibilities (custom clang 21 is used in v8, but android ndk r28c has clang 19).
        # tried setting "clang_base_path" and "clang_version", but it didn't help, so, disabling for now
        "use_thin_lto=false"

        # enable v8_monolith compilation target which builds a single static library containing the whole v8
        "v8_monolithic=true"

        # use the specific version of android ndk instead of the one bundled with v8
        "android_ndk_root=\"${NDK_DIRECTORY}\""

        # use the standard library from the android ndk instead if the custom one bundled with v8.
        # if we use the bundled one, then we get compilation errors after adding the resulting static library to the project,
        # because those 2 libraries are incompatible with each other.
        # there might be a workaround if we build NOT the static v8 library (.a) but a shared library (.so) instead and bundle the custom standard library into the .so
        # but I haven't tried that yet
        "use_custom_libcxx=false"
    )

    if [[ "${ARG_PLATFORM_BITS}" = "32" ]]; then
        OUT_DIR="arm32.release"
        UNIQUE_GEN_ARGS=()
    else
        OUT_DIR="arm64.release"
        UNIQUE_GEN_ARGS=(
            "target_cpu=\"arm64\""
        )
    fi

    python3 tools/dev/v8gen.py -b android.arm.release "${OUT_DIR}" -- \
        "${COMMON_GEN_ARGS[@]}" \
        "${UNIQUE_GEN_ARGS[@]}"

    echo
    echo "Copying artifacts 1"
    echo

    zip -r "${ARTIFACTS_DIRECTORY}/include.zip" include

    BUILD_FLAGS_ARTIFACT="${ARTIFACTS_DIRECTORY}/v8_build_flags.txt"
    gn desc "out.gn/${OUT_DIR}" //:v8_monolith defines > "${BUILD_FLAGS_ARTIFACT}"
    echo "Build flags:"
    cat "${BUILD_FLAGS_ARTIFACT}"
    echo

    ARGS_GN_ARTIFACT="${ARTIFACTS_DIRECTORY}/args.gn"
    cp "out.gn/${OUT_DIR}/args.gn" "${ARGS_GN_ARTIFACT}"
    echo "args.gn content:"
    cat "${ARGS_GN_ARTIFACT}"
    echo

    GN_ARGS_LIST_ARTIFACT="${ARTIFACTS_DIRECTORY}/gn-args-list.txt"
    gn args "out.gn/${OUT_DIR}" --list > "${GN_ARGS_LIST_ARTIFACT}"
    echo "gn args list:"
    cat "${GN_ARGS_LIST_ARTIFACT}"
    echo

    echo
    echo "Building v8"
    echo

    ninja -C "out.gn/${OUT_DIR}" v8_monolith

    echo
    echo "Copying artifacts 2"
    echo

    cp "out.gn/${OUT_DIR}/obj/libv8_monolith.a" "${ARTIFACTS_DIRECTORY}/libv8_monolith.a"

popd

# "${NDK_DIRECTORY}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android21-clang++" `# check android21 - should match API level` \
#     -shared -o "${ARTIFACTS_DIRECTORY}/libv8_monolith.so" \
#     -Wl,--gc-sections \
#     -Wl,--strip-all \
#     -Wl,--exclude-libs,ALL \
#     -Wl,--whole-archive \
#     "${ARTIFACTS_DIRECTORY}/libv8_monolith.a" \
#     -Wl,--no-whole-archive \
#     -llog -landroid -lm -ldl


# use_sysroot=false
# v8_enable_lite_mode=true - for not jit