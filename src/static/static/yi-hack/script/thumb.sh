#!/tmp/sd/yi-hack/bin/busybox ash
. "${YI_HACK_PREFIX:-/tmp/sd/yi-hack}/script/storage.sh" || exit 1
sd_present || exit 0
#
# Command line:
# 	ash "/tmp/sd/yi-hack/script/thumb.sh" cron
# 	ash "/tmp/sd/yi-hack/script/thumb.sh" start
# 	ash "/tmp/sd/yi-hack/script/thumb.sh" stop
#
CONF_FILE="etc/system.conf"

YI_HACK_PREFIX="/tmp/sd/yi-hack"
. "$YI_HACK_PREFIX/script/service_lock.sh" || exit 1

get_config()
{
    key=$1
    grep -w $1 $YI_HACK_PREFIX/$CONF_FILE | cut -d "=" -f2-
}
. "$YI_HACK_PREFIX/script/operation_timeout.sh" || exit 1

# Setup env.
export PATH=/usr/bin:/usr/sbin:/bin:/sbin:/home/base/tools:/home/app/localbin:/home/base:/tmp/sd/yi-hack/bin:/tmp/sd/yi-hack/sbin:/tmp/sd/yi-hack/usr/bin:/tmp/sd/yi-hack/usr/sbin
export LD_LIBRARY_PATH=/lib:/usr/lib:/home/lib:/home/qigan/lib:/home/app/locallib:/tmp/sd:/tmp/sd/gdb:/tmp/sd/yi-hack/lib
#
# Script Configuration.
FOLDER_TO_WATCH="/tmp/sd/record"
FOLDER_MINDEPTH="1"
FILE_WATCH_PATTERN="*.mp4"
SLEEP_CYCLE_SECONDS="45"
#
# Runtime Variables.
SCRIPT_FULLFN="thumb.sh"
SCRIPT_NAME="thumb"
LOGFILE="/tmp/${SCRIPT_NAME}.log"
LOG_MAX_LINES="200"
STOPFILE="/tmp/yi-hack-thumb.stop"


#
# -----------------------------------------------------
# -------------- START OF FUNCTION BLOCK --------------
# -----------------------------------------------------


