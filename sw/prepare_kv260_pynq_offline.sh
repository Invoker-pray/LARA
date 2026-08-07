#!/usr/bin/env bash
set -Eeuo pipefail

# Build a self-contained KV260/PYNQ offline bundle on the x86 host.
# This script does not source shell startup files or modify the repository.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_ROOT="${1:-${HOME}/Downloads/kv260-pynq-offline}"
DOWNLOAD_ROOT="${OUT_ROOT}"
BUNDLE="${OUT_ROOT}/sd-bundle"
KRIA_REPO="${DOWNLOAD_ROOT}/Kria-PYNQ"
SRC_DIR="${DOWNLOAD_ROOT}/src"
WHEELS_DIR="${DOWNLOAD_ROOT}/wheels"

KRIA_URL="https://github.com/Xilinx/Kria-PYNQ.git"
PYNQ_SOURCE_URL="https://files.pythonhosted.org/packages/source/p/pynq/pynq-3.0.1.tar.gz"
PYNQ_BINARIES_URL="https://www.xilinx.com/bin/public/openDownload?filename=pynq-v3.0-binaries.tar.gz"
PYNQ_SOURCE_SHA256="9c8833212ad91bbb8e95fb0bc76ee4f8deefff0780d02ea90845ea73afd54451"
PYNQ_BINARIES_SHA256="0b530f5e301712f8b5939533f7c955afa2f3495a81704773d1a4cebc6587b105"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    printf '\n==> %s\n' "$*"
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

check_sha256() {
    local expected="$1"
    local file="$2"
    local actual
    actual="$(sha256sum "${file}" | awk '{print $1}')"
    [[ "${actual}" == "${expected}" ]] || die "SHA256 mismatch for ${file}: ${actual}"
    echo "SHA256 OK: ${file}"
}

download_archive() {
    local url="$1"
    local output="$2"
    local expected="$3"

    if [[ -f "${output}" ]]; then
        if sha256sum -c <(printf '%s  %s\n' "${expected}" "${output}") >/dev/null 2>&1; then
            echo "Reuse verified archive: ${output}"
            return
        fi
        echo "Existing archive failed verification; downloading again: ${output}" >&2
        rm -f "${output}"
    fi
    wget -O "${output}" "${url}"
    check_sha256 "${expected}" "${output}"
}

compile_dtbo() {
    local dts_dir="${KRIA_REPO}/dts"

    if command -v dtc >/dev/null 2>&1; then
        need_command make
        make -C "${dts_dir}"
        return
    fi

    if ! command -v docker >/dev/null 2>&1; then
        die "dtc is missing and Docker is unavailable; install device-tree-compiler"
    fi

    log "dtc not found; compiling pynq.dtbo in a temporary Ubuntu container"
    docker run --rm --platform linux/amd64 \
        -v "${dts_dir}:/src" \
        ubuntu:22.04 \
        bash -lc '
            set -e
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y --no-install-recommends device-tree-compiler make
            make -C /src
        '
}

download_wheels() {
    log "Downloading Python 3.10/aarch64 runtime wheels"

    # Binary packages must target the KV260 architecture. The remaining
    # packages are pure Python and are downloaded without an x86 platform tag.
    python3 -m pip download \
        --disable-pip-version-check \
        --dest "${WHEELS_DIR}" \
        --only-binary=:all: \
        --platform manylinux2014_aarch64 \
        --python-version 3.10 \
        --implementation cp \
        --abi cp310 \
        --no-deps \
        numpy==1.26.4 \
        cffi==1.15.1

    python3 -m pip download \
        --disable-pip-version-check \
        --dest "${WHEELS_DIR}" \
        --only-binary=:all: \
        --no-deps \
        nest_asyncio==1.5.5 \
        pynqmetadata==0.1.2 \
        pynqutils==0.1.1 \
        pycparser==2.21 \
        typing_extensions==4.3.0 \
        setuptools==65.5.0 \
        wheel==0.37.1 \
        pydantic==1.10.13 \
        virtualenv==20.16.5 \
        distlib==0.3.6 \
        filelock==3.8.0 \
        platformdirs==2.5.2 \
        jsonschema==4.9.0 \
        attrs==22.2.0 \
        pyrsistent==0.19.3 \
        python-magic==0.4.27 \
        tqdm==4.70.0 \
        ipython==8.4.0 \
        ipython-genutils==0.2.0 \
        backcall==0.2.0 \
        decorator==5.1.1 \
        jedi==0.18.1 \
        matplotlib-inline==0.1.3 \
        pickleshare==0.7.5 \
        prompt-toolkit==3.0.30 \
        pygments==2.12.0 \
        stack-data==0.3.0 \
        traitlets==5.3.0 \
        pexpect==4.8.0 \
        wcwidth==0.2.5 \
        parso==0.8.3 \
        ptyprocess==0.7.0 \
        asttokens==2.0.5 \
        executing==0.9.1 \
        pure-eval==0.2.2 \
        six==1.16.0

    # Keep the wheelhouse self-consistent and fail early if a required file
    # is unavailable instead of producing a bundle that fails on the board.
    local required=(
        numpy-1.26.4-cp310-cp310-manylinux_2_17_aarch64.manylinux2014_aarch64.whl
        cffi-1.15.1-cp310-cp310-manylinux_2_17_aarch64.manylinux2014_aarch64.whl
        nest_asyncio-1.5.5-py3-none-any.whl
        pynqmetadata-0.1.2-py3-none-any.whl
        pynqutils-0.1.1-py3-none-any.whl
        pycparser-2.21-py2.py3-none-any.whl
        pydantic-1.10.13-py3-none-any.whl
        virtualenv-20.16.5-py3-none-any.whl
        distlib-0.3.6-py2.py3-none-any.whl
        filelock-3.8.0-py3-none-any.whl
        platformdirs-2.5.2-py3-none-any.whl
        jsonschema-4.9.0-py3-none-any.whl
        attrs-22.2.0-py3-none-any.whl
        pyrsistent-0.19.3-py3-none-any.whl
        python_magic-0.4.27-py2.py3-none-any.whl
        tqdm-4.70.0-py3-none-any.whl
        ipython-8.4.0-py3-none-any.whl
        ipython_genutils-0.2.0-py2.py3-none-any.whl
        backcall-0.2.0-py2.py3-none-any.whl
        decorator-5.1.1-py3-none-any.whl
        jedi-0.18.1-py2.py3-none-any.whl
        matplotlib_inline-0.1.3-py3-none-any.whl
        pickleshare-0.7.5-py2.py3-none-any.whl
        prompt_toolkit-3.0.30-py3-none-any.whl
        Pygments-2.12.0-py3-none-any.whl
        stack_data-0.3.0-py3-none-any.whl
        traitlets-5.3.0-py3-none-any.whl
        pexpect-4.8.0-py2.py3-none-any.whl
        wcwidth-0.2.5-py2.py3-none-any.whl
        parso-0.8.3-py2.py3-none-any.whl
        ptyprocess-0.7.0-py2.py3-none-any.whl
        asttokens-2.0.5-py2.py3-none-any.whl
        executing-0.9.1-py2.py3-none-any.whl
        pure_eval-0.2.2-py3-none-any.whl
        six-1.16.0-py2.py3-none-any.whl
    )
    local wheel
    for wheel in "${required[@]}"; do
        [[ -f "${WHEELS_DIR}/${wheel}" ]] || die "missing downloaded wheel: ${wheel}"
    done
}

