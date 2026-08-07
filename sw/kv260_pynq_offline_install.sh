#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo bash $0 /path/to/kv260-pynq-offline" >&2
    exit 1
fi

BUNDLE="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
WHEELS="${BUNDLE}/wheels"
SRC="${BUNDLE}/src"
KRIA="${BUNDLE}/Kria-PYNQ"
PYNQ_VENV="${PYNQ_VENV:-/usr/local/share/pynq-venv}"
NOTEBOOK_DIR="${PYNQ_JUPYTER_NOTEBOOKS:-/home/ubuntu/jupyter_notebooks}"

for required in \
    "${SRC}/pynq-3.0.1.tar.gz" \
    "${SRC}/pynq-v3.0-binaries.tar.gz" \
    "${KRIA}/dts/pynq.dtbo" \
    "${KRIA}/dts/insert_dtbo.py"; do
    [[ -f "${required}" ]] || {
        echo "Missing offline input: ${required}" >&2
        exit 2
    }
done

shopt -s nullglob
wheel_files=("${WHEELS}"/*.whl)
(( ${#wheel_files[@]} > 0 )) || {
    echo "No wheel files found in ${WHEELS}" >&2
    exit 2
}
shopt -u nullglob

required_wheels=(
    "numpy-1.26.4-cp310-cp310-manylinux_2_17_aarch64.manylinux2014_aarch64.whl"
    "cffi-1.15.1-cp310-cp310-manylinux_2_17_aarch64.manylinux2014_aarch64.whl"
    "pycparser-2.21-py2.py3-none-any.whl"
    "nest_asyncio-1.5.5-py3-none-any.whl"
    "pynqmetadata-0.1.2-py3-none-any.whl"
    "pynqutils-0.1.1-py3-none-any.whl"
    "jsonschema-4.9.0-py3-none-any.whl"
    "attrs-22.2.0-py3-none-any.whl"
    "pyrsistent-0.19.3-py3-none-any.whl"
    "pydantic-1.10.13-py3-none-any.whl"
    "python_magic-0.4.27-py2.py3-none-any.whl"
    "tqdm-4.70.0-py3-none-any.whl"
    "typing_extensions-4.3.0-py3-none-any.whl"
    "setuptools-65.5.0-py3-none-any.whl"
    "wheel-0.37.1-py2.py3-none-any.whl"
    "ipython-8.4.0-py3-none-any.whl"
    "ipython_genutils-0.2.0-py2.py3-none-any.whl"
    "backcall-0.2.0-py2.py3-none-any.whl"
    "decorator-5.1.1-py3-none-any.whl"
    "jedi-0.18.1-py2.py3-none-any.whl"
    "matplotlib_inline-0.1.3-py3-none-any.whl"
    "pickleshare-0.7.5-py2.py3-none-any.whl"
    "prompt_toolkit-3.0.30-py3-none-any.whl"
    "Pygments-2.12.0-py3-none-any.whl"
    "stack_data-0.3.0-py3-none-any.whl"
    "traitlets-5.3.0-py3-none-any.whl"
    "pexpect-4.8.0-py2.py3-none-any.whl"
    "wcwidth-0.2.5-py2.py3-none-any.whl"
    "parso-0.8.3-py2.py3-none-any.whl"
    "ptyprocess-0.7.0-py2.py3-none-any.whl"
    "asttokens-2.0.5-py2.py3-none-any.whl"
    "executing-0.9.1-py2.py3-none-any.whl"
    "pure_eval-0.2.2-py3-none-any.whl"
    "six-1.16.0-py2.py3-none-any.whl"
)
for required_wheel in "${required_wheels[@]}"; do
    [[ -f "${WHEELS}/${required_wheel}" ]] || {
        echo "Missing required wheel: ${WHEELS}/${required_wheel}" >&2
        exit 2
    }
done

tmp_dir="$(mktemp -d /tmp/lara-pynq-install.XXXXXX)"
trap 'rm -rf "${tmp_dir}"' EXIT

python3 --version
mkdir -p "${NOTEBOOK_DIR}"
export PIP_DISABLE_PIP_VERSION_CHECK=1

# virtualenv carries its own seed pip/setuptools, so python3.10-venv is not
# required on the offline target image.
python3 -m pip install \
    --no-index \
    --find-links "${WHEELS}" \
    --target "${tmp_dir}/bootstrap" \
    virtualenv==20.16.5 \
    distlib==0.3.6 \
    filelock==3.8.0 \
    platformdirs==2.5.2

PYTHONPATH="${tmp_dir}/bootstrap" \
    python3 -m virtualenv --clear --system-site-packages "${PYNQ_VENV}"

VENV_PYTHON="${PYNQ_VENV}/bin/python"
[[ -x "${VENV_PYTHON}" ]] || {
    echo "Failed to create ${PYNQ_VENV}" >&2
    exit 3
}

"${VENV_PYTHON}" -m pip install \
    --no-index \
    --find-links "${WHEELS}" \
    --ignore-installed \
    --upgrade \
    numpy==1.26.4 \
    cffi==1.15.1 \
    pycparser==2.21 \
    nest_asyncio==1.5.5 \
    pynqmetadata==0.1.2 \
    pynqutils==0.1.1 \
    jsonschema==4.9.0 \
    attrs==22.2.0 \
    pyrsistent==0.19.3 \
    pydantic==1.10.13 \
    python-magic==0.4.27 \
    tqdm==4.70.0 \
    typing_extensions==4.3.0 \
    setuptools==65.5.0 \
    wheel==0.37.1 \
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

site_packages="$("${VENV_PYTHON}" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
rm -rf "${site_packages}/pynq"
mkdir -p "${tmp_dir}/pynq-src"
tar -xzf "${SRC}/pynq-3.0.1.tar.gz" -C "${tmp_dir}/pynq-src"
pynq_root="$(find "${tmp_dir}/pynq-src" -mindepth 1 -maxdepth 1 -type d -name 'pynq-*' | head -n 1)"
[[ -d "${pynq_root}/pynq" ]] || {
    echo "Could not locate the PYNQ Python package in the source archive" >&2
    exit 4
}
cp -a "${pynq_root}/pynq" "${site_packages}/"

# PYNQ 3.0.1 incorrectly prefers a sibling .xsa over a valid .hwh when a
# .bit/.hwh/.xsa deployment set is placed in one directory. For Overlay(.bit),
# the HWH is the correct runtime metadata source; XSA remains supported when
# it is explicitly used as the input file.
pynq_embedded_py="${site_packages}/pynq/pl_server/embedded_device.py"
python3 - "${pynq_embedded_py}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = "if hwh_data is not None and not is_xsa:"
new = "if hwh_data is not None:"
if old not in text:
    raise SystemExit("PYNQ metadata precedence patch target was not found")
path.write_text(text.replace(old, new, 1), encoding="utf-8")
PY

mkdir -p "${PYNQ_VENV}/bin"
tar -xzf "${SRC}/pynq-v3.0-binaries.tar.gz" -C "${tmp_dir}"
binary_root="${tmp_dir}/pynq-v3.0-binaries"
cp -a "${binary_root}/gcc-mb/microblazeel-xilinx-elf" "${PYNQ_VENV}/bin/"
install -m 0755 "${binary_root}/xrt/xclbinutil" "${PYNQ_VENV}/bin/xclbinutil"

mkdir -p "${PYNQ_VENV}/pynq-dts"
install -m 0644 "${KRIA}/dts/pynq.dtbo" "${PYNQ_VENV}/pynq-dts/pynq.dtbo"
install -m 0755 "${KRIA}/dts/insert_dtbo.py" "${PYNQ_VENV}/pynq-dts/insert_dtbo.py"

cat > /etc/profile.d/pynq_venv.sh <<EOF
export PYNQ_JUPYTER_NOTEBOOKS="${NOTEBOOK_DIR}"
export BOARD=KV260
export XILINX_XRT=/usr
export PATH="${PYNQ_VENV}/bin:${PYNQ_VENV}/bin/microblazeel-xilinx-elf/bin:\$PATH"
source "${PYNQ_VENV}/bin/activate"
EOF
chmod 0644 /etc/profile.d/pynq_venv.sh

"${VENV_PYTHON}" - <<'PY'
from importlib.metadata import version

expected = {
    "numpy": "1.26.4",
    "cffi": "1.15.1",
    "pynqmetadata": "0.1.2",
    "pynqutils": "0.1.1",
    "pydantic": "1.10.13",
    "ipython": "8.4.0",
    "executing": "0.9.1",
}
for package, wanted in expected.items():
    actual = version(package)
    if actual != wanted:
        raise RuntimeError(f"{package} version mismatch: {actual} != {wanted}")

import pynq
import IPython
from pynq import Overlay, allocate

print("PYNQ import PASS:", pynq.__file__)
print("IPython version PASS:", IPython.__version__)
print("PYNQ Overlay/allocate imports PASS")
PY

echo
echo "Offline PYNQ runtime installed at ${PYNQ_VENV}"
echo "Before loading the LARA overlay after boot, run:"
echo "  sudo -i"
echo "  source /etc/profile.d/pynq_venv.sh"
echo "  python3 ${PYNQ_VENV}/pynq-dts/insert_dtbo.py"
