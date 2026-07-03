#!/bin/bash
# Bootstrap: clone OpenSBI v1.2 (if missing) then run the Linux fw_payload build.
# Run inside linux-rv64 docker from /workspace/tests/linux.
set -e
OW=../opensbi/work
mkdir -p $OW
if [ ! -d $OW/opensbi ]; then
    echo "== cloning OpenSBI v1.2 =="
    git clone --depth 1 --branch v1.2 \
        https://github.com/riscv-software-src/opensbi.git $OW/opensbi
fi
echo "== running linux build.sh =="
bash build.sh
echo "BOOTSTRAP DONE"
