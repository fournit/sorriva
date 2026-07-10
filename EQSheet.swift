import SwiftUI

// MARK: - EQSheet
// Bass, treble, loudness controls for a Sonos zone via RenderingControl UPnP.
// Extended Arc controls shown when zone capabilities include "night_sound" etc.
// Presented as a compact sheet from the expanded zone card EQ button.

struct EQSheet: View {
    let zone: SonosZone
    @ObservedObject var discovery: ZoneDiscoveryService
    @Environment(\.dismiss) private var dismiss

    @State private var bass: Int = 0
    @State private var treble: Int = 0
    @State private var loudness: Bool = false
    @State private var nightSound: Bool = false
    @State private var speechEnhancement: Bool = false
    @State private var subwooferLevel: Int = 0
    @State private var heightLevel: Int = 0
    @State private var isLoading = true

    // Capability helpers — read from zone.capabilities
    private var caps: [String] { zone.capabilities }
    private var hasNightSound: Bool { caps.contains("night_sound") }
    private var hasSpeechEnhancement: Bool { caps.contains("speech_enhancement") }
    private var hasSubwoofer: Bool { caps.contains("subwoofer") }
    private var hasHeightChannel: Bool { caps.contains("height_channel") }
    private var isArcFamily: Bool { hasNightSound || hasSpeechEnhancement }

    // Compact sheet height adapts to available controls
    static func sheetHeight(for zone: SonosZone) -> CGFloat {
        let caps = zone.capabilities
        var height: CGFloat = 240 // base: header + divider + bass + treble + loudness + padding
        if caps.contains("subwoofer") { height += 80 }
        if caps.contains("height_channel") { height += 80 }
        if caps.contains("night_sound") { height += 64 }
        if caps.contains("speech_enhancement") { height += 64 }
        return min(height, 560)
    }

    var body: some View {
        VStack(spacing: 0) {

            // Header
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.sTextMuted)
                        .padding(12)
                }
                .buttonStyle(.plain)

                Spacer()

                VStack(spacing: 2) {
                    Text("EQ")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.sTextPrimary)
                    Text(zone.name)
                        .font(.system(size: 12))
                        .foregroundColor(.sTextMuted)
                }

                Spacer()

                Button(action: resetEQ) {
                    Text("Reset")
                        .font(.system(size: 13))
                        .foregroundColor(.sHighlight)
                        .padding(12)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 20)

            Divider().background(Color.sSeparator)

                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView().tint(.sHighlight)
                        Spacer()
                    }
                    .padding(.top, 24)
                } else {
                    VStack(spacing: 20) {

                        // Bass
                        EQSliderRow(
                            label: "Bass",
                            value: $bass,
                            range: -10...10,
                            onChange: { setBass($0) }
                        )

                        // Treble
                        EQSliderRow(
                            label: "Treble",
                            value: $treble,
                            range: -10...10,
                            onChange: { setTreble($0) }
                        )

                        // Subwoofer level — Arc Ultra, Sub-paired zones
                        if hasSubwoofer {
                            EQSliderRow(
                                label: "Subwoofer",
                                value: $subwooferLevel,
                                range: -15...15,
                                onChange: { setSubwoofer($0) }
                            )
                        }

                        // Height channel — Arc Ultra upfiring drivers
                        if hasHeightChannel {
                            EQSliderRow(
                                label: "Height",
                                value: $heightLevel,
                                range: -10...10,
                                onChange: { setHeight($0) }
                            )
                        }

                        // Loudness toggle
                        EQToggleRow(label: "Loudness",
                                    subtitle: "Boosts bass & treble at low volumes",
                                    value: $loudness,
                                    onChange: { setLoudness($0) })

                        // Night Sound — Arc family
                        if hasNightSound {
                            EQToggleRow(label: "Night Sound",
                                        subtitle: "Reduces loud sounds, boosts quiet ones",
                                        value: $nightSound,
                                        onChange: { setNightSound($0) })
                        }

                        // Speech Enhancement — Arc family
                        if hasSpeechEnhancement {
                            EQToggleRow(label: "Speech Enhancement",
                                        subtitle: "Boosts dialogue clarity",
                                        value: $speechEnhancement,
                                        onChange: { setSpeechEnhancement($0) })
                        }
                    }
                    .padding(.top, 16)
                }

                Spacer(minLength: 0)
        }
        .background(Color.sCard)
        .onAppear { loadEQ() }
    }

    private func loadEQ() {
        Task {
            async let b = EQService.getBass(host: zone.host)
            async let t = EQService.getTreble(host: zone.host)
            async let l = EQService.getLoudness(host: zone.host)
            bass = await b
            treble = await t
            loudness = await l

            if hasNightSound {
                nightSound = await EQService.getNightMode(host: zone.host)
            }
            if hasSpeechEnhancement {
                speechEnhancement = await EQService.getDialogLevel(host: zone.host)
            }
            if hasSubwoofer {
                subwooferLevel = await EQService.getSubwooferLevel(host: zone.host)
            }
            if hasHeightChannel {
                heightLevel = await EQService.getHeightLevel(host: zone.host)
            }
            isLoading = false
        }
    }

    private func setBass(_ value: Int) { Task { await EQService.setBass(host: zone.host, value: value) } }
    private func setTreble(_ value: Int) { Task { await EQService.setTreble(host: zone.host, value: value) } }
    private func setLoudness(_ value: Bool) { Task { await EQService.setLoudness(host: zone.host, value: value) } }
    private func setNightSound(_ value: Bool) { Task { await EQService.setNightMode(host: zone.host, value: value) } }
    private func setSpeechEnhancement(_ value: Bool) { Task { await EQService.setDialogLevel(host: zone.host, value: value) } }
    private func setSubwoofer(_ value: Int) { Task { await EQService.setSubwooferLevel(host: zone.host, value: value) } }
    private func setHeight(_ value: Int) { Task { await EQService.setHeightLevel(host: zone.host, value: value) } }

    private func resetEQ() {
        bass = 0; treble = 0; loudness = false
        nightSound = false; speechEnhancement = false
        subwooferLevel = 0; heightLevel = 0
        setBass(0); setTreble(0); setLoudness(false)
        if hasNightSound { setNightSound(false) }
        if hasSpeechEnhancement { setSpeechEnhancement(false) }
        if hasSubwoofer { setSubwoofer(0) }
        if hasHeightChannel { setHeight(0) }
    }
}

