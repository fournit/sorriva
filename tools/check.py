#!/usr/bin/env python3
"""Compare what the speakers are doing with what the app believes.

    python3 tools/check.py                 # speakers + app, side by side
    python3 tools/check.py --snapshot DIR  # save simulator state (container + keychain)
    python3 tools/check.py --restore DIR   # put it back (app must not be running)

This is the assertion that mattered all week and could not be made: every bug in
the "ghosts" family was app-says-X, speaker-says-Y, and confirming it needed a
human to look at a phone. Nothing here starts or stops audio.

Known limits — worth reading before trusting a green line:
  * The app's DISPLAY state is in memory. This reads what it RESOLVED, from its
    log, which is the closest readable proxy until UI driving works. A zone can
    resolve correctly and still render wrongly; that is precisely the frozen-track
    bug, and this would not have caught it.
  * The log is append-only, so a resolution can be stale if a zone has since
    changed. Cross-check the timestamp when something looks wrong.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sonos, sim

UDID = os.environ.get("SORRIVA_SIM_UDID", "7DA336AC-635C-420F-BFB1-1A4BF4543AD4")


def main():
    if "--snapshot" in sys.argv:
        d = sys.argv[sys.argv.index("--snapshot") + 1]
        print("snapshot ->", sim.snapshot(UDID, d)); return
    if "--restore" in sys.argv:
        d = sys.argv[sys.argv.index("--restore") + 1]
        sim.restore(UDID, d); print("restored <-", d); return

    print("=== APP (simulator %s) ===" % UDID[:8])
    if not sim.container(UDID):
        print("  Sorriva not installed — app-side checks unavailable")
        resolved = {}
    else:
        lib = sim.library(UDID)
        print("  library: %(tracks)d tracks, %(albums)d albums, %(artists)d artists, "
              "%(stations)d stations, art on %(albums_with_art)d albums" % lib)
        print("  sources: %(sources)d, scanState=%(scan_state)s" % lib)
        resolved = sim.resolved_stations(UDID)

    print()
    print("=== SPEAKERS vs APP ===")
    print("  %-16s %-9s %-7s %-34s %s" % ("ZONE", "STATE", "TRACKS", "SPEAKER SAYS", "APP RESOLVED"))
    print("  " + "-" * 104)
    for ip, room, uuid, _model in sonos.discover():
        if not sonos.supports_transport(ip):
            continue                      # subs/satellites — no AVTransport
        t = sonos.transport(ip)
        uri = t["track_uri"] or t["current_uri"]
        if not uri:
            continue
        # What the speaker is actually on, in human terms
        if uri.startswith("x-file-cifs://"):
            speaker = "local: " + uri.rsplit("/", 1)[-1][:26]
        elif uri.startswith("x-rincon:"):
            speaker = "grouped -> coordinator"
        elif uri.startswith("x-rincon-queue:"):
            speaker = "queue (%s tracks)" % t["tracks"]
        else:
            speaker = (t["stream_content"].split("TITLE ", 1)[-1].split("|")[0].strip()
                       if "TITLE " in t["stream_content"] else "stream")
            speaker = "stream: " + speaker[:26]
        kind, name = resolved.get(uuid, ("", "—"))
        print("  %-16s %-9s %-7s %-34s %s" % (room[:16], t["state"][:9], t["tracks"],
                                              speaker[:34], name[:30]))
    print()
    print("  note: APP RESOLVED is the last thing the app's log recorded for that zone,")
    print("        not necessarily what it is displaying now. See the docstring.")


if __name__ == "__main__":
    main()
