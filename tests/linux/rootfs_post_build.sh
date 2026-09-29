#!/bin/sh
# Buildroot post-build hook (BR2_ROOTFS_POST_BUILD_SCRIPT).  $1 = TARGET_DIR.
#
# Make root's login shell /bin/bash so an interactive login on the real board
# lands in bash (the milestone), and ensure the sentinel init script is
# executable (overlay files can lose the +x bit through git on Windows).
set -e
TARGET_DIR="$1"

# root's shell -> /bin/bash (Buildroot's skeleton defaults it to /bin/sh).
if [ -f "$TARGET_DIR/etc/passwd" ]; then
    sed -i 's#^root:\(.*\):/bin/sh$#root:\1:/bin/bash#' "$TARGET_DIR/etc/passwd"
fi

# Guarantee the sim sentinel is runnable regardless of how git stored its mode.
if [ -f "$TARGET_DIR/etc/init.d/S99sentinel" ]; then
    chmod 0755 "$TARGET_DIR/etc/init.d/S99sentinel"
fi
