# Script adopted from https://github.com/ptheywood/cuda-cmake-github-actions
# Copyright (c) 2021 Peter Heywood
# Released under MIT license

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

#
# Script assumes environment variables are set:
#    CUDA_VERSION_MAJOR_MINOR is set to CUDA version to install (e.g. 11.8.0)
#    CUDA_OS is set to Nvidia labeling for OS (e.g. ubuntu2204)
#

## -------------------
## Constants
## -------------------

# List of sub-packages to install.

# Ideally choose from the list of meta-packages to minimise variance between cuda versions (although it does change too). Some of these packages may not be available in older CUDA releases
CUDA_PACKAGES_IN=(
    "cuda-compiler"
    "cuda-cudart-dev"
    "cuda-nvtx"
    "cuda-nvrtc-dev"
    "cuda-nvml-dev"
    "libcurand-dev" # 11-0+
    "cuda-cccl" # 11.4+, provides cub and thrust. On 11.3 known as cuda-thrust-11-3
)

## -------------------
## Bash functions
## -------------------
# returns 0 (true) if a >= b
function version_ge() {
    [ "$#" != "2" ] && echo "${FUNCNAME[0]} requires exactly 2 arguments." && exit 1
    [ "$(printf '%s\n' "$@" | sort -V | head -n 1)" == "$2" ]
}
# returns 0 (true) if a > b
function version_gt() {
    [ "$#" != "2" ] && echo "${FUNCNAME[0]} requires exactly 2 arguments." && exit 1
    [ "$1" = "$2" ] && return 1 || version_ge $1 $2
}
# returns 0 (true) if a <= b
function version_le() {
    [ "$#" != "2" ] && echo "${FUNCNAME[0]} requires exactly 2 arguments." && exit 1
    [ "$(printf '%s\n' "$@" | sort -V | head -n 1)" == "$1" ]
}
# returns 0 (true) if a < b
function version_lt() {
    [ "$#" != "2" ] && echo "${FUNCNAME[0]} requires exactly 2 arguments." && exit 1
    [ "$1" = "$2" ] && return 1 || version_le $1 $2
}

## -------------------
## Select CUDA version
## -------------------

# Get the cuda version from the environment as $cuda.
# CUDA_VERSION_MAJOR_MINOR=${cuda}

# Split the version.
# We (might/probably) don't know PATCH at this point - it depends which version gets installed.
CUDA_MAJOR=$(echo "${CUDA_VERSION_MAJOR_MINOR}" | cut -d. -f1)
CUDA_MINOR=$(echo "${CUDA_VERSION_MAJOR_MINOR}" | cut -d. -f2)
CUDA_PATCH=$(echo "${CUDA_VERSION_MAJOR_MINOR}" | cut -d. -f3)

echo "CUDA_MAJOR: ${CUDA_MAJOR}"
echo "CUDA_MINOR: ${CUDA_MINOR}"
echo "CUDA_PATCH: ${CUDA_PATCH}"

echo "CUDA_OS: ${CUDA_OS}"

# If we don't know the CUDA_MAJOR or MINOR, error.
if [ -z "${CUDA_MAJOR}" ] ; then
    echo "Error: Unknown CUDA Major version. Aborting."
    exit 1
fi
if [ -z "${CUDA_MINOR}" ] ; then
    echo "Error: Unknown CUDA Minor version. Aborting."
    exit 1
fi

## -------------------------------
## Select CUDA packages to install
## -------------------------------
CUDA_PACKAGES=""
for package in "${CUDA_PACKAGES_IN[@]}"
do : 
    # @todo This is not perfect. Should probably provide a separate list for diff versions
    # cuda-compiler-X-Y if CUDA >= 9.1 else cuda-nvcc-X-Y
    if [[ "${package}" == "cuda-nvcc" ]] && version_ge "$CUDA_VERSION_MAJOR_MINOR" "9.1" ; then
        package="cuda-compiler"
    elif [[ "${package}" == "cuda-compiler" ]] && version_lt "$CUDA_VERSION_MAJOR_MINOR" "9.1" ; then
        package="cuda-nvcc"
    # CUB/Thrust  are packages in cuda-thrust in 11.3, but cuda-cccl in 11.4+
    elif [[ "${package}" == "cuda-thrust" || "${package}" == "cuda-cccl" ]]; then
        # CUDA cuda-thrust >= 11.4
        if version_ge "$CUDA_VERSION_MAJOR_MINOR" "11.4" ; then
            package="cuda-cccl"
        # Use cuda-thrust > 11.2
        elif version_ge "$CUDA_VERSION_MAJOR_MINOR" "11.3" ; then
            package="cuda-thrust"
        # Do not include this package < 11.3
        else
            continue
        fi
    fi
    # CUDA 11+ includes lib* / lib*-dev packages, which if they existed previously where cuda-cu*- / cuda-cu*-dev-
    if [[ ${package} == libcu* ]] && version_lt "$CUDA_VERSION_MAJOR_MINOR" "11.0" ; then
        package="${package/libcu/cuda-cu}"
    fi
    # Build the full package name and append to the string.
    CUDA_PACKAGES+=" ${package}-${CUDA_MAJOR}-${CUDA_MINOR}"
