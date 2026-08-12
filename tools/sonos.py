"""Sonos over UPnP/SOAP — ground truth, straight from the speakers.

The speakers are the only authority on what is actually playing. This module exists
because inference repeatedly lost to measurement: on 2026-08-05 an evening went into
theories about speaker models, share registration, NAS reachability, timing and
encoding, and every one was settled in seconds by asking a speaker directly.

Read-only helpers are safe to run any time. Anything that starts or stops audio makes
noise in a real house — see `capture_state`/`restore_state`, and use them.

Contract for command sequences: server/static/docs/engineering/sonos-playback-contract.md
"""
import contextlib
import datetime
import html
import json
import os
import re
import socket
import urllib.error
import urllib.request

PORT = 1400
AVT = "urn:schemas-upnp-org:service:AVTransport:1"
CD = "urn:schemas-upnp-org:service:ContentDirectory:1"
RC = "urn:schemas-upnp-org:service:RenderingControl:1"
AVT_PATH = "/MediaRenderer/AVTransport/Control"
CD_PATH = "/MediaServer/ContentDirectory/Control"
RC_PATH = "/MediaRenderer/RenderingControl/Control"


def _xml_escape(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;")
             .replace(">", "&gt;").replace('"', "&quot;"))


def field(xml, tag):
    """First value of `tag`, entity-decoded. Empty string when absent."""
    m = re.search(r"<%s>(.*?)</%s>" % (tag, tag), xml, re.S)
    return html.unescape(m.group(1)) if m else ""


def soap(host, action, service=AVT, path=AVT_PATH, body=""):
    """One SOAP call. Returns (http_status, body_text).

    Never raises on a SOAP fault — a fault IS the answer we usually want. Sonos
    returns the reason in <errorCode>, and discarding it is what made failures
    look identical to successes for an entire session.
    """
    envelope = (
        '<?xml version="1.0"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
        '<u:%s xmlns:u="%s"><InstanceID>0</InstanceID>%s</u:%s>'
        "</s:Body></s:Envelope>" % (action, service, body, action)
    )
    req = urllib.request.Request(
        "http://%s:%d%s" % (host, PORT, path),
        data=envelope.encode("utf-8"),
        headers={"Content-Type": 'text/xml; charset="utf-8"',
                 "SOAPACTION": '"%s#%s"' % (service, action)},
    )
    try:
        r = urllib.request.urlopen(req, timeout=8)
        return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        # Reading the fault body can ITSELF fail — some devices reset the
        # connection straight after the 500. Sub 4 units do this for every
        # AVTransport call: they are not renderers and do not implement it.
        try:
            return e.code, e.read().decode("utf-8", "replace")
        except Exception:
            return e.code, ""
    except Exception as e:                                   # network-level
        return -1, str(e)


def fault(body):
    """UPnP errorCode from a fault body, e.g. '701'. Empty when not a fault.

    701 transition-not-available is by far the most common and usually means the
    URI was silently rejected earlier — see the contract, section 0.
    """
    return field(body, "errorCode")


def discover(timeout=3):
    """SSDP M-SEARCH for zone players. Returns [(ip, room, uuid, model)].

    Confirmed to work from the iOS Simulator as well as the host.
    """
    msg = ("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n"
           'MAN: "ssdp:discover"\r\nMX: 2\r\n'
           "ST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n\r\n").encode()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.settimeout(timeout)
    s.sendto(msg, ("239.255.255.250", 1900))
    ips = set()
    try:
        while True:
            data, addr = s.recvfrom(2048)
            if b"Sonos" in data or b"ZonePlayer" in data:
                ips.add(addr[0])
    except socket.timeout:
        pass
    out = []
    for ip in sorted(ips, key=lambda i: [int(p) for p in i.split(".")]):
        try:
            x = urllib.request.urlopen(
                "http://%s:%d/xml/device_description.xml" % (ip, PORT), timeout=4
            ).read().decode("utf-8", "replace")
            out.append((ip, field(x, "roomName"),
                        field(x, "UDN").replace("uuid:", ""), field(x, "modelName")))
        except Exception:
            out.append((ip, "?", "", ""))
    return out


def supports_transport(host):
    """False for devices with no AVTransport — subs and satellites.

    They answer discovery like any other player, so a harness that assumes every
    discovered device is controllable will fail on them.
    """
    return soap(host, "GetTransportInfo")[0] == 200


def transport(host):
    """What a zone is doing, as the speaker reports it.

    `duration == '0:00:00'` on a local file means the speaker never read the file
    header — the signature of a URI it accepted but cannot play.
    """
    ti = soap(host, "GetTransportInfo")[1]
    mi = soap(host, "GetMediaInfo")[1]
    pi = soap(host, "GetPositionInfo")[1]
    meta = html.unescape(field(pi, "TrackMetaData"))
    return {
        "state": field(ti, "CurrentTransportState"),
        "current_uri": field(mi, "CurrentURI"),
        "track_uri": field(pi, "TrackURI"),
        "tracks": field(mi, "NrTracks"),
        "position": field(pi, "RelTime"),
        "duration": field(pi, "TrackDuration"),
        "dc_title": field(meta, "dc:title"),          # filename/slug — NOT a station name
        "stream_content": field(meta, "r:streamContent"),   # live track on a stream
    }


def queue(host, limit=200):
    """Queue contents as [(title, uri)]."""
    body = ("<ObjectID>Q:0</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag>"
            "<Filter>*</Filter><StartingIndex>0</StartingIndex>"
            "<RequestedCount>%d</RequestedCount><SortCriteria></SortCriteria>" % limit)
    didl = html.unescape(field(soap(host, "Browse", CD, CD_PATH, body)[1], "Result"))
    out = []
    for item in re.findall(r"<item .*?</item>", didl, re.S):
        out.append((field(item, "dc:title"), field(item, "res")))
    return out