copy_install_script() {
    local scripts_dir="${BUNDLE}/scripts"

    [[ -f "${REPO_ROOT}/sw/kv260_pynq_offline_install.sh" ]] ||
        die "missing offline installer: ${REPO_ROOT}/sw/kv260_pynq_offline_install.sh"
    mkdir -p "${scripts_dir}"
    cp -a "${REPO_ROOT}/sw/kv260_pynq_offline_install.sh" "${scripts_dir}/"
    chmod 0755 "${scripts_dir}/kv260_pynq_offline_install.sh"
}

make_manifest() {
    local manifest="${BUNDLE}/OFFLINE_SHA256SUMS"
    (
        cd "${BUNDLE}"
        find . -type f ! -name OFFLINE_SHA256SUMS -printf '%P\n' |
            LC_ALL=C sort |
            while read -r file; do
                sha256sum -- "${file}"
            done
    ) > "${manifest}"
}

need_command git
need_command wget
need_command sha256sum
need_command tar
need_command python3
python3 -m pip --version >/dev/null 2>&1 ||
    die "python3-pip is required on the host"

if [[ -e "${BUNDLE}/lara" ]]; then
    die "${BUNDLE} contains a legacy LARA payload; choose a fresh output root. The offline runtime must not bind an old bitstream."
fi

mkdir -p "${SRC_DIR}" "${WHEELS_DIR}" \
    "${BUNDLE}/src" "${BUNDLE}/wheels" "${BUNDLE}/Kria-PYNQ/dts"

log "Preparing Kria-PYNQ repository"
if [[ -d "${KRIA_REPO}/.git" ]]; then
    git -C "${KRIA_REPO}" submodule update --init --recursive
else
    [[ ! -e "${KRIA_REPO}" ]] || die "${KRIA_REPO} exists but is not a Git repository"
    git clone --recurse-submodules --branch main "${KRIA_URL}" "${KRIA_REPO}"
fi

log "Downloading PYNQ source and binary archives"
download_archive \
    "${PYNQ_SOURCE_URL}" \
    "${SRC_DIR}/pynq-3.0.1.tar.gz" \
    "${PYNQ_SOURCE_SHA256}"
download_archive \
    "${PYNQ_BINARIES_URL}" \
    "${SRC_DIR}/pynq-v3.0-binaries.tar.gz" \
    "${PYNQ_BINARIES_SHA256}"
tar -tzf "${SRC_DIR}/pynq-3.0.1.tar.gz" >/dev/null
tar -tzf "${SRC_DIR}/pynq-v3.0-binaries.tar.gz" >/dev/null

log "Compiling PYNQ device-tree overlay"
compile_dtbo
[[ -s "${KRIA_REPO}/dts/pynq.dtbo" ]] || die "pynq.dtbo was not generated"
cp -a "${KRIA_REPO}/dts/pynq.dtbo" "${KRIA_REPO}/dts/insert_dtbo.py" \
    "${BUNDLE}/Kria-PYNQ/dts/"
cp -a "${SRC_DIR}/pynq-3.0.1.tar.gz" "${SRC_DIR}/pynq-v3.0-binaries.tar.gz" \
    "${BUNDLE}/src/"

download_wheels
cp -a "${WHEELS_DIR}/." "${BUNDLE}/wheels/"
copy_install_script

log "Creating and validating offline manifest"
make_manifest
(
    cd "${BUNDLE}"
    sha256sum -c OFFLINE_SHA256SUMS
)

echo
echo "Offline bundle ready:"
echo "  ${BUNDLE}"
du -sh "${BUNDLE}"
echo "  files: $(wc -l < "${BUNDLE}/OFFLINE_SHA256SUMS")"
echo
echo "Copy this directory to the SD card writable partition as:"
echo "  /home/ubuntu/kv260-pynq-offline"
echo "This bundle contains only the offline PYNQ runtime."
echo "Use sw/package_kv260_board.sh to combine it with the signed LARA build and tests."
