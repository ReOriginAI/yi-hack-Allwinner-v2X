#!/bin/sh
# Per-file FTP receipts live beside recordings on SD, never in a RAM ledger.
# Caller supplies get_config, uploadToFtp and logAdd.

checkFiles ()
{
    FTP_FILE_DELETE_AFTER_UPLOAD="$(get_config FTP_FILE_DELETE_AFTER_UPLOAD)"
    # A receipt also belongs to a destination. Changing servers/accounts/paths
    # makes retained recordings eligible for the new destination.
    FTP_DESTINATION=$(printf '%s\n' "ftp-receipt-v1" \
        "$(get_config FTP_HOST)" "$(get_config FTP_DIR)" \
        "$(get_config FTP_DIR_TREE)" "$(get_config FTP_USERNAME)" |
        md5sum | cut -d ' ' -f 1)
    [ -n "$FTP_DESTINATION" ] || return 1

    logAdd "[INFO] checkFiles"

    # Retention/manual deletion must not leave orphan receipts on SD.
    find "$FOLDER_TO_WATCH" -mindepth "$FOLDER_MINDEPTH" -type f \
        \( -name '*.mp4.ftp-uploaded' -o -name '*.mp4.ftp-uploaded.tmp' \) |
    while IFS= read -r receipt; do
        original=${receipt%.tmp}
        original=${original%.ftp-uploaded}
        [ -f "$original" ] || rm -f "$receipt"
    done

    # Stream the queue instead of accumulating every path in RAM. Never use a
    # timestamp watermark: same-minute clips and late/older files are distinct.
    find "$FOLDER_TO_WATCH" -mindepth "$FOLDER_MINDEPTH" -type f \
        -name "$FILE_WATCH_PATTERN" |
    while IFS= read -r file; do
        FILE_SUM=$(md5sum "$file" 2>/dev/null) || continue
        RECEIPT="$file.ftp-uploaded"
        EXPECTED_RECEIPT="$FTP_DESTINATION $FILE_SUM"

        if [ "$(cat "$RECEIPT" 2>/dev/null)" != "$EXPECTED_RECEIPT" ]; then
            if ! uploadToFtp -- "$file"; then
                logAdd "[ERROR] checkFiles: uploadToFtp FAILED - [$file]. Will retry next scan."
                # A failed file cannot prevent unrelated pending uploads.
                continue
            fi
            # A file that changed during transfer is still pending. In
            # particular, never delete it or claim the new contents were sent.
            if [ "$(md5sum "$file" 2>/dev/null)" != "$FILE_SUM" ]; then
                logAdd "[WARN] checkFiles: file changed during upload - [$file]. Will retry next scan."
                continue
            fi
            # Commit only after successful transfer. If SD state cannot be
            # saved, retain the clip so a later scan can retry it.
            if ! (umask 077; printf '%s\n' "$EXPECTED_RECEIPT" > "$RECEIPT.tmp") ||
               ! mv -f "$RECEIPT.tmp" "$RECEIPT"; then
                logAdd "[ERROR] checkFiles: could not save upload receipt - [$file]. Keeping recording."
                continue
            fi
            sync
            logAdd "[INFO] checkFiles: uploadToFtp SUCCEEDED - [$file]."
        fi

        if [ "$FTP_FILE_DELETE_AFTER_UPLOAD" = "yes" ]; then
            if rm -f "$file" "${file%.mp4}.jpg"; then
                rm -f "$RECEIPT" "$RECEIPT.tmp"
            else
                logAdd "[ERROR] checkFiles: could not delete uploaded recording - [$file]."
            fi
        fi
    done

    find "$FOLDER_TO_WATCH" -mindepth "$FOLDER_MINDEPTH" -type d |
    while IFS= read -r directory; do
        rmdir "$directory" 2>/dev/null || true
    done
    return 0
}