def shares(host):
    """Music shares the household has actually registered.

    The only reliable way to know: CreateObject returns 200 while registering
    nothing (bSonosShareRegistrationSilentlyNoOps).
    """
    body = ("<ObjectID>S:</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag>"
            "<Filter>*</Filter><StartingIndex>0</StartingIndex>"
            "<RequestedCount>100</RequestedCount><SortCriteria></SortCriteria>")
    didl = html.unescape(field(soap(host, "Browse", CD, CD_PATH, body)[1], "Result"))
    return re.findall(r'<container id="([^"]*)"', didl)


def get_volume(host):
    b = soap(host, "GetVolume", RC, RC_PATH, "<Channel>Master</Channel>")[1]
    try:
        return int(field(b, "CurrentVolume"))
    except ValueError:
        return -1


def set_volume(host, level):
    return soap(host, "SetVolume", RC, RC_PATH,
                "<Channel>Master</Channel><DesiredVolume>%d</DesiredVolume>" % int(level))[0]


def capture_state(host):
    """Snapshot enough to put a zone back as it was. Use before any noisy test."""
    t = transport(host)
    return {"host": host, "state": t["state"], "current_uri": t["current_uri"],
            "queue": queue(host), "volume": get_volume(host)}


def restore_state(saved):
    """Best-effort restore. Stops the zone; re-queues only if we took it over.

    Stopping alone is NOT enough — a probe track left playing on Workout for an
    hour on 2026-08-05 was read as an album transfer having landed there, and
    corrupted a real test result.
    """
    host = saved["host"]
    soap(host, "Stop", body="<Speed>1</Speed>")
    if saved.get("volume", -1) >= 0:
        set_volume(host, saved["volume"])
    if saved["state"] == "PLAYING" and saved["current_uri"]:
        soap(host, "SetAVTransportURI",
             body="<CurrentURI>%s</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>"
                  % _xml_escape(saved["current_uri"]))
        soap(host, "Play", body="<Speed>1</Speed>")


# ---------------------------------------------------------------- guardrails

_ZONES_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "test-zones.json")


class ZoneNotTestable(Exception):
    """Raised rather than making noise in a room that was not offered up."""


def _policy():
    try:
        with open(_ZONES_FILE) as f:
            return json.load(f)
    except Exception:
        return {"allowed": [], "quiet_hours": {"ranges": []}}


def testable_zones():
    return list(_policy().get("allowed", []))


def in_quiet_hours(now=None):
    now = now or datetime.datetime.now()
    for r in _policy().get("quiet_hours", {}).get("ranges", []):
        start, end = int(r[0]), int(r[1])
        if start <= now.hour < end:
            return True
    return False


def household_id(host):
    """The Sonos household this speaker belongs to, or "" if it will not say.

    Zone names are not unique across systems — see test-zones.json. This is what
    makes a permission specific to one house.
    """
    code, body = soap(host, "GetHouseholdID",
                      service="urn:schemas-upnp-org:service:DeviceProperties:1",
                      path="/DeviceProperties/Control")
    return field(body, "CurrentHouseholdID") if code == 200 else ""


def assert_testable(room, host=None):
    """Gate for anything that starts or stops audio. Call it FIRST.

    Read-only inspection needs no permission — it is invisible. Playback is not:
    it happens in a real room, in a real house, where somebody may be listening
    to something else. On 2026-08-05 a probe track was left playing in Workout
    for an hour and was mistaken for a real test result, which corrupted the
    finding it was meant to check.

    Zones are listed in test-zones.json by Tom. Absence means no.
    """
    # A household-scoped permission needs the speaker to prove which household it
    # is in, so it cannot be satisfied by name alone.
    scoped = _policy().get("households", {})
    if host and scoped:
        hh = household_id(host)
        if hh in scoped and room in scoped[hh]:
            if in_quiet_hours():
                raise ZoneNotTestable("Within quiet hours — refusing to make noise.")
            return True
        for other, rooms in scoped.items():
            if room in rooms and other != hh:
                raise ZoneNotTestable(
                    "%r is nominated for household %s, but this speaker reports %s. "
                    "Same zone name, different house — refusing." % (room, other, hh or "nothing"))

    allowed = testable_zones()
    if not allowed:
        raise ZoneNotTestable(
            "No zones nominated. Add them to tools/test-zones.json — this is Tom's "
            "call, not something to infer from which zones look idle.")
    if room not in allowed:
        raise ZoneNotTestable(
            "%r is not nominated for testing. Allowed: %s" % (room, ", ".join(allowed)))
    if in_quiet_hours():
        raise ZoneNotTestable("Within quiet hours — refusing to make noise.")
    return True


@contextlib.contextmanager
def testing(room, host):
    """The only sanctioned way to make a zone do anything audible.

        with sonos.testing("Workout", "192.168.1.230"):
            ...play, transfer, group...

    Checks the zone is nominated, captures prior state INCLUDING VOLUME, sets the
    volume to zero, and restores everything afterwards — even if the body raises.

    Volume zero is Tom's guardrail and it is a good one: silence makes the hour
    irrelevant, so there are no quiet hours to encode. It also removes the failure
    that actually happened on 2026-08-05, where a probe track left playing in a
    room was mistaken for a real result and corrupted the finding it was checking.
    """
    assert_testable(room, host=host)
    saved = capture_state(host)
    try:
        if _policy().get("mute_during_test", True):
            set_volume(host, 0)
        yield saved
    finally:
        restore_state(saved)
