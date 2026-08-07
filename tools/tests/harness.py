"""Test harness primitives — app lifecycle, baselines, waiting, assertions.

Built on tools/sim.py (reads the simulator) and tools/sonos.py (drives the
speakers). This module adds the things a TEST needs that an inspection session
does not: a known starting state, the ability to wait for something to happen
without sleeping blindly, and failures that say what was expected.

Two rules encoded here rather than remembered:

  * Never write to a RUNNING app's database. Every restore terminates the app
    first. A half-written SQLite file under a live GRDB connection is a corrupt
    library, and the app owns that file.

  * Log assertions read forward from a CURSOR, never from the whole file. The
    log is append-only and long-lived, so "did line X appear" is meaningless
    without "since when". Matching a line from an hour ago is the easiest way to
    write a test that passes for the wrong reason.
"""

import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import sim  # noqa: E402

BUNDLE_ID = "app.sorriva.ios"

BASELINES = os.path.expanduser("~/Library/Application Support/sorriva-test-baseline")
# Baselines live outside the repo ON PURPOSE: a snapshot contains
# keychain-2-debug.db, which holds the real NAS password. It must never be
# committed, and putting it under tools/ makes that an accident waiting to
# happen rather than an impossibility.


class TestFailure(AssertionError):
    """Raised by the expect_* helpers. The runner catches and reports these."""


# --------------------------------------------------------------------------
# Device


def device():
    booted = sim.booted_devices()
    if not booted:
        raise RuntimeError(
            "No booted simulator. Boot one in Xcode or with `xcrun simctl boot`.")
    return booted[0][0]


def _simctl(*args):
    return subprocess.run(["xcrun", "simctl"] + list(args),
                          capture_output=True, text=True)


def launch(udid):
    r = _simctl("launch", udid, BUNDLE_ID)
    if r.returncode != 0:
        raise RuntimeError("launch failed: %s" % (r.stderr.strip() or r.stdout.strip()))
    return r.stdout.strip()


def terminate(udid):
    """Stop the app and wait for it to actually be gone.

    simctl terminate returns before the process has exited. Restoring a snapshot
    into a container the app is still holding open is exactly the corruption this
    harness is supposed to make impossible, so we confirm rather than assume.
    """
    _simctl("terminate", udid, BUNDLE_ID)
    for _ in range(50):
        r = subprocess.run(["pgrep", "-f", "Sorriva.app/Sorriva"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            return True
        time.sleep(0.1)
    return False


# --------------------------------------------------------------------------
# Baselines


def baseline_path(name):
    return os.path.join(BASELINES, name) if name != "seeded" else BASELINES


def restore_baseline(udid, name="seeded"):
    """Put the simulator into a known state. Terminates the app first."""
    path = baseline_path(name)
    if not os.path.isdir(os.path.join(path, "container")):
        raise RuntimeError(
            "Baseline %r not found at %s. Create it with make_baseline()." % (name, path))
    terminate(udid)
    sim.restore(udid, path)


def make_baseline(udid, name):
    """Snapshot the CURRENT simulator state as a named baseline."""
    terminate(udid)
    dest = baseline_path(name)
    sim.snapshot(udid, dest)
    return dest


def derive_unscanned_baseline(udid):
    """Build the 'share configured, credentials present, never scanned' fixture.

    This is the starting state for every scan test, and the one state that cannot
    be reached without typing a password — which is why it is DERIVED from the
    seeded baseline rather than produced by walking the add-share UI. The share
    row and the keychain entry are copied wholesale; only the scan bookkeeping is
    cleared. Nothing is typed and no credential is read.
    """
    import shutil
    import sqlite3

    src = baseline_path("seeded")
    dest = baseline_path("unscanned")
    if not os.path.isdir(os.path.join(src, "container")):
        raise RuntimeError("Seeded baseline missing — snapshot a good state first.")
    shutil.rmtree(dest, ignore_errors=True)
    shutil.copytree(src, dest)

    db = os.path.join(dest, "container", "Library", "Application Support", "sorriva.sqlite")
    c = sqlite3.connect(db)
    c.execute("DELETE FROM tracks")
    c.execute("DELETE FROM albums")
    c.execute("DELETE FROM scan_ledger")
    c.execute("DELETE FROM scan_sessions")
    c.execute("DELETE FROM scan_skips")
    c.execute("DELETE FROM folder_stats")
    c.execute("UPDATE library_sources SET scanState='idle', lastScanned=NULL, trackCount=0")
    c.commit()
    c.close()
    return dest


# --------------------------------------------------------------------------
# Log cursor


class LogCursor:
    """Reads the debug log forward from where it was when you opened it."""

    def __init__(self, udid):
        self.udid = udid
        self.path = sim.log_path(udid)
        self.pos = os.path.getsize(self.path) if os.path.exists(self.path) else 0

    def new_text(self):
        if not os.path.exists(self.path):
            return ""
        with open(self.path, "r", errors="replace") as f:
            f.seek(self.pos)
            return f.read()

    def wait_for(self, pattern, timeout=60, poll=0.25):
        """Block until a line matching `pattern` appears after the cursor."""
        rx = re.compile(pattern)
        deadline = time.time() + timeout
        while time.time() < deadline:
            for line in self.new_text().splitlines():
                m = rx.search(line)
                if m:
                    return m
            time.sleep(poll)
        raise TestFailure(
            "timed out after %ss waiting for log line matching %r" % (timeout, pattern))

    def saw(self, pattern):
        return re.search(pattern, self.new_text()) is not None


# --------------------------------------------------------------------------
# Waiting on state


def wait_until(predicate, timeout=120, poll=0.5, what="condition"):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            last = predicate()
            if last:
                return last
        except Exception as e:          # a table may not exist yet mid-migration
            last = e
        time.sleep(poll)
    raise TestFailure("timed out after %ss waiting for %s (last=%r)" % (timeout, what, last))


def q(udid, sql):
    return sim.query(udid, sql)


def one(udid, sql):
    rows = sim.query(udid, sql)
    return rows[0][0] if rows else None


# --------------------------------------------------------------------------
# Assertions
#
# These raise rather than return, and they put the ACTUAL value in the message.
# A failure that says "expected 95, got 77" is a diagnosis; one that says
# "assertion failed" is a second debugging session.


def expect_eq(actual, expected, what):
    if actual != expected:
        raise TestFailure("%s: expected %r, got %r" % (what, expected, actual))
    return actual


def expect(condition, message):
    if not condition:
        raise TestFailure(message)
    return condition


def expect_ge(actual, floor, what):
    if actual < floor:
        raise TestFailure("%s: expected at least %r, got %r" % (what, floor, actual))
    return actual
