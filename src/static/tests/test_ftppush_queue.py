#!/usr/bin/env python3
"""Exercise the production FTP queue under BusyBox ash, with fake transfers."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

QUEUE = Path(__file__).resolve().parents[1] / "static/yi-hack/script/ftppush_queue.sh"
HARNESS = r'''
. "$1"
FOLDER_TO_WATCH="$ROOT/record"
FOLDER_MINDEPTH=1
FILE_WATCH_PATTERN='*.mp4'
get_config() {
    case "$1" in
        FTP_FILE_DELETE_AFTER_UPLOAD) echo "$DELETE";;
        FTP_HOST) echo "$DEST";;
        FTP_DIR) echo recordings;;
        FTP_DIR_TREE) echo yes;;
        FTP_USERNAME) echo camera;;
    esac
}
uploadToFtp() {
    printf '%s\n' "$2" >> "$ROOT/attempts"
    [ "$2" != "$FAIL" ] || return 1
    [ "$2" != "$CHANGE" ] || echo changed >> "$2"
    return 0
}
logAdd() { printf '%s\n' "$*" >> "$ROOT/log"; }
sync() { :; }
checkFiles
'''


class FtpQueueTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ftp-queue-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "record").mkdir()

    def clip(self, relative, content="video"):
        p = self.root / "record" / relative
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
        return p

    def scan(self, delete="no", dest="server-a", fail="", change=""):
        env = dict(os.environ, ROOT=str(self.root), DELETE=delete, DEST=dest,
                   FAIL=str(fail), CHANGE=str(change))
        subprocess.run(["busybox", "ash", "-c", HARNESS, "test", str(QUEUE)],
                       env=env, check=True, capture_output=True, text=True)

    def attempts(self):
        p = self.root / "attempts"
        return p.read_text().splitlines() if p.exists() else []

    def receipt(self, p):
        return Path(str(p) + ".ftp-uploaded")

    def test_same_minute_clips_both_upload(self):
        a = self.clip("2026Y10M10D00H/E830M01S10.mp4")
        b = self.clip("2026Y10M10D00H/E830M25S10.mp4")
        self.scan()
        self.assertCountEqual(self.attempts(), [str(a), str(b)])

    def test_late_older_clip_uploads_after_newer_success(self):
        newer = self.clip("2026Y10M10D01H/E830M01S10.mp4")
        self.scan()
        older = self.clip("2020Y04M17D20H/E816M37S23.mp4")
        # The obsolete watermark must not affect the new queue.
        (self.root / "last_file_sent").write_text("2026-10-10T01:30")
        self.scan()
        self.assertCountEqual(self.attempts(), [str(newer), str(older)])

    def test_receipts_survive_fresh_process_and_destination_change(self):
        a = self.clip("hour/clip.mp4")
        self.scan()
        self.scan()
        self.assertEqual(self.attempts(), [str(a)])
        self.scan(dest="server-b")
        self.assertEqual(self.attempts(), [str(a), str(a)])

    def test_failed_upload_retained_and_other_file_not_blocked(self):
        a = self.clip("hour/first.mp4")
        b = self.clip("hour/second.mp4")
        self.scan(delete="yes", fail=a)
        self.assertTrue(a.exists())
        self.assertFalse(self.receipt(a).exists())
        self.assertFalse(b.exists())
        self.scan(delete="yes")
        self.assertFalse(a.exists())
        self.assertEqual(self.attempts().count(str(b)), 1)
        self.assertEqual(self.attempts().count(str(a)), 2)

    def test_changed_contents_reupload_even_same_name_and_size(self):
        a = self.clip("hour/clip.mp4", "aaaa")
        self.scan()
        a.write_text("bbbb")
        self.scan()
        self.assertEqual(self.attempts(), [str(a), str(a)])

    def test_change_during_upload_never_receipted_or_deleted(self):
        a = self.clip("hour/clip.mp4")
        self.scan(delete="yes", change=a)
        self.assertTrue(a.exists())
        self.assertFalse(self.receipt(a).exists())
        self.scan(delete="yes")
        self.assertFalse(a.exists())

    def test_receipt_write_failure_keeps_clip(self):
        a = self.clip("hour/clip.mp4")
        Path(str(a) + ".ftp-uploaded.tmp").mkdir()
        self.scan(delete="yes")
        self.assertTrue(a.exists())
        self.assertFalse(self.receipt(a).exists())

    def test_temporary_recording_ignored_and_paths_with_spaces_supported(self):
        a = self.clip("hour with space/clip one.mp4")
        pending = self.clip("tmp.mp4.tmp")
        self.scan(delete="yes")
        self.assertEqual(self.attempts(), [str(a)])
        self.assertTrue(pending.exists())
        self.assertFalse(a.parent.exists())

    def test_orphan_receipts_pruned_and_success_cleanup_removes_thumbnail(self):
        a = self.clip("hour/clip.mp4")
        self.scan()
        a.unlink()
        Path(str(a) + ".ftp-uploaded.tmp").write_text("interrupted")
        self.scan()
        self.assertFalse(self.receipt(a).exists())
        self.assertFalse(a.parent.exists())
        b = self.clip("hour2/clip.mp4")
        jpg = b.with_suffix(".jpg")
        jpg.write_text("thumbnail")
        self.scan(delete="yes")
        self.assertFalse(jpg.exists())
        self.assertFalse(self.receipt(b).exists())

    def test_enabling_delete_cleans_retained_success_without_reupload(self):
        a = self.clip("hour/clip.mp4")
        self.scan()
        self.scan(delete="yes")
        self.assertEqual(self.attempts(), [str(a)])
        self.assertFalse(a.exists())
        self.assertFalse(self.receipt(a).exists())


if __name__ == "__main__":
    unittest.main()
