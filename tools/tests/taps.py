"""UI driving — and an honest account of what is available.

THE CONSTRAINT: as of 2026-08-07 this Mac has no scriptable way to tap the
simulator. `xcrun simctl ui` sets appearance and content size, not touches.
`idb` and `cliclick` are not installed. The iOS Simulator MCP tool CAN tap, but
it is available to Claude inside a session — it is not a command a standalone
Python process can call.

WHY IT MATTERS: a scan cannot be started from outside the app. Never-scanned
shares deliberately do not self-start (bAutoScanTriggeredOnNeverScannedSource
was fixed on purpose), and a resume is offered through a dialog. So the two
tests that need a full scan need somebody to press a button.

DECIDED 2026-08-07: XCUITest, and PARKED until the UI redesign lands.

Tom's call, and the reasoning is worth keeping: given a choice between a
third-party dependency and none, take none. idb would have unblocked the two
skipped tests today, but it costs a trusted third-party Homebrew tap, a Python
package and a companion daemon that has to track each Xcode release. XCUITest is
Apple's own, needs no trust grant, survives Xcode upgrades, and finds elements by
identity rather than by coordinate — so it does not break every time a layout
moves, which is the failure mode the COORDS table below is waiting to have.

Parked rather than built now because the UI it would drive is about to be
redesigned, and coordinates or identifiers written against the current screens
would be thrown away. The trigger to pick this up is the full regression pass on
the new UI — which is also when the wider ambition lands: a script that exercises
the entire UI and every feature, not just the scan path.

Until then the two tap-dependent scan tests SKIP with a reason. A skipped test
that says why is honest; a failing test everyone learns to ignore is worse than
no test at all. The idb hooks below stay because they cost nothing and light up
automatically if idb ever appears on PATH.
"""

import shutil
import subprocess

# Device points for iPhone 17 Pro (402x874). These are the harness's most
# brittle surface — a layout change silently moves them, and the failure looks
# like a scan bug rather than a coordinate bug. First thing to check when a
# tap-driven test fails for no apparent reason.
COORDS = {
    "settings_tab":        (330, 740),
    "local_library_row":   (201, 285),
    "server_card":         (201, 289),
    "share_row":           (300, 486),
    "sheet_scan_now":      (85, 456),
    "alert_start_scan":    (275, 505),
    "alert_resume":        (275, 505),
}


class TapsUnavailable(RuntimeError):
    """No scriptable tap driver on this machine."""


def driver():
    """Return the name of an available driver, or None."""
    return "idb" if shutil.which("idb") else None


def available():
    return driver() is not None


def require():
    if not available():
        raise TapsUnavailable(
            "no scriptable tap driver — install idb (brew tap facebook/fb && "
            "brew install idb-companion; pip3 install fb-idb) or run this test "
            "with Claude driving the simulator in-session")


def tap(udid, name):
    require()
    x, y = COORDS[name]
    r = subprocess.run(["idb", "ui", "tap", "--udid", udid, str(x), str(y)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("tap %s failed: %s" % (name, r.stderr.strip()))


def long_press(udid, name, duration=0.9):
    require()
    x, y = COORDS[name]
    r = subprocess.run(["idb", "ui", "tap", "--udid", udid,
                        "--duration", str(duration), str(x), str(y)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("long press %s failed: %s" % (name, r.stderr.strip()))
