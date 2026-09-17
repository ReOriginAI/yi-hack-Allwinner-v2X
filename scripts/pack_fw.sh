#!/bin/bash

#
#  This file is part of yi-hack-v4 (https://github.com/TheCrypt0/yi-hack-v4).
#  Copyright (c) 2018-2019 Davide Maggioni.
# 
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, version 3.
# 
#  This program is distributed in the hope that it will be useful, but
#  WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
#  General Public License for more details.
# 
#  You should have received a copy of the GNU General Public License
#  along with this program. If not, see <http://www.gnu.org/licenses/>.
#

get_script_dir()
{
    echo "$(cd `dirname $0` && pwd)"
}

create_tmp_dir()
{
    local TMP_DIR=$(mktemp -d)

    if [[ ! "$TMP_DIR" || ! -d "$TMP_DIR" ]]; then
        echo "ERROR: Could not create temp dir \"$TMP_DIR\". Exiting."
        exit 1
    fi

    echo $TMP_DIR
}

compress_file()
{
    local DIR=$1
    local FILENAME=$2
    local FILE=$DIR/$FILENAME
    echo -n "    Compressing $FILE..."
    7za a "$FILE.7z" "$FILE" > /dev/null
    rm -f "$FILE"
    echo "done!"
}

pack_image()
{
    local TYPE=$1
    local CAMERA_ID=$2
    local DIR=$3
    local OUT=$4

    echo ">>> Packing ${TYPE}_${CAMERA_ID}"

    echo TYPE $TYPE
    echo CAMERA_ID $CAMERA_ID
    echo DIR $DIR
    echo OUT $OUT
    echo -n "    Creating tar.bz2 archive in $DIR/${TYPE}_${CAMERA_ID}.tar.bz2... "
    tar jcvf $OUT/${TYPE}_${CAMERA_ID}.tar.bz2 -C $DIR $TYPE || exit 1
    echo "done!"
}

render_local_bootstrap()
{
    local MODEL=$1
    local ROOT_DIR=$2
    local TOOLCHAIN_BIN=${YI_TOOLCHAIN_BIN:-/opt/yi/toolchain-sunxi-musl/toolchain/bin}
    local AS=${TOOLCHAIN_BIN}/arm-openwrt-linux-muslgnueabi-as
    local LD=${TOOLCHAIN_BIN}/arm-openwrt-linux-muslgnueabi-ld
    local NOOP_OBJ=${ROOT_DIR}/.local-only-noop.o
    local NOOP=${ROOT_DIR}/.local-only-noop
    local EXPECTED_NOOP_MD5=b92bc72d8b7019ec751c36235e92fba5

    [ -x "$AS" ] || { echo "ERROR: ARM assembler not found: $AS"; exit 1; }
    [ -x "$LD" ] || { echo "ERROR: ARM linker not found: $LD"; exit 1; }

    "$AS" -o "$NOOP_OBJ" "$BASE_DIR/scripts/vendor-ablation/noop.S" || exit 1
    "$LD" -N -nostdlib -static -s -o "$NOOP" "$NOOP_OBJ" || exit 1

    local NOOP_MD5
    NOOP_MD5=$(md5sum "$NOOP" | awk '{print $1}')
    if [ "$NOOP_MD5" != "$EXPECTED_NOOP_MD5" ]; then
        echo "ERROR: local-only no-op binary hash mismatch: $NOOP_MD5"
        rm -f "$NOOP_OBJ" "$NOOP"
        exit 1
    fi

    mkdir -p "$ROOT_DIR/Factory" || exit 1
    python3 "$BASE_DIR/scripts/vendor-ablation/render.py" "$MODEL" "$NOOP" "$ROOT_DIR/yi-hack" "$ROOT_DIR/Factory/local_init.sh" || exit 1
    /bin/sh -n "$ROOT_DIR/Factory/local_init.sh" || exit 1
    chmod 755 "$ROOT_DIR/Factory/local_init.sh" || exit 1
    rm -f "$NOOP_OBJ" "$NOOP"
}

###############################################################################

source "$(get_script_dir)/common.sh"

require_root