lbasename ()
{
	echo ${1:0:$((${#1} - 4))}
}


logAdd ()
{
    TMP_DATETIME="$(date '+%Y-%m-%d [%H-%M-%S]')"
    "$YI_HACK_PREFIX/script/bounded_log.sh" "$LOGFILE" "$TMP_DATETIME $*"
    echo "$TMP_DATETIME $*"
    return 0
}


lstat ()
{
	if [ -d "${1}" ]; then
		ls -a -l -td "${1}" | awk '{k=0;for(i=0;i<=8;i++)k+=((substr($1,i+2,1)~/[rwx]/) \
				 *2^(8-i));if(k)printf("%0o ",k);print}' | \
				 cut -d " " -f 1
	else
		ls -a -l "${1}" | awk '{k=0;for(i=0;i<=8;i++)k+=((substr($1,i+2,1)~/[rwx]/) \
				 *2^(8-i));if(k)printf("%0o ",k);print}' | \
				 cut -d " " -f 1
	fi
}


checkFiles ()
{
	#
	logAdd "[INFO] checkFiles"
	#
	# Search for new files.
	if [ -f "/usr/bin/sort" ] || [ -f "/tmp/sd/yi-hack/usr/bin/sort" ]; then
		# Default: Optimized for busybox
		L_FILE_LIST="$(find "${FOLDER_TO_WATCH}" -mindepth ${FOLDER_MINDEPTH} -type f \( -name "${FILE_WATCH_PATTERN}" \) | sort -k 1 -n)"
	else
		# Alternative: Unsorted output
		L_FILE_LIST="$(find "${FOLDER_TO_WATCH}" -mindepth ${FOLDER_MINDEPTH} -type f \( -name "${FILE_WATCH_PATTERN}" \))"
	fi
	if [ -z "${L_FILE_LIST}" ]; then
		return 0
	fi
	#
	echo "${L_FILE_LIST}" | while read file; do
		[ ! -e "$STOPFILE" ] || break
		BASE_NAME=$(lbasename "$file")
		if [ ! -f $BASE_NAME.jpg ]; then
			runWithTimeout 30 minimp4_yi -t 1 "$file" "$BASE_NAME.h26x"
			if [ $? -ne 0 ]; then
				logAdd "[ERROR] checkFiles: demux mp4 FAILED - [${file}]."
				rm -f "$BASE_NAME.h26x"
				continue
			fi
			if [ "${#file}" == "44" ]; then
				TIME_STAMP="${file:15:4}-${file:20:2}-${file:23:2} ${file:26:2}:${file:32:2}:${file:35:2}"
			else
				TIME_STAMP="${file:15:4}-${file:20:2}-${file:23:2} ${file:26:2}:${file:30:2}:${file:33:2}"
			fi
			runWithTimeout 30 imggrabber -f "$BASE_NAME.h26x" -r low -w -t "$TIME_STAMP" > "$BASE_NAME.jpg"
			if [ $? -ne 0 ]; then
				logAdd "[ERROR] checkFiles: create jpg FAILED - [${file}]. Using fallback.jpg."
				rm -f $BASE_NAME.h26x
				rm -f $BASE_NAME.jpg
				cp $YI_HACK_PREFIX/etc/fallback.jpg $BASE_NAME.jpg
			fi
			rm -f $BASE_NAME.h26x
			logAdd "[INFO] checkFiles: createThumb SUCCEEDED - [${file}]."
			sync
		else
			#logAdd "[INFO] checkFiles: ignore file [${file}] - already present."
			if [ -s $BASE_NAME.jpg ]; then
				logAdd "[INFO] checkFiles: ignore file [${file}] - already present."
			else
				rm -f $BASE_NAME.jpg
				logAdd "[DEBUG] checkFiles: ignore file [${file}] - already present but ZERO, deleted for next try"
			fi
		fi
		#
	done
	#
	return 0
}


serviceMain ()
{
	#
	# Usage:		serviceMain	[--one-shot]
	# Called By:	MAIN
	#
	logAdd "[INFO] === SERVICE START ==="
	# sleep 10
	while (true); do
		[ ! -e "$STOPFILE" ] || break
		# Check if folder exists.
		if [ ! -d "${FOLDER_TO_WATCH}" ]; then
			mkdir -p "${FOLDER_TO_WATCH}"
		fi
		#
		# Ensure correct file permissions.
		if ( ! lstat "${FOLDER_TO_WATCH}/" | grep -q "^755$" ); then
			logAdd "[WARN] Adjusting folder permissions to 0755 ..."
			chmod -R 0755 "${FOLDER_TO_WATCH}"
		fi
		#
		checkFiles
		#
		[ ! -e "$STOPFILE" ] || break
		if [ "${1}" = "--one-shot" ]; then
			break
		fi
		#
		sleep ${SLEEP_CYCLE_SECONDS}
	done
	return 0
}
# ---------------------------------------------------
# -------------- END OF FUNCTION BLOCK --------------
# ---------------------------------------------------
#
# set +m
trap "" SIGHUP
# Serialize stop requests with acquisition/clearing of a new worker's state.
case "$1" in
    cron|start|stop) yi_lock thumb-control || exit $? ;;
esac
#
if [ "${1}" = "cron" ]; then
	yi_lock thumb
	LOCK_STATUS=$?
	if [ "$LOCK_STATUS" -ne 0 ]; then
		[ "$LOCK_STATUS" -eq 75 ] || exit "$LOCK_STATUS"
		logAdd "[INFO] === SERVICE ALREADY RUNNING ==="
		exit 0
	fi
	rm -f "$STOPFILE"
	yi_lock -u thumb-control || exit 1
	serviceMain --one-shot
	logAdd "[INFO] === SERVICE STOPPED ==="
	exit 0
elif [ "${1}" = "start" ]; then
	yi_lock thumb
	LOCK_STATUS=$?
	if [ "$LOCK_STATUS" -ne 0 ]; then
		[ "$LOCK_STATUS" -eq 75 ] || exit "$LOCK_STATUS"
		logAdd "[INFO] === SERVICE ALREADY RUNNING ==="
		exit 0
	fi
	rm -f "$STOPFILE"
	yi_lock -u thumb-control || exit 1
	serviceMain
	exit 0
elif [ "${1}" = "stop" ]; then
    # Keep ownership while finishing/aborting the current bounded operation.
    # Killing only a parent shell could orphan a transfer and permit overlap.
    : > "$STOPFILE" || exit 1
    yi_lock thumb
    LOCK_STATUS=$?
    case "$LOCK_STATUS" in
        0) logAdd "[INFO] === SERVICE STOPPED ===" ;;
        75) logAdd "[INFO] Stop requested; current bounded work must finish before restart." ;;
        *) exit "$LOCK_STATUS" ;;
    esac
    exit 0
fi
#
logAdd "[ERROR] Parameter #1 missing."
logAdd "[INFO] Usage: ${SCRIPT_FULLFN} {cron|start|stop}"
exit 99
