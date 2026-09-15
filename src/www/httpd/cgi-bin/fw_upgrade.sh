#!/bin/sh

export PATH=/usr/bin:/usr/sbin:/bin:/sbin:/home/base/tools:/home/app/localbin:/home/base:/tmp/sd/yi-hack/bin:/tmp/sd/yi-hack/sbin:/tmp/sd/yi-hack/usr/bin:/tmp/sd/yi-hack/usr/sbin
export LD_LIBRARY_PATH=/lib:/usr/lib:/home/lib:/home/qigan/lib:/home/app/locallib:/tmp/sd:/tmp/sd/gdb:/tmp/sd/yi-hack/lib

YI_HACK_PREFIX="/tmp/sd/yi-hack"

. $YI_HACK_PREFIX/www/cgi-bin/validate.sh

if ! $(validateQueryString $QUERY_STRING); then
    printf "Content-type: application/json\r\n\r\n"
    printf "{\n"
    printf "\"%s\":\"%s\"\\n" "error" "true"
    printf "}"
    exit
fi

NAME="$(echo $QUERY_STRING | cut -d'=' -f1)"
VAL="$(echo $QUERY_STRING | cut -d'=' -f2)"

if [ "$NAME" != "get" ] ; then
    exit
fi

if [ "$VAL" == "info" ] ; then
    printf "Content-type: application/json\r\n\r\n"

    MODEL_SUFFIX=`cat $YI_HACK_PREFIX/model_suffix`
    FW_VERSION=`cat $YI_HACK_PREFIX/version`
    LATEST_FW=`/tmp/sd/yi-hack/usr/bin/wget -O -  https://api.github.com/repos/roleoroleo/yi-hack-Allwinner-v2/releases/latest 2>&1 | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'`
    if [ -f /tmp/sd/${MODEL_SUFFIX}_x.x.x.tgz ]; then
        LOCAL_FW="true"
    else
        LOCAL_FW="false"
    fi

    printf "{\n"
    printf "\"%s\":\"%s\",\n" "error" "false"
    printf "\"%s\":\"%s\",\n" "fw_version"      "$FW_VERSION"
    printf "\"%s\":\"%s\",\n" "latest_fw"       "$LATEST_FW"
    printf "\"%s\":%s\n" "local_fw"             "$LOCAL_FW"
    printf "}"

elif [ "$VAL" == "upgrade" ] ; then

    printf "Content-type: text/plain\r\n\r\n"

    FREE_SD=$(df | grep -m1 '/tmp/sd' | grep mmc | awk '{print $4}')
    if [ -z "$FREE_SD" ]; then
        printf "No SD detected."
        exit
    fi

    if [ "$FREE_SD" -lt 100000 ]; then
        printf "No space left on SD."
        exit
    fi

    # Clean old upgrades.
    rm -rf /tmp/sd/.fw_upgrade
    rm -rf /tmp/sd/.fw_upgrade.conf
    rm -rf /tmp/sd/Factory
    rm -rf /tmp/sd/newhome

    mkdir -p /tmp/sd/.fw_upgrade
    mkdir -p /tmp/sd/.fw_upgrade.conf
    cd /tmp/sd/.fw_upgrade || exit

    MODEL_SUFFIX=$(cat "$YI_HACK_PREFIX/model_suffix")
    FW_VERSION=$(cat "$YI_HACK_PREFIX/version")
    if [ -f "/tmp/sd/${MODEL_SUFFIX}_x.x.x.tgz" ]; then
        mv "/tmp/sd/${MODEL_SUFFIX}_x.x.x.tgz" "/tmp/sd/.fw_upgrade/${MODEL_SUFFIX}_x.x.x.tgz"
        LATEST_FW="x.x.x"
    else
        LATEST_FW=$(/tmp/sd/yi-hack/usr/bin/wget -O - https://api.github.com/repos/roleoroleo/yi-hack-Allwinner-v2/releases/latest 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [ "$FW_VERSION" = "$LATEST_FW" ]; then
            rm -rf /tmp/sd/.fw_upgrade /tmp/sd/.fw_upgrade.conf
            printf "No new firmware available."
            exit
        fi

        /tmp/sd/yi-hack/usr/bin/wget -q "https://github.com/roleoroleo/yi-hack-Allwinner-v2/releases/download/$LATEST_FW/${MODEL_SUFFIX}_${LATEST_FW}.tgz" >/dev/null 2>&1
        if [ ! -f "${MODEL_SUFFIX}_${LATEST_FW}.tgz" ]; then
            rm -rf /tmp/sd/.fw_upgrade /tmp/sd/.fw_upgrade.conf
            printf "Unable to download firmware file."
            exit
        fi
    fi

    # Backup configuration.
    cp -rf "$YI_HACK_PREFIX"/etc/* /tmp/sd/.fw_upgrade.conf/
    rm -f /tmp/sd/.fw_upgrade.conf/*.tar.gz

    # Prepare the new hack silently. Never let tar write archive member names
    # to the CGI stream before/among the response body.
    ARCHIVE="${MODEL_SUFFIX}_${LATEST_FW}.tgz"
    if ! tar zxf "$ARCHIVE" >/dev/null 2>&1; then
        rm -rf /tmp/sd/.fw_upgrade /tmp/sd/.fw_upgrade.conf
        printf "Firmware extraction failed."
        exit
    fi
    rm -f "$ARCHIVE"

    # Never reboot into a partial or wrong-model stage.
    STAGED_MODEL=$(cat /tmp/sd/.fw_upgrade/yi-hack/model_suffix 2>/dev/null)
    STAGED_VERSION=$(cat /tmp/sd/.fw_upgrade/yi-hack/version 2>/dev/null)
    if [ "$STAGED_MODEL" != "$MODEL_SUFFIX" ] || [ -z "$STAGED_VERSION" ] || [ ! -f /tmp/sd/.fw_upgrade/yi-hack/fw_upgrade_in_progress ]; then
        rm -rf /tmp/sd/.fw_upgrade /tmp/sd/.fw_upgrade.conf
        printf "Firmware validation failed after extraction."
        exit
    fi

    mkdir -p /tmp/sd/.fw_upgrade/yi-hack/etc
    cp -rf /tmp/sd/.fw_upgrade.conf/* /tmp/sd/.fw_upgrade/yi-hack/etc/
    rm -rf /tmp/sd/.fw_upgrade.conf

    printf "Firmware staged (%s), rebooting and upgrading." "$STAGED_VERSION"

    sync
    sync
    sync
    sleep 1
    reboot
fi
