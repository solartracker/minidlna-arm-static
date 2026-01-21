#!/bin/sh
################################################################################
# minidlna-arm-musl.sh
#
# Build script for a statically linked version of MiniDLNA media
# server, capable of running on any ARMv7 Linux device.
#
# MiniDLNA (also known as ReadyMedia) is a lightweight, simple-to-configure
# media server that implements the DLNA/UPnP-AV standard. It allows you to
# stream music, videos, and photos from a Linux-based device, such as a
# Raspberry Pi, to DLNA-compatible clients like smart TVs, game consoles, or
# media players.
#
# NOTE: Compiling MiniDLNA (and especially FFmpeg) on a Raspberry Pi can
# generate significant heat, often exceeding 80°C in stock cases. Upgrading to
# an aluminum case with copper shims and good thermal paste provides effective
# passive cooling that dramatically improves heat dissipation, keeping CPU
# temperatures below 50°C and preventing thermal throttling during long builds.
#
# Copyright (C) 2025 Richard Elwell
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
################################################################################
PATH_CMD="$(readlink -f -- "$0")"
SCRIPT_DIR="$(dirname -- "$(readlink -f -- "$0")")"
PARENT_DIR="$(dirname -- "$(dirname -- "$(readlink -f -- "$0")")")"
CACHED_DIR="${PARENT_DIR}/solartracker-sources"
set -e
set -x

################################################################################
# Helpers

# If autoconf/configure fails due to missing libraries or undefined symbols, you
# immediately see all undefined references without having to manually search config.log
handle_configure_error() {
    local rc=$1

    #grep -R --include="config.log" --color=always "undefined reference" .
    #find . -name "config.log" -exec grep -H "undefined reference" {} \;
    #find . -name "config.log" -exec grep -H -E "undefined reference|can't load library|unrecognized command-line option|No such file or directory" {} \;
    find . -name "config.log" -exec grep -H -E "undefined reference|can't load library|unrecognized command-line option" {} \;

    # Force failure if rc is zero, since error was detected
    [ "${rc}" -eq 0 ] && return 1

    return ${rc}
}

################################################################################
# Package management

# new files:       rw-r--r-- (644)
# new directories: rwxr-xr-x (755)
umask 022

sign_file()
( # BEGIN sub-shell
    [ -n "$1" ]            || return 1

    local target_path="$1"
    local option="$2"
    local sign_path="$(readlink -f "${target_path}").sha256"
    local target_file="$(basename -- "${target_path}")"
    local target_file_hash=""
    local temp_path=""
    local now_localtime=""

    if [ ! -f "${target_path}" ]; then
        echo "ERROR: File not found: ${target_path}"
        return 1
    fi

    if [ -z "${option}" ]; then
        target_file_hash="$(sha256sum "${target_path}" | awk '{print $1}')"
    elif [ "${option}" == "tar_extract" ]; then
        target_file_hash="$(tar -xJOf "${target_path}" | sha256sum | awk '{print $1}')"
    elif [ "${option}" == "xz_extract" ]; then
        target_file_hash="$(xz -dc "${target_path}" | sha256sum | awk '{print $1}')"
    else
        return 1
    fi

    now_localtime="$(date '+%Y-%m-%d %H:%M:%S %Z %z')"

    cleanup() { rm -f "${temp_path}"; }
    trap 'cleanup; exit 130' INT
    trap 'cleanup; exit 143' TERM
    trap 'cleanup' EXIT
    temp_path=$(mktemp "${sign_path}.XXXXXX")
    {
        #printf '%s released %s\n' "${target_file}" "${now_localtime}"
        #printf '\n'
        #printf 'SHA256: %s\n' "${target_file_hash}"
        #printf '\n'
        printf '%s  %s\n' "${target_file_hash}" "${target_file}"
    } >"${temp_path}" || return 1
    touch -r "${target_path}" "${temp_path}" || return 1
    mv -f "${temp_path}" "${sign_path}" || return 1
    # TODO: implement signing
    trap - EXIT INT TERM

    return 0
) # END sub-shell

# Checksum verification for downloaded file
verify_hash() {
    [ -n "$1" ] || return 1

    local file_path="$1"
    local expected="$2"
    local option="$3"
    local actual=""
    local sign_path="$(readlink -f "${file_path}").sha256"
    local line=""

    if [ ! -f "${file_path}" ]; then
        echo "ERROR: File not found: ${file_path}"
        return 1
    fi

    if [ -z "${option}" ]; then
        # hash the compressed binary file. this method is best when downloading
        # compressed binary files.
        actual="$(sha256sum "${file_path}" | awk '{print $1}')"
    elif [ "${option}" == "tar_extract" ]; then
        # hash the data, file names, directory names. this method is best when
        # archiving Github repos.
        actual="$(tar -xJOf "${file_path}" | sha256sum | awk '{print $1}')"
    elif [ "${option}" == "xz_extract" ]; then
        # hash the data, file names, directory names, timestamps, permissions, and
        # tar internal structures. this method is not as "future-proof" for archiving
        # Github repos because it is possible that the tar internal structures
        # could change over time as the tar implementations evolve.
        actual="$(xz -dc "${file_path}" | sha256sum | awk '{print $1}')"
    else
        return 1
    fi

    if [ -z "${expected}" ]; then
        if [ ! -f "${sign_path}" ]; then
            echo "ERROR: Signature file not found: ${sign_path}"
            return 1
        else
            # TODO: implement signature verify
            IFS= read -r line <"${sign_path}" || return 1
            expected=${line%%[[:space:]]*}
            if [ -z "${expected}" ]; then
                echo "ERROR: Bad signature file: ${sign_path}"
                return 1
            fi
        fi
    fi

    if [ "${actual}" != "${expected}" ]; then
        echo "ERROR: SHA256 mismatch for ${file_path}"
        echo "Expected: ${expected}"
        echo "Actual:   ${actual}"
        return 1
    fi

    echo "SHA256 OK: ${file_path}"
    return 0
}

