#!/bin/sh
# motiond diagnostics live in RAM. Keep one 64 KiB current file and one backup.
# A streaming logger avoids copy/truncate races with motiond's open descriptor.
[ "$#" -eq 1 ] || exit 2
exec awk -v logfile="$1" -v limit=65536 '
function rotate(    line) {
    close(logfile)
    printf "%s", "" > (logfile ".1")
    while ((getline line < logfile) > 0)
        print line > (logfile ".1")
    close(logfile)
    close(logfile ".1")
    printf "%s", "" > logfile
    close(logfile)
    bytes = 0
}
BEGIN {
    # Startup is a fresh current logfile; the last rotated generation is retained.
    printf "%s", "" > logfile
    close(logfile)
    bytes = 0
}
{
    line = $0
    if (length(line) >= limit)
        line = substr(line, 1, limit - 1)
    n = length(line) + 1
    if (bytes + n > limit)
        rotate()
    print line >> logfile
    fflush(logfile)
    bytes += n
}
'
