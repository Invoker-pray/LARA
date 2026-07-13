#!/bin/bash
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
set -e
export SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-27000@127.0.0.1}"
export LM_LICENSE_FILE="${LM_LICENSE_FILE:-$SNPSLMD_LICENSE_FILE}"
TB_NAME="tb_output_buffer"
SIM_DIR="VV/sim/${TB_NAME}_xpm"
mkdir -p "${SIM_DIR}"

WRAPPER_DIR="$(pwd)/${SIM_DIR}/.gcc_wrapper"
mkdir -p "${WRAPPER_DIR}"
REAL_GCC="$(command -v gcc)"
cat > "${WRAPPER_DIR}/gcc" << GCCEOF
#!/bin/bash
exec ${REAL_GCC} -Wno-error=implicit-function-declaration "\$@"
GCCEOF
chmod +x "${WRAPPER_DIR}/gcc"
export PATH="${WRAPPER_DIR}:${PATH}"

XPM_SV="${XPM_SV:-/home/jiao/xilinx/2025.2/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv}"

if [ ! -f "${XPM_SV}" ]; then
    echo "ERROR: XPM source not found: ${XPM_SV}"
    exit 1
fi

cd "${SIM_DIR}"
ln -sf ../../../VV/data/recip_lut.hex recip_lut.hex
set +e
vcs -full64 -sverilog -timescale=1ns/1ps +lint=all +v2k +define+SYNTHESIS +define+USE_XPM_MEMORY \
    -l compile.log \
    +incdir+../../../hw/rtl/pkg \
    "${XPM_SV}" \
    ../../../hw/rtl/pkg/attn_pkg.sv \
    ../../../hw/rtl/mem/output_buffer.sv \
    ../../../VV/tb/${TB_NAME}.sv \
    -top ${TB_NAME} \
    -o simv > compile.console.log 2>&1
VCS_STATUS=$?
set -e

if [ ${VCS_STATUS} -ne 0 ]; then
    echo "ERROR: VCS compilation failed; tail of compile.console.log follows"
    tail -n 80 compile.console.log
    exit ${VCS_STATUS}
fi

# Xilinx's xpm_memory.sv emits a large number of +lint=all warnings from its
# generic simulation model. Keep those auditable without allowing them to hide
# warnings from LARA RTL or the testbench.
: > vendor_warnings.log
: > project_warnings.log
awk -v xpm="${XPM_SV}" \
    -v vendor_log="vendor_warnings.log" \
    -v project_log="project_warnings.log" '
    BEGIN { RS=""; ORS="\n\n" }
    /(^|\n)(Warning|Lint)-\[/ {
        if (index($0, xpm))
            print > vendor_log
        else
            print > project_log
    }
' compile.log

VENDOR_WARNING_COUNT=$(grep -Ec '^(Warning|Lint)-\[' vendor_warnings.log || true)
PROJECT_WARNING_COUNT=$(grep -Ec '^(Warning|Lint)-\[' project_warnings.log || true)
echo "XPM lint classification: vendor=${VENDOR_WARNING_COUNT} project=${PROJECT_WARNING_COUNT}"
echo "  vendor details: ${SIM_DIR}/vendor_warnings.log"

if [ ${PROJECT_WARNING_COUNT} -ne 0 ]; then
    echo "ERROR: project-local warnings found in XPM verification path:"
    cat project_warnings.log
    exit 1
fi

cat > run.tcl << 'TCL'
run 5000ns
quit
TCL
./simv -no_save -ucli -i run.tcl -l sim.log
echo "${TB_NAME}_xpm: DONE"
