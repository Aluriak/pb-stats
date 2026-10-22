#!/bin/sh
LOG=/mnt/ext1/reading-stats-log.txt
BIN="/mnt/ext1/applications/Reading Stats.bin"
echo "== run" >> $LOG
"$BIN" >> $LOG 2>&1
echo "exit code: $?" >> $LOG
