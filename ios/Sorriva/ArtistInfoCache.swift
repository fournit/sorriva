import Foundation

// MARK: - ArtistInfoCache
//
// Connects ArtistInfoService to the database, and is the ONLY thing that does.
//
// WHY THIS FILE EXISTS AT ALL. ArtistInfoService is compiled directly into `ios/FastTests`,
// which builds for macOS and has no GRDB. Calling SorrivaDatabase from inside the service
// broke that target the moment it was tried. So the service declares inert cache hooks and
// this installs the real ones at launch — the boundary that keeps the whole lookup chain in
// the one-second test loop.
//
// WHAT IS STORED, and the rule is Tom's: only Discogs and Wikipedia results. A Last.fm
// fallback is shown and never written, so a single unlucky fetch during a Discogs hiccup
// cannot decide an artist's biography permanently — the next visit tries the good sources
// again. The rule itself lives in ArtistInfoService.cacheable, where it is unit-tested;
// this file only moves rows.

enum ArtistInfoCache {

    /// Called once at launch, before any artist page can ask for a biography.
    static func install() {
        ArtistInfoService.cacheRead = { mbid in
            guard let row = SorrivaDatabase.shared.artistMetadata(mbid: mbid) else { return nil }
            return ArtistInfo(
                mbid: row.mbid,
                name: row.name,
                disambiguation: row.disambiguation,
                bio: row.bio,
                bioSource: row.bioSource.flatMap(ArtistInfo.BioSource.init(rawValue:)))
        }

        ArtistInfoService.cacheWrite = { info in
            guard let mbid = info.mbid else { return }
            SorrivaDatabase.shared.saveArtistMetadata(
                ArtistMetadata(mbid: mbid,
                               name: info.name,
                               disambiguation: info.disambiguation,
                               bio: info.bio,
                               bioSource: info.bioSource?.rawValue,
                               fetchedAt: Int(Date().timeIntervalSince1970)))
        }
    }
}