# the signature file is just a checksum hash
signature_file_exists() {
    [ -n "$1" ] || return 1
    local file_path="$1"
    local sign_path="$(readlink -f "${file_path}").sha256"
    if [ -f "${sign_path}" ]; then
        return 0
    else
        return 1
    fi
}

retry() {
    local max=$1
    shift
    local i=1
    while :; do
        if ! "$@"; then
            if [ "${i}" -ge "${max}" ]; then
                return 1
            fi
            i=$((i + 1))
            sleep 10
        else
            return 0
        fi
    done
}

wget_clean() {
    [ -n "$1" ]          || return 1
    [ -n "$2" ]          || return 1
    [ -n "$3" ]          || return 1

    local temp_path="$1"
    local source_url="$2"
    local target_path="$3"

    rm -f "${temp_path}"
    if ! wget -O "${temp_path}" --tries=9 --retry-connrefused --waitretry=5 "${source_url}"; then
        rm -f "${temp_path}"
        return 1
    else
        if ! mv -f "${temp_path}" "${target_path}"; then
            rm -f "${temp_path}" "${target_path}"
            return 1
        fi
    fi

    return 0
}

download()
( # BEGIN sub-shell
    [ -n "$1" ]            || return 1
    [ -n "$2" ]            || return 1
    [ -n "$3" ]            || return 1
    [ -n "${CACHED_DIR}" ] || return 1

    local source_url="$1"
    local source="$2"
    local target_dir="$3"
    local cached_path="${CACHED_DIR}/${source}"
    local target_path="${target_dir}/${source}"
    local temp_path=""

    if [ ! -f "${cached_path}" ]; then
        mkdir -p "${CACHED_DIR}"
        if [ ! -f "${target_path}" ]; then
            cleanup() { rm -f "${cached_path}" "${temp_path}"; }
            trap 'cleanup; exit 130' INT
            trap 'cleanup; exit 143' TERM
            trap 'cleanup' EXIT
            temp_path=$(mktemp "${cached_path}.XXXXXX")
            if ! retry 100 wget_clean "${temp_path}" "${source_url}" "${cached_path}"; then
                return 1
            fi
            trap - EXIT INT TERM
        else
            cleanup() { rm -f "${cached_path}"; }
            trap 'cleanup; exit 130' INT
            trap 'cleanup; exit 143' TERM
            trap 'cleanup' EXIT
            if ! mv -f "${target_path}" "${cached_path}"; then
                return 1
            fi
            trap - EXIT INT TERM
        fi
    fi

    if [ ! -f "${target_path}" ]; then
        if [ -f "${cached_path}" ]; then
            ln -sfn "${cached_path}" "${target_path}"
        fi
    fi

    return 0
) # END sub-shell

clone_github()
( # BEGIN sub-shell
    [ -n "$1" ]            || return 1
    [ -n "$2" ]            || return 1
    [ -n "$3" ]            || return 1
    [ -n "$4" ]            || return 1
    [ -n "$5" ]            || return 1
    [ -n "${CACHED_DIR}" ] || return 1

    local source_url="$1"
    local source_version="$2"
    local source_subdir="$3"
    local source="$4"
    local target_dir="$5"
    local cached_path="${CACHED_DIR}/${source}"
    local target_path="${target_dir}/${source}"
    local temp_path=""
    local temp_dir=""
    local timestamp=""

    if [ ! -f "${cached_path}" ]; then
        umask 022
        mkdir -p "${CACHED_DIR}"
        if [ ! -f "${target_path}" ]; then
            cleanup() { rm -rf "${temp_path}" "${temp_dir}"; }
            trap 'cleanup; exit 130' INT
            trap 'cleanup; exit 143' TERM
            trap 'cleanup' EXIT
            temp_path=$(mktemp "${cached_path}.XXXXXX")
            temp_dir=$(mktemp -d "${target_dir}/temp.XXXXXX")
            mkdir -p "${temp_dir}"
            if ! retry 100 git clone "${source_url}" "${temp_dir}/${source_subdir}"; then
                return 1
            fi
            cd "${temp_dir}/${source_subdir}"
            if ! retry 100 git checkout ${source_version}; then
                return 1
            fi
            if ! retry 100 git submodule update --init --recursive; then
                return 1
            fi
            timestamp="$(git log -1 --format='@%ct')"
            rm -rf .git
            cd ../..
            #chmod -R g-w,o-w "${temp_dir}/${source_subdir}"
            if ! tar --numeric-owner --owner=0 --group=0 --sort=name --mtime="${timestamp}" \
                    -C "${temp_dir}" "${source_subdir}" \
                    -cv | xz -zc -7e -T0 >"${temp_path}"; then
                return 1
            fi
            touch -d "${timestamp}" "${temp_path}" || return 1
            mv -f "${temp_path}" "${cached_path}" || return 1
            rm -rf "${temp_dir}" || return 1
            trap - EXIT INT TERM
            sign_file "${cached_path}"
        else
            cleanup() { rm -f "${cached_path}"; }
            trap 'cleanup; exit 130' INT
            trap 'cleanup; exit 143' TERM
            trap 'cleanup' EXIT
            mv -f "${target_path}" "${cached_path}" || return 1
            trap - EXIT INT TERM
        fi
    fi

    if [ ! -f "${target_path}" ]; then
        if [ -f "${cached_path}" ]; then
            ln -sfn "${cached_path}" "${target_path}"
        fi
    fi

    return 0
) # END sub-shell