if [ $# -ne 1 ]; then
    echo "Usage: pack_sw.sh camera_name"
    echo ""
    exit 1
fi

CAMERA_NAME=$1

check_camera_name $CAMERA_NAME

CAMERA_ID=$(get_camera_id $CAMERA_NAME)

BASE_DIR=$(get_script_dir)/../
BASE_DIR=$(normalize_path $BASE_DIR)
SYSROOT_DIR=$BASE_DIR/sysroot/$CAMERA_NAME


SDHACK_DIR=$BASE_DIR/sdhack
STATIC_DIR=$BASE_DIR/static
BUILD_DIR=$BASE_DIR/build
BUILD_PAYLOAD_DIR=$BUILD_DIR/yi-hack
OUT_DIR=$BASE_DIR/out/$CAMERA_NAME
VER=$(cat VERSION)

# Append git short hash when building outside a tagged release,
# so local builds are distinguishable from official releases.
GIT_TAG=$(git -C "$BASE_DIR" tag --points-at HEAD 2>/dev/null | grep -Fx "$VER" | head -1)
if [ -z "$GIT_TAG" ]; then
    GIT_HASH=$(git -C "$BASE_DIR" rev-parse --short HEAD 2>/dev/null || echo "custom")
    VER="${VER}-${GIT_HASH}"
fi

echo ""
echo "------------------------------------------------------------------------"
echo " YI-HACK - FIRMWARE PACKER"
echo "------------------------------------------------------------------------"
printf " camera_name      : %s\n" $CAMERA_NAME
printf " camera_id        : %s\n" $CAMERA_ID
printf " version          : %s\n" $VER
printf "                      \n"
printf " sysroot_dir      : %s\n" $SYSROOT_DIR
printf " static_dir       : %s\n" $STATIC_DIR
printf " build_dir        : %s\n" $BUILD_DIR
printf " build_payload    : %s\n" $BUILD_PAYLOAD_DIR
printf " out_dir          : %s\n" $OUT_DIR
echo "------------------------------------------------------------------------"
echo ""

echo -n ">>> Starting..."

sleep 1

[ -d "$BUILD_PAYLOAD_DIR" ] || { echo "ERROR: Missing compiled payload: $BUILD_PAYLOAD_DIR"; exit 1; }

echo -n ">>> Creating the out directory... "
mkdir -p $OUT_DIR
echo "${OUT_DIR} created!"

echo -n ">>> Creating the tmp directory... "
TMP_DIR=$(create_tmp_dir)
echo "${TMP_DIR} created!"
mkdir -p ${TMP_DIR}/yi-hack

# Copy the sysroot to the tmp dir
echo ">>> Copying the sysroot contents to ${TMP_DIR}... "
rsync -a ${SYSROOT_DIR}/* ${TMP_DIR}/ || exit 1
echo "    done!"

# Copy only the compiled firmware payload. Never copy arbitrary build/ siblings:
# local development keeps private vendor-ablation evidence under build/.
echo -n ">>> Copying compiled yi-hack payload to ${TMP_DIR}... "
rsync -a "${BUILD_PAYLOAD_DIR}/" "${TMP_DIR}/yi-hack/" || exit 1
echo "done!"

# adding defaults
echo -n ">>> Adding defaults... "
(cd $TMP_DIR/yi-hack/etc/ && tar jcvf $TMP_DIR/yi-hack/etc/defaults.tar.bz2 *.conf > /dev/null 2>&1)
echo "done!"

# insert the version file
echo -n ">>> Writing the version file... "
echo "$VER" > $TMP_DIR/yi-hack/version
echo "done!"

# insert the model suffix file
echo -n ">>> Creating the model suffix file... "
echo $CAMERA_ID > $TMP_DIR/yi-hack/model_suffix
echo "done!"

# fix the files ownership
echo -n ">>> Fixing the files ownership... "
chown -R root:root $TMP_DIR/*
echo "done!"

# Copy the sdhack to the output dir
echo ">>> Copying the sdhack contents to $TMP_DIR... "
echo "    Copying sdhack..."
rsync -a ${SDHACK_DIR}/${CAMERA_ID}/* $TMP_DIR || exit 1
echo "    done!"

# y623 releases carry a deterministic VE-debugfs kernel image. Generate it
# from the exact audited stock boot partition so packaging fails if either the
# vendor image or patch signatures ever drift.
if [ "$CAMERA_NAME" = "y623" ]; then
    STOCK_BOOT="$BASE_DIR/scripts/vendor-images/y623-boot-stock.bin"
    PATCHED_BOOT="$TMP_DIR/Factory/boot-vmalloc.bin"
    EXPECTED_STOCK_BOOT_MD5=2c8abc0f8376bdb55d8464abc6bf14a8
    EXPECTED_PATCHED_BOOT_MD5=26a2e9a432fbe36efe97f0e7cee84dc9

    [ -s "$STOCK_BOOT" ] || { echo "ERROR: Missing audited y623 stock boot image"; exit 1; }
    [ "$(md5sum "$STOCK_BOOT" | awk '{print $1}')" = "$EXPECTED_STOCK_BOOT_MD5" ] || { echo "ERROR: y623 stock boot hash mismatch"; exit 1; }
    command -v xz >/dev/null 2>&1 || { echo "ERROR: xz is required to generate the y623 patched boot image"; exit 1; }
    python3 "$BASE_DIR/scripts/patch_y623_ve_debugfs.py" "$STOCK_BOOT" "$PATCHED_BOOT" || exit 1
    [ "$(md5sum "$PATCHED_BOOT" | awk '{print $1}')" = "$EXPECTED_PATCHED_BOOT_MD5" ] || { echo "ERROR: generated y623 patched boot hash mismatch"; exit 1; }
fi

# Generate the exact model- and payload-bound bootstrap that first install writes
# to /backup/init.sh. This is the same fail-closed bootstrap used on test units.
echo -n ">>> Generating local-only bootstrap... "
render_local_bootstrap "$CAMERA_NAME" "$TMP_DIR"
echo "done!"

# create tar.gz
rm -f $TMP_DIR/*.tgz
(cd $TMP_DIR && tar zcvf ${CAMERA_NAME}_${VER}.tgz *)

# copy files to the output dir
echo ">>> Copying files to $OUT_DIR... "
echo "    Copying files..."
cp $TMP_DIR/${CAMERA_NAME}_${VER}.tgz $OUT_DIR
mkdir -p $OUT_DIR/../all
cp $TMP_DIR/${CAMERA_NAME}_${VER}.tgz $OUT_DIR/../all
echo "    done!"

# Cleanup
echo -n ">>> Cleaning up the tmp folder... "
rm -rf $TMP_DIR
echo "done!"

echo "------------------------------------------------------------------------"
echo " Finished!"
echo "------------------------------------------------------------------------"
