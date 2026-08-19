import Foundation

// MARK: - SonosSOAP
//
// One place where a SOAP call to a speaker is built and sent. Every command in
// SonosCommands went through its own hand-written copy of this before 2026-08-09
// — sixteen near-identical blocks of envelope, URL, headers, POST and response
// handling.
//
// WHAT THE DUPLICATION WAS COSTING, beyond the line count: the timeouts had
// drifted to 3s, 5s and 10s with no stated reason, and TWO commands had no
// explicit timeout at all, so they inherited URLSession's 60-second default. A
// speaker that goes unreachable mid-command would hang those for a minute. That
// is not a decision anybody made; it is what happens when the same code is
// written sixteen times. Timeouts now live in one table with a reason attached.
//
// THE SEAM. `SonosCommands.soap` is settable, so a test can substitute a fake
// speaker and assert what was sent without a real device. Deliberately a static
// var rather than an injected parameter: threading a transport through sixteen
// call signatures and every caller above them would have been a far larger and
// riskier change than the one this replaces.
//
// WHAT THIS DOES NOT TEST. Asserting a single command's XML is not the same as
// asserting a SEQUENCE, and the sequences are where the hard-won knowledge lives
// (see sonos-playback-contract.md — local files play via the queue, a 200 does
// not mean success). Those need a fake one level up, at SonosCommands itself.
// This seam is necessary for that work, not sufficient.

/// The four Sonos services Sorriva speaks to, with the endpoint and namespace
/// each one requires. Getting these paired wrong is a 500 from the speaker.
enum SonosService {
    case avTransport
    case renderingControl
    case contentDirectory
    case deviceProperties
    /// Which streaming services this household has linked. Read-only, and the only
    /// honest way to know whether Apple Music is usable here — a hardcoded list would
    /// claim a service the speakers cannot play.
    case musicServices

    var path: String {
        switch self {
        case .avTransport:      return "/MediaRenderer/AVTransport/Control"
        case .renderingControl: return "/MediaRenderer/RenderingControl/Control"
        case .contentDirectory: return "/MediaServer/ContentDirectory/Control"
        case .deviceProperties: return "/DeviceProperties/Control"
        case .musicServices:    return "/MusicServices/Control"
        }
    }

    var urn: String {
        switch self {
        case .avTransport:      return "urn:schemas-upnp-org:service:AVTransport:1"
        case .renderingControl: return "urn:schemas-upnp-org:service:RenderingControl:1"
        case .contentDirectory: return "urn:schemas-upnp-org:service:ContentDirectory:1"
        case .deviceProperties: return "urn:schemas-upnp-org:service:DeviceProperties:1"
        case .musicServices:    return "urn:schemas-upnp-org:service:MusicServices:1"
        }
    }
}

/// How long to wait, and why. Named rather than numeric at the call sites so the
/// reason survives — the previous spread of 3/5/10/none had no recoverable
/// rationale and at least two values looked accidental.
enum SonosTimeout {
    /// Reads and simple transport verbs. A speaker that cannot answer this fast
    /// is not going to answer.
    static let quick: TimeInterval = 3
    /// Commands that make the speaker do work — load a URI, join a group.
    static let action: TimeInterval = 5
    /// Bulk queue writes, which scale with the number of tracks submitted.
    static let bulk: TimeInterval = 10
}

/// The response, reduced to what callers actually use: whether it was accepted,
/// and the body for the handful of commands that read a value back.
///
/// `status == 200` is NOT success — Sonos validates lazily and will accept
/// commands it then silently ignores. See sonos-playback-contract.md; several
/// commands follow up with verifyPlaybackStarted for exactly this reason.
struct SonosSOAPResponse {
    let status: Int
    let body: Data

    var ok: Bool { status == 200 }
    var text: String { String(data: body, encoding: .utf8) ?? "" }
}

protocol SonosSOAPTransport: Sendable {
    func send(host: String,
              service: SonosService,
              action: String,
              innerXML: String,
              timeout: TimeInterval) async throws -> SonosSOAPResponse
}

/// The real one. Builds the envelope, posts it, hands back status and body.
struct LiveSonosSOAP: SonosSOAPTransport {

    func send(host: String,
              service: SonosService,
              action: String,
              innerXML: String,
              timeout: TimeInterval) async throws -> SonosSOAPResponse {

        guard let url = URL(string: "http://\(host):1400\(service.path)") else {
            throw SonosSOAPError.badHost(host)
        }

        let envelope = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:\(action) xmlns:u="\(service.urn)">
        \(innerXML)
            </u:\(action)>
          </s:Body>
        </s:Envelope>
        """

        guard let bodyData = envelope.data(using: .utf8) else {
            throw SonosSOAPError.badBody(action)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.urn)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = bodyData
        request.timeoutInterval = timeout

        let (data, response) = try await URLSession.shared.data(for: request)
        return SonosSOAPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                 body: data)
    }
}

enum SonosSOAPError: Error {
    case badHost(String)
    case badBody(String)
}