download_archive() {
    [ "$#" -eq 3 ] || [ "$#" -eq 5 ] || return 1

    local source_url="$1"
    local source="$2"
    local target_dir="$3"
    local source_version="$4"
    local source_subdir="$5"

    if [ -z "${source_version}" ]; then
        download "${source_url}" "${source}" "${target_dir}"
    else
        clone_github "${source_url}" "${source_version}" "${source_subdir}" "${source}" "${target_dir}"
    fi
}

apply_patch() {
    [ -n "$1" ] || return 1
    [ -n "$2" ] || return 1

    local patch_path="$1"
    local target_dir="$2"

    if [ -f "${patch_path}" ]; then
        echo "Applying patch: ${patch_path}"
        if patch --dry-run --silent -p1 -d "${target_dir}/" -i "${patch_path}"; then
            if ! patch -p1 -d "${target_dir}/" -i "${patch_path}"; then
                echo "The patch failed."
                return 1
            fi
        else
            echo "The patch was not applied. Failed dry run."
            return 1
        fi
    else
        echo "Patch not found: ${patch_path}"
        return 1
    fi

    return 0
}

apply_patch_folder() {
    [ -n "$1" ] || return 1
    [ -n "$2" ] || return 1

    local patch_dir="$1"
    local target_dir="$2"
    local patch_file=""
    local rc=0

    if [ -d "${patch_dir}" ]; then
        for patch_file in ${patch_dir}/*.patch; do
            if [ -f "${patch_file}" ]; then
                if ! apply_patch "${patch_file}" "${target_dir}"; then
                    rc=1
                fi
            fi
        done
    fi

    return ${rc}
}

rm_safe() {
    [ -n "$1" ] || return 1
    local target_dir="$1"

    # Prevent absolute paths
    case "${target_dir}" in
        /*)
            echo "Refusing to remove absolute path: ${target_dir}"
            return 1
            ;;
    esac

    # Prevent current/parent directories
    case "${target_dir}" in
        "."|".."|*/..|*/.)
            echo "Refusing to remove . or .. or paths containing ..: ${target_dir}"
            return 1
            ;;
    esac

    # Finally, remove safely
    rm -rf -- "${target_dir}"

    return 0
}

apply_patches() {
    [ -n "$1" ] || return 1
    [ -n "$2" ] || return 1

    local patch_dir="$1"
    local target_dir="$2"

    if ! apply_patch_folder "${patch_dir}" "${target_dir}"; then
        #rm_safe "${target_dir}"
        return 1
    fi

    return 0
}

extract_package() {
    [ -n "$1" ] || return 1
    [ -n "$2" ] || return 1

    local source_path="$1"
    local target_dir="$2"

    case "${source_path}" in
        *.tar.gz|*.tgz)
            tar xzvf "${source_path}" -C "${target_dir}" || return 1
            ;;
        *.tar.bz2|*.tbz)
            tar xjvf "${source_path}" -C "${target_dir}" || return 1
            ;;
        *.tar.xz|*.txz)
            tar xJvf "${source_path}" -C "${target_dir}" || return 1
            ;;
        *.tar.lz|*.tlz)
            tar xlvf "${source_path}" -C "${target_dir}" || return 1
            ;;
        *.tar.zst)
            tar xvf "${source_path}" -C "${target_dir}" || return 1
            ;;
        *.tar)
            tar xvf "${source_path}" -C "${target_dir}" || return 1
            ;;
        *)
            echo "Unsupported archive type: ${source_path}" >&2
            return 1
            ;;
    esac

    return 0
}

