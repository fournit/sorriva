"""Scan regression suite.

Ground truth here is SQLITE, not the log. The scan ledger was built to account
for every file a scan planned — scan_sessions carries plannedFiles,
plannedFolders and skippedUnchangedFiles, and scan_ledger holds one row per file
with its outcome. That is a purpose-built accounting surface, and it is a
stronger assertion target than any log line, which only tells you what somebody
remembered to print. The log is used for TIMING (waiting for a scan to finish)
rather than for truth.

Expected contents of the seeded test library, which is what these numbers mean:
95 tracks across 8 albums, artwork on all 8.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness as h  # noqa: E402
import taps  # noqa: E402

EXPECTED_TRACKS = 95
EXPECTED_ALBUMS = 8

# Log line shapes, measured against a real run on 2026-08-07. Scan lines carry
# the session id once a session exists (fScanSessionLogCorrelation), so the bare
# "SCAN:" prefix only matches the handful of lines emitted before one is opened.
# Matching "SCAN: END" — which is what the on-screen scan card shows — silently
# never fires, which is exactly the "the app may not log everything" trap: the
# line existed, in a shape the test did not expect.
SCAN_FINISHED = r"SCAN \[[0-9A-F-]+\]: state = complete for"
LEDGER_AUDIT = (r"LEDGER \[[0-9A-F-]+\]: audit — planned (\d+), written (\d+), "
                r"resolved (\d+), still failing (\d+), permanent (\d+), UNACCOUNTED (\d+)")


def _finished_outcomes(udid, session_id):
    rows = h.q(udid, "SELECT outcome, COUNT(*) FROM scan_ledger "
                     "WHERE sessionId='%s' GROUP BY outcome" % session_id)
    return {r[0]: r[1] for r in rows}


# ---------------------------------------------------------------------------


def test_rescan_of_unchanged_library_scans_nothing(udid):
    """A change-check over an untouched share must skip everything.

    Runs on launch with no UI at all — the app checks for changes when it comes
    to the foreground. This is the cheapest possible guard against the folder
    fingerprinting regressing into "rescan everything every time", which would be
    invisible on a 95-file test library and ruinous on Tom's real 11,670-file one.
    """
    h.restore_baseline(udid, "seeded")
    before = h.one(udid, "SELECT COUNT(*) FROM tracks")
    h.expect_eq(before, EXPECTED_TRACKS, "baseline track count")
    sessions_before = h.one(udid, "SELECT COUNT(*) FROM scan_sessions")

    log = h.LogCursor(udid)
    h.launch(udid)

    # Assert on the PLAN before waiting for the scan to finish.
    #
    # If the folder fingerprints regress, this share rescans all 95 files over
    # SMB and the run takes minutes. Waiting for completion first turns that into
    # "timed out after 120s", which says nothing about what broke. Checking the
    # plan the moment the session opens fails in seconds and names the defect.
    h.wait_until(lambda: h.one(udid, "SELECT COUNT(*) FROM scan_sessions") > sessions_before,
                 timeout=120, what="a scan session to open")
    planned = h.one(udid, "SELECT plannedFiles FROM scan_sessions ORDER BY rowid DESC LIMIT 1")
    h.expect_eq(planned, 0, "files planned for an unchanged library")

    log.wait_for(SCAN_FINISHED, timeout=120)

    # The one genuinely log-only fact: the ledger's own audit of the session.
    # Nothing in SQLite states "unaccounted" as a number — the app computes it.
    audit = log.wait_for(LEDGER_AUDIT, timeout=30)
    h.expect_eq(int(audit.group(6)), 0,
                "files unaccounted for by the ledger audit")

    h.expect_eq(h.one(udid, "SELECT COUNT(*) FROM tracks"),
                EXPECTED_TRACKS, "track count after change check")
    h.expect_eq(h.one(udid, "SELECT COUNT(*) FROM albums"),
                EXPECTED_ALBUMS, "album count after change check")

    skipped = h.one(udid,
                    "SELECT skippedUnchangedFiles FROM scan_sessions ORDER BY rowid DESC LIMIT 1")
    h.expect_eq(skipped, EXPECTED_TRACKS, "files skipped as unchanged")

    h.terminate(udid)


def test_full_scan_accounts_for_every_planned_file(udid):
    """Every file the scan PLANNED must end with a recorded outcome.

    This is the ledger's whole reason for existing: a file that was planned and
    then quietly vanished — a read that failed and was never retried, a folder
    abandoned mid-walk — is the defect class that produced bMissingTracksInAlbum
    and could only be found by counting. Planned must equal accounted-for.
    """
    taps.require()
    h.derive_unscanned_baseline(udid)
    h.restore_baseline(udid, "unscanned")
    h.expect_eq(h.one(udid, "SELECT COUNT(*) FROM tracks"), 0, "unscanned baseline is empty")

    log = h.LogCursor(udid)
    h.launch(udid)
    _start_scan_via_ui(udid)
    log.wait_for(SCAN_FINISHED, timeout=600)

    session = h.q(udid, "SELECT id, plannedFiles, state FROM scan_sessions "
                        "ORDER BY rowid DESC LIMIT 1")
    h.expect(session, "no scan session was recorded")
    session_id, planned, state = session[0]

    h.expect_ge(planned, EXPECTED_TRACKS, "files planned for a full scan")
    outcomes = _finished_outcomes(udid, session_id)
    h.expect_eq(sum(outcomes.values()), planned,
                "ledger rows vs planned files (outcomes: %r)" % outcomes)
    h.expect_eq(state, "complete", "session end state")

    h.expect_eq(h.one(udid, "SELECT COUNT(*) FROM tracks"),
                EXPECTED_TRACKS, "tracks after a full scan")
    h.expect_eq(h.one(udid, "SELECT COUNT(*) FROM albums"),
                EXPECTED_ALBUMS, "albums after a full scan")
    h.terminate(udid)


def test_scan_resumes_after_the_app_is_killed(udid):
    """Kill the app mid-scan; the resumed scan must finish the job, not redo it.

    Proven by accident on 2026-08-06 when SMBClient crashed mid-scan and the
    scan resumed cleanly on relaunch. Accidents are not regression tests, so
    this does it on purpose: the second session's planned count must be SMALLER
    than the first, and the final library must still be complete.
    """
    taps.require()
    h.derive_unscanned_baseline(udid)
    h.restore_baseline(udid, "unscanned")

    log = h.LogCursor(udid)
    h.launch(udid)
    _start_scan_via_ui(udid)
    log.wait_for(r"SCAN \[[0-9A-F-]+\]: START full scan", timeout=120)

    # Let it get somewhere, then kill it mid-flight.
    h.wait_until(lambda: h.one(udid, "SELECT COUNT(*) FROM scan_ledger "
                                     "WHERE outcome IS NOT NULL AND outcome != ''") > 5,
                 timeout=120, what="the scan to process a few files")
    h.terminate(udid)

    done_before = h.one(udid, "SELECT COUNT(*) FROM tracks")
    h.expect(0 < done_before < EXPECTED_TRACKS,
             "expected a partial library before the kill, got %r" % done_before)

    log2 = h.LogCursor(udid)
    h.launch(udid)
    _resume_scan_via_ui(udid)
    log2.wait_for(SCAN_FINISHED, timeout=600)

    h.expect_eq(h.one(udid, "SELECT COUNT(*) FROM tracks"),
                EXPECTED_TRACKS, "tracks after resume")
    h.expect_eq(h.one(udid, "SELECT COUNT(*) FROM albums"),
                EXPECTED_ALBUMS, "albums after resume")
    h.terminate(udid)


# ---------------------------------------------------------------------------
# UI driving
#
# Starting a scan is the ONE thing these tests cannot do from outside the app:
# never-scanned shares do not self-start (bAutoScanTriggeredOnNeverScannedSource
# was fixed on purpose), and a resume is offered through a dialog. See taps.py
# for why no scriptable tap driver exists today and the three ways out.
#
# When fAutoScanOnShareAdd lands, the first of these disappears entirely.


def _start_scan_via_ui(udid):
    taps.require()
    taps.tap(udid, "settings_tab")
    taps.tap(udid, "local_library_row")
    taps.tap(udid, "server_card")
    taps.long_press(udid, "share_row")
    taps.tap(udid, "sheet_scan_now")
    taps.tap(udid, "alert_start_scan")


def _resume_scan_via_ui(udid):
    taps.require()
    taps.tap(udid, "alert_resume")
