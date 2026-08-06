"""Sorriva running in the iOS Simulator — read its state without asking a human.

The gap this closes: through 2026-08-05 the speakers were fully visible over SOAP
and the app was not, so every question of the form "the app shows X but the speaker
is doing Y" needed Tom to look at his phone. In the Simulator the app's log,
database and process are all files on this Mac.

Everything here is READ-ONLY except snapshot/restore, which are explicit.
"""
import glob
import os
import plistlib
import shutil
import sqlite3
import subprocess

BUNDLE_ID = "app.sorriva.ios"
DEVICES = os.path.expanduser("~/Library/Developer/CoreSimulator/Devices")


def booted_devices():
    """[(udid, name)] for booted simulators."""
    out = subprocess.run(["xcrun", "simctl", "list", "devices"],
                         capture_output=True, text=True).stdout
    found = []
    for line in out.splitlines():
        if "(Booted)" in line:
            name = line.strip().split(" (")[0]
            udid = line.split("(")[1].split(")")[0]
            found.append((udid, name))
    return found


def container(udid):
    """Sorriva's data container for a device, or None.

    Located by metadata rather than remembered: the UUID changes when the app is
    reinstalled, which caught us out mid-session on 2026-08-06.
    """
    for c in glob.glob(os.path.join(DEVICES, udid, "data/Containers/Data/Application/*/")):
        meta = os.path.join(c, ".com.apple.mobile_container_manager.metadata.plist")
        try:
            with open(meta, "rb") as f:
                if plistlib.load(f).get("MCMMetadataIdentifier") == BUNDLE_ID:
                    return c
        except Exception:
            continue
    return None


def db_path(udid):
    c = container(udid)
    return os.path.join(c, "Library/Application Support/sorriva.sqlite") if c else None


def log_path(udid):
    c = container(udid)
    p = os.path.join(c, "Documents/sorriva-debug.log") if c else None
    return p if p and os.path.exists(p) else None


def query(udid, sql):
    """Read-only query against the app's live database.

    Opened read-only on purpose: the app may be running, and this must never be
    the thing that corrupts its state.
    """
    p = db_path(udid)
    if not p or not os.path.exists(p):
        return []
    conn = sqlite3.connect("file:%s?mode=ro" % p, uri=True)
    try:
        return conn.execute(sql).fetchall()
    finally:
        conn.close()


def library(udid):
    """Counts that say whether the app has a usable library."""
    def one(sql):
        r = query(udid, sql)
        return r[0][0] if r else 0
    return {
        "tracks": one("select count(*) from tracks"),
        "albums": one("select count(*) from albums"),
        "artists": one("select count(*) from artists"),
        "stations": one("select count(*) from stations"),
        "albums_with_art": one("select count(*) from albums where artPathThumb is not null"),
        "sources": one("select count(*) from library_sources"),
        "scan_state": (query(udid, "select scanState from library_sources limit 1") or [("none",)])[0][0],
    }


def resolved_stations(udid, limit=40):
    """What the app most recently resolved each zone to, from its own log.

    The app's display state lives in memory, so this is the closest readable
    proxy until UI driving is available: CONTEXT lines record what a URI was
    resolved to, which is exactly the claim worth checking against a speaker.
    """
    p = log_path(udid)
    if not p:
        return {}
    out = {}
    with open(p, errors="replace") as f:
        for line in f:
            if "CONTEXT: resolved station from URI" in line:
                # "… — <name> for <RINCON_…>"
                try:
                    name = line.split("— ", 1)[1].rsplit(" for ", 1)[0].strip()
                    zone = line.rsplit(" for ", 1)[1].strip()
                    out[zone] = ("station", name)
                except IndexError:
                    continue
            elif "CONTEXT: resolved local URI for" in line:
                try:
                    zone = line.split("for ", 1)[1].split(" ", 1)[0].strip()
                    out[zone] = ("local", line.rsplit("→ ", 1)[1].strip())
                except IndexError:
                    continue
    return dict(list(out.items())[-limit:])


def tail_log(udid, n=40, contains=None):
    p = log_path(udid)
    if not p:
        return []
    with open(p, errors="replace") as f:
        lines = [l.rstrip("\n") for l in f]
    if contains:
        lines = [l for l in lines if contains in l]
    return lines[-n:]


def snapshot(udid, dest):
    """Copy the container AND the device keychain.

    The keychain is DEVICE-level, not in the app container, so a container-only
    copy silently loses the NAS credentials. Playback survives that (Sonos fetches
    from the NAS itself) but scanning does not.
    """
    c = container(udid)
    if not c:
        raise RuntimeError("Sorriva not installed on %s" % udid)
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(os.path.join(dest, "container"), exist_ok=True)
    os.makedirs(os.path.join(dest, "keychain"), exist_ok=True)
    for sub in ("Library", "Documents"):
        src = os.path.join(c, sub)
        if os.path.isdir(src):
            shutil.copytree(src, os.path.join(dest, "container", sub))
    for kc in glob.glob(os.path.join(DEVICES, udid, "data/Library/Keychains/keychain-2-debug.db*")):
        shutil.copy2(kc, os.path.join(dest, "keychain"))
    return dest


def restore(udid, src):
    """Put a snapshot back. The app must not be running."""
    c = container(udid)
    if not c:
        raise RuntimeError("Sorriva not installed on %s" % udid)
    for sub in ("Library", "Documents"):
        s = os.path.join(src, "container", sub)
        if os.path.isdir(s):
            shutil.rmtree(os.path.join(c, sub), ignore_errors=True)
            shutil.copytree(s, os.path.join(c, sub))
    kdir = os.path.join(DEVICES, udid, "data/Library/Keychains")
    for kc in glob.glob(os.path.join(src, "keychain", "*")):
        shutil.copy2(kc, kdir)
