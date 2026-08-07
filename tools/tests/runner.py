"""Test runner.

    python3 tools/tests/runner.py              # everything
    python3 tools/tests/runner.py scan         # one suite
    python3 tools/tests/runner.py scan:rescan  # one test

Every test starts from a named baseline and the runner restores the seeded
baseline afterwards WHETHER OR NOT the test passed. A failing test that leaves
the simulator half-scanned makes the next test fail for reasons that have
nothing to do with the code it is testing — the failure mode that makes a suite
untrustworthy, and the reason people stop running it.
"""

import importlib
import os
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness  # noqa: E402
import taps  # noqa: E402

SUITES = ["scan"]

GREEN, RED, YELLOW, DIM, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[0m"


def collect(selector=None):
    """Find test functions. A test is a module-level `test_*` callable."""
    suite_name, _, test_name = (selector or "").partition(":")
    found = []
    for suite in SUITES:
        if suite_name and suite != suite_name:
            continue
        mod = importlib.import_module("test_%s" % suite)
        for name in sorted(dir(mod)):
            if not name.startswith("test_"):
                continue
            if test_name and not name.endswith(test_name) and test_name not in name:
                continue
            found.append((suite, name, getattr(mod, name)))
    return found


def main():
    selector = sys.argv[1] if len(sys.argv) > 1 else None
    udid = harness.device()

    if not os.path.isdir(os.path.join(harness.BASELINES, "container")):
        print("%sNo seeded baseline at %s%s" % (RED, harness.BASELINES, RESET))
        print("Snapshot a known-good simulator first:")
        print("  python3 -c \"import sys;sys.path.insert(0,'tools');import sim;"
              "sim.snapshot(sim.booted_devices()[0][0], '%s')\"" % harness.BASELINES)
        return 2

    tests = collect(selector)
    if not tests:
        print("No tests matched %r" % selector)
        return 2

    print("%s%d test(s) on %s%s" % (DIM, len(tests), udid, RESET))
    if not taps.available():
        print("%stap driver: none — tests needing a scan start will SKIP%s" % (YELLOW, RESET))
    print()
    passed, failed, skipped = [], [], []

    for suite, name, fn in tests:
        label = "%s:%s" % (suite, name.replace("test_", ""))
        started = time.time()
        sys.stdout.write("  %-46s " % label)
        sys.stdout.flush()
        try:
            fn(udid)
        except taps.TapsUnavailable as e:
            # Not a failure. The test is written and correct; the machine cannot
            # press the button yet. Saying so is honest — turning it red would
            # train everyone to ignore red.
            skipped.append((label, str(e)))
            print("%sskip%s  (%.1fs)" % (YELLOW, RESET, time.time() - started))
        except harness.TestFailure as e:
            failed.append((label, str(e), None))
            print("%sFAIL%s  (%.1fs)" % (RED, RESET, time.time() - started))
        except Exception:
            failed.append((label, "unexpected error", traceback.format_exc()))
            print("%sERROR%s (%.1fs)" % (RED, RESET, time.time() - started))
        else:
            passed.append(label)
            print("%sok%s    (%.1fs)" % (GREEN, RESET, time.time() - started))
        finally:
            # Always put the simulator back, even after a failure.
            try:
                harness.restore_baseline(udid, "seeded")
            except Exception as e:
                print("    %swarning: could not restore baseline: %s%s" % (RED, e, RESET))

    print()
    for label, msg in skipped:
        print("%s%s skipped%s — %s" % (YELLOW, label, RESET, msg))
    if skipped:
        print()
    for label, msg, tb in failed:
        print("%s%s%s\n    %s" % (RED, label, RESET, msg))
        if tb:
            print("".join("    " + l for l in tb.splitlines(True)))
    print("%s%d passed%s, %s%d failed%s, %s%d skipped%s" %
          (GREEN, len(passed), RESET,
           RED if failed else DIM, len(failed), RESET,
           YELLOW if skipped else DIM, len(skipped), RESET))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
