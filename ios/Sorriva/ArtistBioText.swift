import Foundation

// MARK: - ArtistBioText
//
// Turning three sources' markup into one readable paragraph.
//
// Each source dirties its prose differently, so this is per-source rather than one universal
// scrubber — a generic tag-stripper would leave Discogs's reference codes and Last.fm's
// trailing link intact, which is exactly what a generic scrubber always does.
//
// Foundation-only and pure, so the fast suite covers every rule below with no network.

enum ArtistBioText {

    enum Source {
        case discogs, wikipedia, lastfm
    }

    static func clean(_ raw: String?, from source: Source) -> String? {
        guard var text = raw, !text.isEmpty else { return nil }

        switch source {
        case .discogs:
            text = strippingDiscogsMarkup(text)
        case .wikipedia:
            // Already plain prose — the extracts endpoint is asked for explaintext. Nothing
            // to strip; only the shared tidy-up below applies.
            break
        case .lastfm:
            text = strippingHTML(text)
            text = strippingLastFmBoilerplate(text)
        }

        text = normalisingWhitespace(text)
        return text.isEmpty ? nil : text
    }

    // MARK: - Discogs

    /// Discogs profiles carry two kinds of markup.
    ///
    /// REFERENCE CODES: `[a256558]` for an artist, `[l123]` label, `[m123]` master,
    /// `[r123]` release. They are bare identifiers with no display text at all, so they are
    /// removed outright — leaving them produces "his stint with vibraphone great [a256558]".
    ///
    /// BBCODE: `[b]`, `[i]`, `[u]`, and `[url=...]text[/url]`. Here the INNER TEXT is the
    /// prose and must survive; only the tags go.
    ///
    /// Also `[a=Gary Burton]`, the named form of a reference, where the name after `=` is
    /// real text worth keeping.
    static func strippingDiscogsMarkup(_ text: String) -> String {
        var out = text

        // [a=Gary Burton] / [l=ECM] → keep the name. But ONLY when it is a name: Discogs
        // also writes [r=54828] for a release, and keeping THAT produced Grammy citations
        // reading "Best Jazz Fusion Performance for 54828". A purely numeric value is an
        // identifier, not prose.
        out = out.replacingOccurrences(
            of: #"\[[almr]=(\d+)\]"#, with: "",
            options: .regularExpression)
        out = out.replacingOccurrences(
            of: #"\[[almr]=([^\]]+)\]"#, with: "$1",
            options: .regularExpression)

        // [a256558] / [l1234] / [m99] / [r5] → bare ids, nothing to keep.
        out = out.replacingOccurrences(
            of: #"\[[almr]\d+\]"#, with: "",
            options: .regularExpression)

        // [url=https://…]text[/url] → keep text.
        out = out.replacingOccurrences(
            of: #"\[url=[^\]]*\]([^\[]*)\[/url\]"#, with: "$1",
            options: .regularExpression)

        // Remaining simple BBCode tags.
        out = out.replacingOccurrences(
            of: #"\[/?(b|i|u|url)\]"#, with: "",
            options: [.regularExpression, .caseInsensitive])

        return out
    }

    // MARK: - Last.fm

    static func strippingHTML(_ text: String) -> String {
        text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    /// Every Last.fm bio ends with a link back to Last.fm, and licence text with it. It is not
    /// part of the biography and reads as an error when it lands mid-panel.
    static func strippingLastFmBoilerplate(_ text: String) -> String {
        var out = text
        for marker in ["Read more on Last.fm", "User-contributed text is available"] {
            if let range = out.range(of: marker) {
                out = String(out[out.startIndex..<range.lowerBound])
            }
        }
        return out
    }

    // MARK: - Shared

    /// Collapse the runs of blank lines that markup removal leaves behind, without destroying
    /// real paragraph breaks — a biography reads badly as one wall of text.
    static func normalisingWhitespace(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "\r\n", with: "\n")
        out = out.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        // Removing a reference leaves the space that preceded it stranded against the next
        // punctuation mark — "the younger brother of flugelhorn player ." and "vibraphone
        // great , the young Missouri native". Close those up.
        out = out.replacingOccurrences(of: #" +([,.;:!?\)])"#, with: "$1",
                                       options: .regularExpression)
        out = out.replacingOccurrences(of: #"\( +"#, with: "(", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        out = out.replacingOccurrences(of: #" +\n"#, with: "\n", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
