#!/bin/bash
# Resolve a list of kernel PCs to nearest symbol (System.map) + addr2line.
# System.map addresses are fixed 16-hex-digit, so lexicographic compare == numeric.
KDIR=work/linux-6.12
MAP=$KDIR/System.map
VMLINUX=$KDIR/vmlinux
A2L=riscv64-linux-gnu-addr2line
for a in "$@"; do
  echo "=== $a ==="
  awk -v target="$a" '$1 <= target { sym=$0 } END { print "  sym: " sym }' "$MAP"
  if [ -f "$VMLINUX" ]; then
    printf "  a2l: "; $A2L -f -e "$VMLINUX" "0x$a" | tr '\n' ' '; echo
  fi
done