// MARK: - EQSliderRow

struct EQSliderRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let onChange: (Int) -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.sTextPrimary)
                Spacer()
                Text(value > 0 ? "+\(value)" : "\(value)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(value == 0 ? .sTextMuted : .sHighlight)
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            }
            .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Text("\(range.lowerBound)")
                    .font(.system(size: 10))
                    .foregroundColor(.sTextMuted)

                Slider(
                    value: Binding(
                        get: { Double(value) },
                        set: { newVal in
                            let stepped = Int(newVal)
                            if stepped != value {
                                value = stepped
                                onChange(stepped)
                            }
                        }
                    ),
                    in: Double(range.lowerBound)...Double(range.upperBound),
                    step: 1
                )
                .tint(Color.sHighlight)

                Text("+\(range.upperBound)")
                    .font(.system(size: 10))
                    .foregroundColor(.sTextMuted)
            }
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - EQToggleRow

struct EQToggleRow: View {
    let label: String
    let subtitle: String
    @Binding var value: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.sTextPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.sTextMuted)
            }
            Spacer()
            Button(action: {
                value.toggle()
                onChange(value)
            }) {
                ZStack {
                    Capsule()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 48, height: 28)
                    Circle()
                        .fill(value ? Color.sHighlight : Color.white.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .offset(x: value ? 10 : -10)
                        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: value)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - EQService
// Sonos RenderingControl EQ endpoints — same service as volume.

enum EQService {

    static func getBass(host: String) async -> Int {
        return await getRenderingControlInt(host: host, channel: "Master", action: "GetBass", tag: "CurrentBass")
    }

    static func getTreble(host: String) async -> Int {
        return await getRenderingControlInt(host: host, channel: "Master", action: "GetTreble", tag: "CurrentTreble")
    }

    static func getLoudness(host: String) async -> Bool {
        let val = await getRenderingControlInt(host: host, channel: "Master", action: "GetLoudness", tag: "CurrentLoudness")
        return val == 1
    }

    static func setBass(host: String, value: Int) async {
        await setRenderingControl(host: host, action: "SetBass", channel: "Master", paramName: "DesiredBass", value: "\(value)")
    }

    static func setTreble(host: String, value: Int) async {
        await setRenderingControl(host: host, action: "SetTreble", channel: "Master", paramName: "DesiredTreble", value: "\(value)")
    }

    static func setLoudness(host: String, value: Bool) async {
        await setRenderingControl(host: host, action: "SetLoudness", channel: "Master", paramName: "DesiredLoudness", value: value ? "1" : "0")
    }

    // MARK: - Arc family controls

    static func getNightMode(host: String) async -> Bool {
        // NightMode uses AVTransport, not RenderingControl
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetEQ xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
              <InstanceID>0</InstanceID>
              <EQType>NightMode</EQType>
            </u:GetEQ>
          </s:Body>
        </s:Envelope>
        """
        let val = await getEQValue(host: host, soapBody: soapBody, tag: "CurrentValue")
        return val == 1
    }

    static func setNightMode(host: String, value: Bool) async {
        await setEQValue(host: host, eqType: "NightMode", value: value ? "1" : "0")
    }

    static func getDialogLevel(host: String) async -> Bool {
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetEQ xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
              <InstanceID>0</InstanceID>
              <EQType>DialogLevel</EQType>
            </u:GetEQ>
          </s:Body>
        </s:Envelope>
        """
        let val = await getEQValue(host: host, soapBody: soapBody, tag: "CurrentValue")
        return val == 1
    }

    static func setDialogLevel(host: String, value: Bool) async {
        await setEQValue(host: host, eqType: "DialogLevel", value: value ? "1" : "0")
    }

    static func getSubwooferLevel(host: String) async -> Int {
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetEQ xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
              <InstanceID>0</InstanceID>
              <EQType>SubGain</EQType>
            </u:GetEQ>
          </s:Body>
        </s:Envelope>
        """
        return await getEQValue(host: host, soapBody: soapBody, tag: "CurrentValue")
    }

    static func setSubwooferLevel(host: String, value: Int) async {
        await setEQValue(host: host, eqType: "SubGain", value: "\(value)")
    }

    static func getHeightLevel(host: String) async -> Int {
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetEQ xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
              <InstanceID>0</InstanceID>
              <EQType>HeightChannelLevel</EQType>
            </u:GetEQ>
          </s:Body>
        </s:Envelope>
        """
        return await getEQValue(host: host, soapBody: soapBody, tag: "CurrentValue")
    }

    static func setHeightLevel(host: String, value: Int) async {
        await setEQValue(host: host, eqType: "HeightChannelLevel", value: "\(value)")
    }

    private static func getEQValue(host: String, soapBody: String, tag: String) async -> Int {
        guard let url = URL(string: "http://\(host):1400/MediaRenderer/RenderingControl/Control"),
              let bodyData = soapBody.data(using: .utf8) else { return 0 }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:RenderingControl:1#GetEQ\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = bodyData
        request.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let raw = String(data: data, encoding: .utf8),
              let start = raw.range(of: "<\(tag)>"),
              let end = raw.range(of: "</\(tag)>") else { return 0 }
        return Int(String(raw[start.upperBound..<end.lowerBound])) ?? 0
    }

    private static func setEQValue(host: String, eqType: String, value: String) async {
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:SetEQ xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
              <InstanceID>0</InstanceID>
              <EQType>\(eqType)</EQType>
              <DesiredValue>\(value)</DesiredValue>
            </u:SetEQ>
          </s:Body>
        </s:Envelope>
        """
        guard let url = URL(string: "http://\(host):1400/MediaRenderer/RenderingControl/Control"),
              let bodyData = soapBody.data(using: .utf8) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:RenderingControl:1#SetEQ\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = bodyData
        request.timeoutInterval = 3
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func getRenderingControlInt(host: String, channel: String, action: String, tag: String) async -> Int {
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:\(action) xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
              <InstanceID>0</InstanceID>
              <Channel>\(channel)</Channel>
            </u:\(action)>
          </s:Body>
        </s:Envelope>
        """
        guard let url = URL(string: "http://\(host):1400/MediaRenderer/RenderingControl/Control"),
              let bodyData = soapBody.data(using: .utf8) else { return 0 }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:RenderingControl:1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = bodyData
        request.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let raw = String(data: data, encoding: .utf8),
              let start = raw.range(of: "<\(tag)>"),
              let end = raw.range(of: "</\(tag)>") else { return 0 }
        return Int(String(raw[start.upperBound..<end.lowerBound])) ?? 0
    }

    private static func setRenderingControl(host: String, action: String, channel: String, paramName: String, value: String) async {
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:\(action) xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
              <InstanceID>0</InstanceID>
              <Channel>\(channel)</Channel>
              <\(paramName)>\(value)</\(paramName)>
            </u:\(action)>
          </s:Body>
        </s:Envelope>
        """
        guard let url = URL(string: "http://\(host):1400/MediaRenderer/RenderingControl/Control"),
              let bodyData = soapBody.data(using: .utf8) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:RenderingControl:1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = bodyData
        request.timeoutInterval = 3
        _ = try? await URLSession.shared.data(for: request)
    }
}