done
echo "CUDA_PACKAGES ${CUDA_PACKAGES}"

## -----------------
## Prepare to install
## -----------------
CPU_ARCH="x86_64"
PIN_FILENAME="cuda-${CUDA_OS}.pin"
PIN_URL="https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_OS}/${CPU_ARCH}/${PIN_FILENAME}"
# apt keyring package now available https://developer.nvidia.com/blog/updating-the-cuda-linux-gpg-repository-key/
KERYRING_PACKAGE_FILENAME="cuda-keyring_1.0-1_all.deb"
KEYRING_PACKAGE_URL="https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_OS}/${CPU_ARCH}/${KERYRING_PACKAGE_FILENAME}"
REPO_URL="https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_OS}/${CPU_ARCH}/"

echo "PIN_FILENAME ${PIN_FILENAME}"
echo "PIN_URL ${PIN_URL}"
echo "KEYRING_PACKAGE_URL ${KEYRING_PACKAGE_URL}"
echo "APT_KEY_URL ${APT_KEY_URL}"

## -----------------
## Check for root/sudo
## -----------------

# Detect if the script is being run as root, storing true/false in is_root.
is_root=false
if (( $EUID == 0)); then
   is_root=true
fi
# Find if sudo is available
has_sudo=false
if command -v sudo &> /dev/null ; then
    has_sudo=true
fi
# Decide if we can proceed or not (root or sudo is required) and if so store whether sudo should be used or not. 
if [ "$is_root" = false ] && [ "$has_sudo" = false ]; then 
    echo "Root or sudo is required. Aborting."
    exit 1
elif [ "$is_root" = false ] ; then
    USE_SUDO=sudo
else
    USE_SUDO=
fi

## -----------------
## Install
## -----------------
echo "Adding CUDA Repository"
wget ${PIN_URL}
$USE_SUDO mv ${PIN_FILENAME} /etc/apt/preferences.d/cuda-repository-pin-600
wget ${KEYRING_PACKAGE_URL} && ${USE_SUDO} dpkg -i ${KERYRING_PACKAGE_FILENAME} && rm ${KERYRING_PACKAGE_FILENAME}
$USE_SUDO add-apt-repository "deb ${REPO_URL} /"
$USE_SUDO apt-get update

echo "Installing CUDA packages ${CUDA_PACKAGES}"
$USE_SUDO apt-get -y install ${CUDA_PACKAGES}

if [[ $? -ne 0 ]]; then
    echo "CUDA Installation Error."
    exit 1
fi

## -----------------
## Set environment vars / vars to be propagated
## -----------------

CUDA_PATH=/usr/local/cuda-${CUDA_MAJOR}.${CUDA_MINOR}
echo "CUDA_PATH=${CUDA_PATH}"
export CUDA_PATH=${CUDA_PATH}
export PATH="$CUDA_PATH/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_PATH/lib:$LD_LIBRARY_PATH"
export LD_LIBRARY_PATH="$CUDA_PATH/lib64:$LD_LIBRARY_PATH"
# Check nvcc is now available.
nvcc -V


# If executed on github actions, make the appropriate echo statements to update the environment
if [[ $GITHUB_ACTIONS ]]; then
    # Set paths for subsequent steps, using ${CUDA_PATH}
    echo "Adding CUDA to CUDA_PATH, PATH and LD_LIBRARY_PATH"
    echo "CUDA_PATH=${CUDA_PATH}" >> $GITHUB_ENV
    echo "${CUDA_PATH}/bin" >> $GITHUB_PATH
    echo "LD_LIBRARY_PATH=${CUDA_PATH}/lib:${LD_LIBRARY_PATH}" >> $GITHUB_ENV
    echo "LD_LIBRARY_PATH=${CUDA_PATH}/lib64:${LD_LIBRARY_PATH}" >> $GITHUB_ENV
fi
