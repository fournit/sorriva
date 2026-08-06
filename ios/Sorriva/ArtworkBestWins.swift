import Foundation

// MARK: - ArtworkBestWins
// Pure decision logic for bArtworkSelectionNotBestWins, extracted from
// runFolderArtPass so it's testable without touching SMB/network I/O.
// Takes plain values in, returns a plain decision out.

enum ArtworkBestWins {

    struct Candidate: Equatable {
        let name: String
        let width: Int
        let height: Int
    }

    /// Picks the best candidate by pixel area, tie-broken by filename
    /// preference (cover > folder > AlbumArt_* > other). Returns nil if
    /// there are no candidates, or if the best one doesn't actually beat
    /// what's already stored for this album — callers should not overwrite
    /// in that case.
    static func selectWinner(
        candidates: [Candidate],
        storedWidth: Int?,
        storedHeight: Int?
    ) -> Candidate? {
        var best: Candidate? = nil
        for candidate in candidates {
            let area = candidate.width * candidate.height
            if let currentBest = best {
                let currentArea = currentBest.width * currentBest.height
                if area > currentArea ||
                   (area == currentArea && filenamePriority(candidate.name) < filenamePriority(currentBest.name)) {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }
        guard let winner = best else { return nil }
        let storedArea = (storedWidth ?? 0) * (storedHeight ?? 0)
        let winnerArea = winner.width * winner.height
        guard winnerArea > storedArea else { return nil }
        return winner
    }

    /// Lower number = higher priority. Only breaks ties on exactly equal area.
    static func filenamePriority(_ name: String) -> Int {
        let lower = name.lowercased()
        if lower.hasPrefix("cover") { return 0 }
        if lower.hasPrefix("folder") { return 1 }
        if lower.hasPrefix("albumart") { return 2 }
        return 3
    }
}
