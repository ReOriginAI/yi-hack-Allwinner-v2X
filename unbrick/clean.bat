@ECHO OFF
SETLOCAL EnableDelayedExpansion

FOR %%x IN (y623 y28ga) DO (
    SET DIR=%%x
    FOR /F "tokens=*" %%g IN ('type !DIR!\filename') do (SET FILENAME=%%g)
    DEL !DIR!\rootfs_!FILENAME!.gz
    DEL !DIR!\home_!FILENAME!.gz
    DEL !DIR!\backup_!FILENAME!.gz
)