unpack_archive()
( # BEGIN sub-shell
    [ -n "$1" ] || return 1
    [ -n "$2" ] || return 1

    local source_path="$1"
    local target_dir="$2"
    local dir_tmp=""

    if [ ! -d "${target_dir}" ]; then
        cleanup() { rm -rf "${dir_tmp}" "${target_dir}"; }
        trap 'cleanup; exit 130' INT
        trap 'cleanup; exit 143' TERM
        trap 'cleanup' EXIT
        dir_tmp=$(mktemp -d "${target_dir}.XXXXXX")
        mkdir -p "${dir_tmp}"
        if ! extract_package "${source_path}" "${dir_tmp}"; then
            return 1
        else
            # try to rename single sub-directory
            if ! mv -f "${dir_tmp}"/* "${target_dir}"/; then
                # otherwise, move multiple files and sub-directories
                mkdir -p "${target_dir}" || return 1
                mv -f "${dir_tmp}"/* "${target_dir}"/ || return 1
            fi
        fi
        rm -rf "${dir_tmp}" || return 1
        trap - EXIT INT TERM
    fi

    return 0
) # END sub-shell

get_latest_package() {
    [ "$#" -eq 3 ] || return 1

    local prefix=$1
    local middle=$2
    local suffix=$3
    local pattern=${prefix}${middle}${suffix}
    local latest=""
    local version=""

    (
        cd "$CACHED_DIR" || return 1

        set -- $pattern
        [ "$1" != "$pattern" ] || return 1   # no matches

        latest=$1
        for f do
            latest=$f
        done

        version=${latest#"$prefix"}
        version=${version%"$suffix"}
        printf '%s\n' "$version"
    )
    return 0
}

is_version_git() {
    case "$1" in
        *+git*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

update_patch_library() {
    [ -n "$1" ]            || return 1
    [ -n "$2" ]            || return 1
    [ -n "$3" ]            || return 1
    [ -n "$4" ]            || return 1
    [ -n "${PARENT_DIR}" ] || return 1
    [ -n "${SCRIPT_DIR}" ] || return 1

    local git_commit="$1"
    local patches_dir="$2"
    local pkg_name="$3"
    local pkg_subdir="$4"
    local entware_packages_dir="${PARENT_DIR}/entware-packages"

    if [ ! -d "${entware_packages_dir}" ]; then
        cd "${PARENT_DIR}"
        git clone https://github.com/Entware/entware-packages
    fi

    cd "${entware_packages_dir}"
    git fetch origin
    git reset --hard "${git_commit}"
    [ -d "${patches_dir}" ] || return 1
    mkdir -p "${SCRIPT_DIR}/patches/${pkg_name}/${pkg_subdir}/entware"
    cp -pf "${patches_dir}"/* "${SCRIPT_DIR}/patches/${pkg_name}/${pkg_subdir}/entware/"
    cd ..

    return 0
}

check_static() {
    local rc=0
    for bin in "$@"; do
        echo "Checking ${bin}"
        file "${bin}" || true
        if ${CROSS_PREFIX}readelf -d "${bin}" 2>/dev/null | grep NEEDED; then
            rc=1
        fi || true
        "${LDD}" "${bin}" 2>&1 || true
    done

    if [ ${rc} -eq 1 ]; then
        echo "*** NOT STATICALLY LINKED ***"
        echo "*** NOT STATICALLY LINKED ***"
        echo "*** NOT STATICALLY LINKED ***"
    fi

    return ${rc}
}

finalize_build() {
    set +x
    echo ""
    echo "Stripping symbols and sections from files..."
    ${CROSS_PREFIX}strip -v "$@"

    # Exit here, if the programs are not statically linked.
    # If any binaries are not static, check_static() returns 1
    # set -e will cause the shell to exit here, so renaming won't happen below.
    echo ""
    echo "Checking statically linked programs..."
    check_static "$@"

    # Append ".static" to the program names
    echo ""
    echo "Create symbolic link with .static suffix..."
    for bin in "$@"; do
        case "$bin" in
            *.static) : ;;   # do nothing
            *) ln -sfn "$(basename "${bin}")" "${bin}.static" ;;
        esac
    done
    set -x

    return 0
}


################################################################################
# Install the build environment
# ARM Linux musl Cross-Compiler v0.2.0
#
CROSSBUILD_SUBDIR="cross-arm-linux-musleabi-build"
CROSSBUILD_DIR="${PARENT_DIR}/${CROSSBUILD_SUBDIR}"
export TARGET=arm-linux-musleabi
(
PKG_NAME=cross-arm-linux-musleabi
HOST_CPU="$(uname -m)"
get_latest() { get_latest_package "${PKG_NAME}-${HOST_CPU}-" "??????????????" ".tar.xz"; }
#PKG_VERSION="$(get_latest)" # this line will fail if you did not build a toolchain yourself
PKG_VERSION=0.2.0 # this line will cause a toolchain to be downloaded from Github
PKG_SOURCE="${PKG_NAME}-${HOST_CPU}-${PKG_VERSION}.tar.xz"
PKG_SOURCE_URL="https://github.com/solartracker/${PKG_NAME}/releases/download/${PKG_VERSION}/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_SOURCE_PATH="${CACHED_DIR}/${PKG_SOURCE}"

if signature_file_exists "${PKG_SOURCE_PATH}"; then
    # use an archived toolchain that you built yourself, along with a signature
    # file that was created automatically.  the version number is a 14 digit
    # timestamp and a symbolic link was automatically created for the release
    # asset that would normally have been downloaded. all this is done for you
    # by the toolchain build script: build-arm-linux-musleabi.sh
    #
    # Example of what your sources directory might look like:
    # cross-arm-linux-musleabi-armv7l-20260120150840.tar.xz
    # cross-arm-linux-musleabi-armv7l-20260120150840.tar.xz.sha256
    # cross-arm-linux-musleabi-armv7l-0.2.0.tar.xz -> cross-arm-linux-musleabi-armv7l-20260120150840.tar.xz
    # cross-arm-linux-musleabi-armv7l-0.2.0.tar.xz.sha256 -> cross-arm-linux-musleabi-armv7l-20260120150840.tar.xz.sha256
    #
    PKG_HASH=""
else
    # alternatively, the toolchain can be downloaded from Github. note that the version
    # number is the Github tag, instead of a 14 digit timestamp.
    case "${HOST_CPU}" in
        armv7l)
            # cross-arm-linux-musleabi-armv7l-0.2.0.tar.xz
            PKG_HASH="db200a801420d21b5328c9005225bb0fa822b612c6b67b3da58c397458238634"
            ;;
        x86_64)
            # cross-arm-linux-musleabi-x86_64-0.2.0.tar.xz
            PKG_HASH="9a303a9978ff8d590394bccf2a03890ccb129916347dcdd66dc7780ea7826d9b"
            ;;
        *)
            echo "Unsupported CPU architecture: "${HOST_CPU} >&2
            exit 1
            ;;
    esac
fi

# Check if toolchain exists and install it, if needed
if [ ! -d "${CROSSBUILD_DIR}" ]; then
    echo "Toolchain not found at ${CROSSBUILD_DIR}. Installing..."
    echo ""
    cd ${PARENT_DIR}
    download_archive "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "${CACHED_DIR}"
    verify_hash "${PKG_SOURCE_PATH}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE_PATH}" "${CROSSBUILD_DIR}"
fi

# Check for required toolchain tools
if [ ! -x "${CROSSBUILD_DIR}/bin/${TARGET}-gcc" ]; then
    echo "ERROR: Toolchain installation appears incomplete."
    echo "Missing ${TARGET}-gcc in ${CROSSBUILD_DIR}/bin"
    echo ""
    exit 1
fi
if [ ! -x "${CROSSBUILD_DIR}/${TARGET}/lib/libc.so" ]; then
    echo "ERROR: Toolchain installation appears incomplete."
    echo "Missing libc.so in ${CROSSBUILD_DIR}/${TARGET}/lib"
    echo ""
    exit 1
fi
)


################################################################################
# General

PKG_ROOT=minidlna

MINIDLNA_THUMBNAILS_ENABLED=true # enabling increases file size by about 2MB

export PREFIX="${CROSSBUILD_DIR}"
export HOST=${TARGET}
export SYSROOT="${PREFIX}/${TARGET}"
export PATH="${PATH}:${PREFIX}/bin:${SYSROOT}/bin"

CROSS_PREFIX=${TARGET}-
export CC=${CROSS_PREFIX}gcc
export AR=${CROSS_PREFIX}ar
export RANLIB=${CROSS_PREFIX}ranlib
export STRIP=${CROSS_PREFIX}strip

export LDFLAGS="-L${PREFIX}/lib -Wl,--gc-sections"
export CPPFLAGS="-I${PREFIX}/include -D_GNU_SOURCE"
CFLAGS_COMMON="-O3 -march=armv7-a -mtune=cortex-a9 -marm -mfloat-abi=soft -mabi=aapcs-linux -fomit-frame-pointer -ffunction-sections -fdata-sections -pipe -Wall -fPIC"
export CFLAGS="${CFLAGS_COMMON} -std=gnu99"
export CXXFLAGS="${CFLAGS_COMMON} -std=gnu++17"

case "${HOST_CPU}" in
    armv7l)
        LDD="${SYSROOT}/lib/libc.so --list"
        ;;
    *)
        LDD="ldd"
        ;;
esac

#STAGEDIR="${CROSSBUILD_DIR}"
#mkdir -p "${STAGEDIR}"
SRC_ROOT="${CROSSBUILD_DIR}/src/${PKG_ROOT}"
mkdir -p "${SRC_ROOT}"

MAKE="make -j$(grep -c ^processor /proc/cpuinfo)" # parallelism
#MAKE="make -j1"                                  # one job at a time

export PKG_CONFIG="pkg-config"
export PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig"
unset PKG_CONFIG_PATH


################################################################################
# zlib-1.3.1
(
PKG_NAME=zlib
PKG_VERSION=1.3.1
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.xz"
PKG_SOURCE_URL="https://github.com/madler/zlib/releases/download/v${PKG_VERSION}/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_HASH="38ef96b8dfe510d42707d9c781877914792541133e1870841463bfa73f883e32"

mkdir -p "${SRC_ROOT}/${PKG_NAME}"
cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_SOURCE_SUBDIR}/__package_installed" ]; then
    rm -rf "${PKG_SOURCE_SUBDIR}"
    download_archive "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"
    cd "${PKG_SOURCE_SUBDIR}"

    ./configure \
        --static \
        --prefix="${PREFIX}" \
    || handle_configure_error $?

    $MAKE
    make install

    touch __package_installed
fi
)

################################################################################
# bzip2-1.0.8
(
PKG_NAME=bzip2
PKG_VERSION=1.0.8
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.gz"
PKG_SOURCE_URL="https://sourceware.org/pub/${PKG_NAME}/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_HASH="ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269"

mkdir -p "${SRC_ROOT}/${PKG_NAME}"
cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_SOURCE_SUBDIR}/__package_installed" ]; then
    rm -rf "${PKG_SOURCE_SUBDIR}"
    download_archive "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"
    cd "${PKG_SOURCE_SUBDIR}"

    export CFLAGS="${CFLAGS} -static"

    make distclean || true

    $MAKE \
        CC="$CC" \
        AR="$AR" \
        RANLIB="$RANLIB" \
        CFLAGS="$CFLAGS" \
        bzip2 bzip2recover libbz2.a

    make install PREFIX="${PREFIX}"

    finalize_build \
        "${PREFIX}/bin/bzip2" \
        "${PREFIX}/bin/bunzip2" \
        "${PREFIX}/bin/bzcat" \
        "${PREFIX}/bin/bzip2recover"

    touch __package_installed
fi
)

################################################################################
# SQLite 3.51.2
(
PKG_NAME=sqlite-autoconf
PKG_VERSION=3510200
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.gz"
PKG_SOURCE_URL="https://sqlite.org/2026/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_HASH="fbd89f866b1403bb66a143065440089dd76100f2238314d92274a082d4f2b7bb"

mkdir -p "${SRC_ROOT}/${PKG_NAME}"
cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_SOURCE_SUBDIR}/__package_installed" ]; then
    rm -rf "${PKG_SOURCE_SUBDIR}"
    download "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"
    cd "${PKG_SOURCE_SUBDIR}"

    ./configure \
        --prefix="${PREFIX}" \
        --host="${HOST}" \
        --disable-shared \
        --enable-static \
        --disable-rpath \
    || handle_configure_error $?

    $MAKE
    make install

    touch __package_installed
fi
)

################################################################################
# libogg-1.3.6
(
PKG_NAME=libogg
PKG_VERSION=1.3.6
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.gz"
PKG_SOURCE_URL="https://ftp.osuosl.org/pub/xiph/releases/ogg/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_HASH="83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638"

mkdir -p "${SRC_ROOT}/${PKG_NAME}"
cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_SOURCE_SUBDIR}/__package_installed" ]; then
    rm -rf "${PKG_SOURCE_SUBDIR}"
    download "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"
    cd "${PKG_SOURCE_SUBDIR}"

    ./configure \
        --enable-static \
        --disable-shared \
        --prefix="${PREFIX}" \
        --host="${HOST}" \
    || handle_configure_error $?

    $MAKE
    make install

    touch __package_installed
fi
)

################################################################################
# libvorbis-1.3.7
(
PKG_NAME=libvorbis
PKG_VERSION=1.3.7
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.gz"
PKG_SOURCE_URL="https://ftp.osuosl.org/pub/xiph/releases/vorbis/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_HASH="0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab"

mkdir -p "${SRC_ROOT}/${PKG_NAME}"
cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_SOURCE_SUBDIR}/__package_installed" ]; then
    download "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"
    cd "${PKG_SOURCE_SUBDIR}"

    ./configure \
        --enable-static \
        --disable-shared \
        --disable-oggtest \
        --prefix="${PREFIX}" \
        --host="${HOST}" \
    || handle_configure_error $?

    $MAKE
    make install

    touch __package_installed
fi
)

################################################################################
# flac-1.5.0
(
PKG_NAME=flac
PKG_VERSION=1.5.0
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.xz"
PKG_SOURCE_URL="https://ftp.osuosl.org/pub/xiph/releases/flac/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_HASH="f2c1c76592a82ffff8413ba3c4a1299b6c7ab06c734dee03fd88630485c2b920"

mkdir -p "${SRC_ROOT}/${PKG_NAME}"
cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_SOURCE_SUBDIR}/__package_installed" ]; then
    rm -rf "${PKG_SOURCE_SUBDIR}"
    download "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"
    cd "${PKG_SOURCE_SUBDIR}"

    ./configure \
        --enable-static \
        --disable-shared \
        --disable-rpath \
        --disable-doxygen-docs \
        --disable-cpplibs \
        --disable-avx \
        --disable-stack-smash-protection \
        --disable-oggtest \
        --disable-examples \
        --without-libiconv-prefix \
        --prefix="${PREFIX}" \
        --host="${HOST}" \
    || handle_configure_error $?

    $MAKE
    make install

    touch __package_installed
fi
)

################################################################################
# libid3tag-0.15.1b
(
PKG_NAME=libid3tag
PKG_VERSION=0.15.1b
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.gz"
PKG_SOURCE_URL="https://downloads.sourceforge.net/project/mad/libid3tag/${PKG_VERSION}/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_HASH="63da4f6e7997278f8a3fef4c6a372d342f705051d1eeb6a46a86b03610e26151"

mkdir -p "${SRC_ROOT}/${PKG_NAME}"
cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_SOURCE_SUBDIR}/__package_installed" ]; then
    rm -rf "${PKG_SOURCE_SUBDIR}"
    download "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"
    cd "${PKG_SOURCE_SUBDIR}"
    cp -p "${SCRIPT_DIR}/files/${PKG_NAME}/${PKG_SOURCE_SUBDIR}/solartracker/config.guess" "./"
    cp -p "${SCRIPT_DIR}/files/${PKG_NAME}/${PKG_SOURCE_SUBDIR}/solartracker/config.sub" "./"

    ./configure \
        --enable-static \
        --disable-shared \
        --disable-rpath \
        --disable-debugging \
        --disable-profiling \
        --disable-dependency-tracking \
        --prefix="${PREFIX}" \
        --host="${HOST}" \
    || handle_configure_error $?

    $MAKE
    make install

    touch __package_installed
fi
)

################################################################################
# libexif-0.6.25
(
PKG_NAME=libexif
PKG_VERSION=0.6.25
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.gz"
PKG_SOURCE_URL="https://github.com/libexif/libexif/releases/download/v${PKG_VERSION}/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_HASH="16fdfa59cf9d301a9ccd5c1bc2fe05c78ee0ee2bf96e39640039e3dc0fd593cb"

mkdir -p "${SRC_ROOT}/${PKG_NAME}"
cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_SOURCE_SUBDIR}/__package_installed" ]; then
    rm -rf "${PKG_SOURCE_SUBDIR}"
    download "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"
    cd "${PKG_SOURCE_SUBDIR}"

    ./configure \
        --enable-static \
        --disable-shared \
        --disable-nls \
        --disable-docs \
        --disable-rpath \
        --without-libiconv-prefix \
        --without-libintl-prefix \
        --prefix="${PREFIX}" \
        --host="${HOST}" \
    || handle_configure_error $?

    $MAKE
    make install

    touch __package_installed
fi
)

################################################################################
# jpeg-9f
(
PKG_NAME=jpeg
PKG_VERSION=9f
PKG_SOURCE="${PKG_NAME}src.v${PKG_VERSION}.tar.gz"
PKG_SOURCE_URL="https://www.ijg.org/files/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_HASH="04705c110cb2469caa79fb71fba3d7bf834914706e9641a4589485c1f832565b"

mkdir -p "${SRC_ROOT}/${PKG_NAME}"
cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_SOURCE_SUBDIR}/__package_installed" ]; then
    rm -rf "${PKG_SOURCE_SUBDIR}"
    download "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"
    cd "${PKG_SOURCE_SUBDIR}"

    ./configure \
        --enable-static \
        --disable-shared \
        --enable-maxmem=1 \
        --prefix="${PREFIX}" \
        --host="${HOST}" \
    || handle_configure_error $?

    $MAKE
    make install

    touch __package_installed
fi
)

################################################################################
# libpng-1.6.53
(
if $MINIDLNA_THUMBNAILS_ENABLED; then
PKG_NAME=libpng
PKG_VERSION=1.6.53
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.xz"
PKG_SOURCE_URL="https://downloads.sourceforge.net/project/libpng/libpng16/${PKG_VERSION}/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_HASH="1d3fb8ccc2932d04aa3663e22ef5ef490244370f4e568d7850165068778d98d4"

mkdir -p "${SRC_ROOT}/${PKG_NAME}"
cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_SOURCE_SUBDIR}/__package_installed" ]; then
    rm -rf "${PKG_SOURCE_SUBDIR}"
    download "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"
    cd "${PKG_SOURCE_SUBDIR}"

    ./configure \
        --enable-static \
        --disable-shared \
        --disable-tests \
        --disable-tools \
        --disable-hardware-optimizations \
        --prefix="${PREFIX}" \
        --host="${HOST}" \
    || handle_configure_error $?

    $MAKE
    make install

    touch __package_installed
fi
fi
)

################################################################################
# ffmpeg-6.1.2
(
PKG_NAME=ffmpeg
PKG_VERSION=6.1.2
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.gz"
PKG_SOURCE_URL="https://ffmpeg.org/releases/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_HASH="def310d21e40c39e6971a6bcd07fba78ca3ce39cc01ffda4dca382599dc06312"

mkdir -p "${SRC_ROOT}/${PKG_NAME}"
cd "${SRC_ROOT}/${PKG_NAME}"

ffmpeg_options() {
    [ -n "$1" ] || return 1
    [ -n "$2" ] || return 1
    local v
    for v in $2; do printf -- "%s=%s " $1 $v; done
    return 0
}

ffmpeg_enable() {
    [ -n "$1" ] || return 1
    [ -n "$2" ] || return 1
    local p n
    $2 && p=enable || p=disable
    for n in $1; do printf -- "--%s-%s " "$p" "$n"; done
    return 0
}

if [ ! -f "${PKG_SOURCE_SUBDIR}/__package_installed" ]; then
    rm -rf "${PKG_SOURCE_SUBDIR}"
    download "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"
    cd "${PKG_SOURCE_SUBDIR}"

    if ${MINIDLNA_THUMBNAILS_ENABLED}; then
        apply_patches "${SCRIPT_DIR}/patches/${PKG_NAME}/${PKG_SOURCE_SUBDIR}/entware" "."
    fi

    FFMPEG_DECODERS="aac ac3 atrac3 h264 jpegls mp3 mpeg1video mpeg2video mpeg4 mpegvideo png wmav1 wmav2 svq3"
    FFMPEG_PARSERS="aac ac3 h264 mpeg4video mpegaudio mpegvideo"
    FFMPEG_PROTOCOLS="file"
    FFMPEG_DISABLED_DEMUXERS="amr apc ape ass bethsoftvid bfi c93 daud dnxhd dsicin dxa gsm gxf idcin iff image2 image2pipe ingenient ipmovie lmlm4 mm mmf msnwc_tcp mtv mxf nsv nut oma pva rawvideo rl2 roq rpl segafilm shorten siff smacker sol str thp tiertexseq tta txd vmd voc wc3 wsaud wsvqa xa yuv4mpegpipe"

    ./configure \
        --arch=arm --target-os=linux --disable-neon --disable-vfp --disable-asm \
        --enable-cross-compile --cross-prefix=${CROSS_PREFIX} --sysroot="${SYSROOT}" \
        --enable-static --disable-shared --disable-rpath --disable-debug --disable-doc \
        --enable-gpl --enable-version3 --enable-nonfree \
        --enable-pthreads --enable-small \
        $(ffmpeg_enable "avfilter swscale" $MINIDLNA_THUMBNAILS_ENABLED) \
        --disable-ffmpeg --disable-ffplay --disable-ffprobe \
        --disable-encoders --disable-filters --disable-muxers --disable-devices \
        --disable-avdevice --disable-hwaccels --disable-network --disable-bsfs \
        --enable-demuxers $(ffmpeg_options "--disable-demuxer" "$FFMPEG_DISABLED_DEMUXERS") \
        --disable-decoders $(ffmpeg_options "--enable-decoder" "$FFMPEG_DECODERS") \
        --disable-parsers $(ffmpeg_options "--enable-parser" "$FFMPEG_PARSERS") \
        --disable-protocols $(ffmpeg_options "--enable-protocol" "$FFMPEG_PROTOCOLS") \
        --enable-zlib \
        --prefix="${PREFIX}" \
    || handle_configure_error $?

    $MAKE
    make install

    touch __package_installed
fi
)

################################################################################
# ffmpegthumbnailer-2.2.3
(
if $MINIDLNA_THUMBNAILS_ENABLED; then
PKG_NAME=ffmpegthumbnailer
PKG_VERSION=2.2.3
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.gz"
PKG_SOURCE_URL="https://github.com/dirkvdb/ffmpegthumbnailer/archive/refs/tags/${PKG_VERSION}.tar.gz"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_HASH="8c9b9057c6cc8bce9d11701af224c8139c940f734c439a595525e073b09d19b8"

mkdir -p "${SRC_ROOT}/${PKG_NAME}"
cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_SOURCE_SUBDIR}/__package_installed" ]; then
    rm -rf "${PKG_SOURCE_SUBDIR}"
    download "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"
    cd "${PKG_SOURCE_SUBDIR}"

    apply_patches "${SCRIPT_DIR}/patches/${PKG_NAME}/${PKG_SOURCE_SUBDIR}/solartracker" "."

    {
        printf '%s\n' "# toolchain.cmake"
        printf '%s\n' "set(CMAKE_SYSTEM_NAME Linux)"
        printf '%s\n' "set(CMAKE_SYSTEM_PROCESSOR arm)"
        printf '%s\n' ""
        printf '%s\n' "# Cross-compiler"
        printf '%s\n' "set(CMAKE_C_COMPILER   \"${PREFIX}/bin/${CROSS_PREFIX}gcc\")"
        printf '%s\n' "set(CMAKE_CXX_COMPILER \"${PREFIX}/bin/${CROSS_PREFIX}g++\")"
        printf '%s\n' ""
        printf '%s\n' "# Optional: sysroot"
        printf '%s\n' "set(CMAKE_SYSROOT \"${PREFIX}\")"
        printf '%s\n' ""
        printf '%s\n' "# Ensure proper float ABI"
        printf '%s\n' "set(CMAKE_C_FLAGS \"${CFLAGS}\")"
        printf '%s\n' "set(CMAKE_CXX_FLAGS \"\${CMAKE_C_FLAGS}\")"
        printf '%s\n' ""
        printf '%s\n' "# Avoid picking host libraries"
        printf '%s\n' "set(CMAKE_FIND_ROOT_PATH \"${PREFIX}\")"
        printf '%s\n' ""
        printf '%s\n' "# Tell CMake to search only in sysroot"
        printf '%s\n' "set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)"
        printf '%s\n' "set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)"
        printf '%s\n' "set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)"
    } >"toolchain.cmake"

    rm -rf build
    mkdir -p build
    cd build

    cmake .. \
      -DCMAKE_TOOLCHAIN_FILE=../toolchain.cmake \
      -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
      -DCMAKE_PREFIX_PATH="${PREFIX}" \
      -DENABLE_STATIC=ON \
      -DENABLE_SHARED=OFF \
      -DJPEG_LIBRARY="${PREFIX}/lib/libjpeg.a" \
      -DPNG_LIBRARY="${PREFIX}/lib/libpng.a" \
      -DZLIB_LIBRARY="${PREFIX}/lib/libz.a" \
      -DBZIP2_LIBRARY="${PREFIX}/lib/libbz2.a" \
      -DCMAKE_VERBOSE_MAKEFILE=ON \
      -DCMAKE_EXE_LINKER_FLAGS="-static -static-libgcc -static-libstdc++"

    $MAKE
    make install

    cd ..

    if [ ! -f "${PREFIX}/include/libffmpegthumbnailer/videothumbnailerc.h" ]; then
        mkdir -p "${PREFIX}/include/libffmpegthumbnailer"
        cp -p libffmpegthumbnailer/*.h "${PREFIX}/include/libffmpegthumbnailer/."
    fi

    touch __package_installed
fi
fi
)

################################################################################
# minidlna-1.3.3
(
PKG_NAME=minidlna
PKG_VERSION=1.3.3
PKG_SOURCE="${PKG_NAME}-${PKG_VERSION}.tar.gz"
PKG_SOURCE_URL="https://downloads.sourceforge.net/project/minidlna/minidlna/${PKG_VERSION}/${PKG_SOURCE}"
PKG_SOURCE_SUBDIR="${PKG_NAME}-${PKG_VERSION}"
PKG_HASH="39026c6d4a139b9180192d1c37225aa3376fdf4f1a74d7debbdbb693d996afa4"

mkdir -p "${SRC_ROOT}/${PKG_NAME}"
cd "${SRC_ROOT}/${PKG_NAME}"

if [ ! -f "${PKG_SOURCE_SUBDIR}/__package_installed" ]; then
    rm -rf "${PKG_SOURCE_SUBDIR}"
    download "${PKG_SOURCE_URL}" "${PKG_SOURCE}" "."
    verify_hash "${PKG_SOURCE}" "${PKG_HASH}"
    unpack_archive "${PKG_SOURCE}" "${PKG_SOURCE_SUBDIR}"
    cd "${PKG_SOURCE_SUBDIR}"

    if ${MINIDLNA_THUMBNAILS_ENABLED}; then
        apply_patches "${SCRIPT_DIR}/patches/${PKG_NAME}/${PKG_SOURCE_SUBDIR}/entware" "."
        apply_patches "${SCRIPT_DIR}/patches/${PKG_NAME}/${PKG_SOURCE_SUBDIR}/entware/solartracker" "."
    else
        apply_patches "${SCRIPT_DIR}/patches/${PKG_NAME}/${PKG_SOURCE_SUBDIR}/solartracker" "."
    fi

    mkdir -p "${PREFIX}/include/sys"
    cp -p "${SCRIPT_DIR}/files/${PKG_NAME}/${PKG_SOURCE_SUBDIR}/solartracker/uclibc-ng+git-bc4bc07d931992388822fa301e34718acbec02c9/include/sys/queue.h" "${PREFIX}/include/sys/"

    if ${MINIDLNA_THUMBNAILS_ENABLED}; then
        LIBS="-lbz2 -lavfilter -ljpeg -lstdc++" \
        ./configure \
            --enable-static \
            --disable-rpath \
            --disable-nls \
            --enable-thumbnail \
            --prefix="${PREFIX}" \
            --host="${HOST}" \
        || handle_configure_error $?
    else
        LIBS="-lbz2" \
        ./configure \
            --enable-static \
            --disable-rpath \
            --disable-nls \
            --prefix="${PREFIX}" \
            --host="${HOST}" \
        || handle_configure_error $?
    fi

    $MAKE
    make install

    # strip and verify there are no dependencies for static build
    finalize_build "${PREFIX}/sbin/minidlnad"

    touch __package_installed
fi
)

