import Foundation
import GRDB

// MARK: - FolderFingerprint
// What "this folder is unchanged" means, in one place.
//
// fUnifiedScanWalkThenFilter: manual scan, automatic foreground scan and resume
// all use the same comparison. Keeping the rule here rather than inline at each
// call site is deliberate — three copies of a subtly different comparison is how
// change detection quietly stops agreeing with itself.

struct FolderFingerprint: Equatable {
    let fileCount: Int
    let totalBytes: Int
    /// Unix seconds of the newest file in the folder. Nil for rows written
    /// before v17 tracked it.
    let maxModifiedAt: Int?

    /// True only if this folder can be safely skipped.
    ///
    /// A nil stored mtime means the row predates v17, so we do NOT know whether
    /// a tag-only edit happened since. Treated as changed, which forces one
    /// rescan of that folder and thereafter records a real value. The safe
    /// direction: the alternative silently trusts stats recorded before mtime
    /// existed, and tag edits made in that window would never be seen.
    func matches(_ current: FolderFingerprint) -> Bool {
        guard let stored = maxModifiedAt else { return false }
        return fileCount == current.fileCount
            && totalBytes == current.totalBytes
            && stored == current.maxModifiedAt
    }
}

// MARK: - SorrivaDatabase
// Singleton database instance. Initialized on app launch.
// SQLite stored in app's Application Support directory.
// Uses GRDB migrations for schema versioning — safe across app updates.

final class SorrivaDatabase {

    static let shared = SorrivaDatabase()

    let dbQueue: DatabaseQueue

    enum MigrationEvent {
        case backupFailed(error: String)
        case migrationFailed(error: String, restored: Bool)
    }

    private(set) static var pendingMigrationEvent: MigrationEvent? = nil

    private init() {
        let fm = FileManager.default

        // Test isolation — never let a test process touch the real app database.
        // XCTestConfigurationFilePath is set by Xcode/xcodebuild for every test
        // run; it is not present in a normal app launch. Each test run gets a
        // fresh, unique temp-directory file, so tests never share state with
        // the real device library or with each other across separate runs.
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

        let appSupport: URL
        if isRunningTests {
            appSupport = fm.temporaryDirectory
                .appendingPathComponent("sorriva-tests-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        } else {
            appSupport = try! fm
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        }

        let dbURL  = appSupport.appendingPathComponent("sorriva.sqlite")
        let walURL = appSupport.appendingPathComponent("sorriva.sqlite-wal")
        let shmURL = appSupport.appendingPathComponent("sorriva.sqlite-shm")

        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let backupURL = appSupport.appendingPathComponent("sorriva-backup-\(ts).sqlite")
        let backupWAL = appSupport.appendingPathComponent("sorriva-backup-\(ts).sqlite-wal")
        let backupSHM = appSupport.appendingPathComponent("sorriva-backup-\(ts).sqlite-shm")

        var backupMade = false
        if fm.fileExists(atPath: dbURL.path) {
            do {
                try fm.copyItem(at: dbURL, to: backupURL)
                if fm.fileExists(atPath: walURL.path) { try? fm.copyItem(at: walURL, to: backupWAL) }
                if fm.fileExists(atPath: shmURL.path) { try? fm.copyItem(at: shmURL, to: backupSHM) }
                backupMade = true
                print("SORRIVA DB: Backup created at \(backupURL.lastPathComponent)")
            } catch {
                print("SORRIVA DB: Backup FAILED (\(error)) — migration aborted")
                Self.pendingMigrationEvent = .backupFailed(error: error.localizedDescription)
                dbQueue = try! DatabaseQueue(path: dbURL.path)
                return
            }
        }

        let queue = try! DatabaseQueue(path: dbURL.path)
        do {
            try Self.runMigrations(on: queue)
            if backupMade {
                try? fm.removeItem(at: backupURL)
                try? fm.removeItem(at: backupWAL)
                try? fm.removeItem(at: backupSHM)
            }
            dbQueue = queue
            print("SORRIVA DB: Initialized at \(dbURL.path)")
        } catch {
            print("SORRIVA DB: Migration FAILED (\(error)) — restoring backup")
            var restored = false
            if backupMade {
                do {
                    _ = queue
                    try fm.replaceItem(at: dbURL, withItemAt: backupURL,
                                       backupItemName: nil, options: [], resultingItemURL: nil)
                    if fm.fileExists(atPath: backupWAL.path) {
                        try? fm.replaceItem(at: walURL, withItemAt: backupWAL,
                                            backupItemName: nil, options: [], resultingItemURL: nil)
                    }
                    if fm.fileExists(atPath: backupSHM.path) {
                        try? fm.replaceItem(at: shmURL, withItemAt: backupSHM,
                                            backupItemName: nil, options: [], resultingItemURL: nil)
                    }
                    restored = true
                } catch let restoreError {
                    print("SORRIVA DB: Restore FAILED (\(restoreError))")
                }
            }
            Self.pendingMigrationEvent = .migrationFailed(
                error: error.localizedDescription,
                restored: restored
            )
            dbQueue = try! DatabaseQueue(path: dbURL.path)
        }
    }

    // MARK: - Migrations

    // MARK: - Testing support
    static func runMigrationsForTesting(on dbQueue: DatabaseQueue) throws {
        try runMigrations(on: dbQueue)
    }

    private static func runMigrations(on dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        // v1 — initial schema
        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "households", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("sonosName", .text)
                t.column("userName", .text)
                t.column("lastSeen", .integer).notNull()
                t.column("createdAt", .integer).notNull()
                t.column("updatedAt", .integer).notNull()
                t.column("deletedAt", .integer)
                t.column("syncedAt", .integer)
            }

            try db.create(table: "devices", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("householdId", .text).notNull().references("households", onDelete: .cascade)
                t.column("source", .text).notNull()
                t.column("sourceId", .text).notNull()
                t.column("modelName", .text)
                t.column("sourceName", .text)
                t.column("userName", .text)
                t.column("capabilitiesJSON", .text).notNull().defaults(to: "[]")
                t.column("firstSeen", .integer).notNull()
                t.column("updatedAt", .integer).notNull()
                t.column("deletedAt", .integer)
                t.column("syncedAt", .integer)
            }

            try db.create(index: "devices_by_source_id", on: "devices",
                         columns: ["source", "sourceId"], unique: true, ifNotExists: true)

            try db.create(table: "stations", ifNotExists: true) { t in
                t.column("id", .integer).primaryKey()
                t.column("source", .text).notNull()
                t.column("name", .text).notNull()
                t.column("logoURL", .text)
                t.column("streamURL", .text)
                t.column("lastFetched", .integer).notNull()
                t.column("updatedAt", .integer).notNull()
            }

            try db.create(table: "zone_state", ifNotExists: true) { t in
                t.column("deviceId", .text).primaryKey().references("devices", onDelete: .cascade)
                t.column("stationId", .integer).references("stations")
                t.column("stationName", .text)
                t.column("stationLogoURL", .text)
                t.column("lastUsed", .integer).notNull()
                t.column("updatedAt", .integer).notNull()
            }
        }

        // v2 — add isFavorite to stations
        migrator.registerMigration("v2_station_favorites") { db in
            try db.alter(table: "stations") { t in
                t.add(column: "isFavorite", .boolean).notNull().defaults(to: false)
            }
        }

        // v3 — genre taxonomy + station-genre relationship + source xref
        migrator.registerMigration("v3_genres") { db in

            // Canonical genre table — AllMusic hierarchy
            try db.create(table: "genres", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()          // slug e.g. "jazz", "jazz-fusion"
                t.column("name", .text).notNull()           // display name e.g. "Jazz", "Fusion"
                t.column("parentId", .text).references("genres")
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("imageURL", .text)                 // null until fGenreImages resolved
            }

            // Many-to-many: stations ↔ genres
            try db.create(table: "station_genres", ifNotExists: true) { t in
                t.column("stationId", .integer).notNull().references("stations", onDelete: .cascade)
                t.column("genreId", .text).notNull().references("genres", onDelete: .cascade)
                t.primaryKey(["stationId", "genreId"])
            }

            // Genre → service ID/name mapping
            // Enables genre-aware search across all future radio/streaming sources
            try db.create(table: "genre_source_xref", ifNotExists: true) { t in
                t.column("genreId", .text).notNull().references("genres", onDelete: .cascade)
                t.column("source", .text).notNull()         // "iheart" | "somafm" | "spotify" | "applemusic" | "lastfm"
                t.column("sourceGenreId", .text)            // service's internal ID (null if name-only)
                t.column("sourceGenreName", .text).notNull() // service's keyword / display name
                t.primaryKey(["genreId", "source"])
            }

            // MARK: Seed — AllMusic parent genres
            let parents: [(id: String, name: String, sort: Int)] = [
                ("avant-garde",    "Avant-Garde",     1),
                ("blues",          "Blues",           2),
                ("childrens",      "Children's",      3),
                ("classical",      "Classical",       4),
                ("comedy-spoken",  "Comedy/Spoken",   5),
                ("country",        "Country",         6),
                ("easy-listening", "Easy Listening",  7),
                ("electronic",     "Electronic",      8),
                ("folk",           "Folk",            9),
                ("holiday",        "Holiday",        10),
                ("international",  "International",  11),
                ("jazz",           "Jazz",           12),
                ("latin",          "Latin",          13),
                ("new-age",        "New Age",        14),
                ("pop-rock",       "Pop/Rock",       15),
                ("rb",             "R&B",            16),
                ("rap",            "Rap",            17),
                ("reggae",         "Reggae",         18),
                ("religious",      "Religious",      19),
                ("stage-screen",   "Stage & Screen", 20),
                ("vocal",          "Vocal",          21),
            ]

            for p in parents {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO genres (id, name, parentId, sortOrder) VALUES (?, ?, NULL, ?)",
                    arguments: [p.id, p.name, p.sort]
                )
            }

            // MARK: Seed — AllMusic subgenres
            // Format: (id, name, parentId, sortOrder)
            let subgenres: [(String, String, String, Int)] = [
                // Avant-Garde
                ("avant-garde-experimental", "Experimental",        "avant-garde",    1),
                ("avant-garde-noise",        "Noise",               "avant-garde",    2),
                ("avant-garde-free-improv",  "Free Improvisation",  "avant-garde",    3),

                // Blues
                ("blues-chicago",            "Chicago Blues",       "blues",          1),
                ("blues-delta",              "Delta Blues",         "blues",          2),
                ("blues-electric",           "Electric Blues",      "blues",          3),
                ("blues-texas",              "Texas Blues",         "blues",          4),
                ("blues-jump",               "Jump Blues",          "blues",          5),
                ("blues-soul",               "Soul Blues",          "blues",          6),
                ("blues-acoustic",           "Acoustic Blues",      "blues",          7),

                // Classical
                ("classical-baroque",        "Baroque",             "classical",      1),
                ("classical-chamber",        "Chamber Music",       "classical",      2),
                ("classical-choral",         "Choral",              "classical",      3),
                ("classical-contemporary",   "Contemporary",        "classical",      4),
                ("classical-early",          "Early Music",         "classical",      5),
                ("classical-opera",          "Opera",               "classical",      6),
                ("classical-orchestral",     "Orchestral",          "classical",      7),
                ("classical-piano",          "Piano",               "classical",      8),
                ("classical-romantic",       "Romantic",            "classical",      9),

                // Country
                ("country-alternative",      "Alternative Country", "country",        1),
                ("country-bluegrass",        "Bluegrass",           "country",        2),
                ("country-classic",          "Classic Country",     "country",        3),
                ("country-contemporary",     "Contemporary Country","country",        4),
                ("country-honky-tonk",       "Honky Tonk",          "country",        5),
                ("country-outlaw",           "Outlaw Country",      "country",        6),
                ("country-western-swing",    "Western Swing",       "country",        7),

                // Easy Listening
                ("easy-adult-contemporary",  "Adult Contemporary",  "easy-listening", 1),
                ("easy-background",          "Background Music",    "easy-listening", 2),
                ("easy-lounge",              "Lounge",              "easy-listening", 3),
                ("easy-soft-rock",           "Soft Rock",           "easy-listening", 4),

                // Electronic
                ("electronic-ambient",       "Ambient",             "electronic",     1),
                ("electronic-dance",         "Dance",               "electronic",     2),
                ("electronic-downtempo",     "Downtempo",           "electronic",     3),
                ("electronic-edm",           "EDM",                 "electronic",     4),
                ("electronic-house",         "House",               "electronic",     5),
                ("electronic-idm",           "IDM",                 "electronic",     6),
                ("electronic-techno",        "Techno",              "electronic",     7),
                ("electronic-trance",        "Trance",              "electronic",     8),
                ("electronic-trip-hop",      "Trip Hop",            "electronic",     9),

                // Folk
                ("folk-acoustic",            "Acoustic Folk",       "folk",           1),
                ("folk-americana",           "Americana",           "folk",           2),
                ("folk-contemporary",        "Contemporary Folk",   "folk",           3),
                ("folk-singer-songwriter",   "Singer-Songwriter",   "folk",           4),
                ("folk-traditional",         "Traditional Folk",    "folk",           5),

                // International
                ("international-african",    "African",             "international",  1),
                ("international-asian",      "Asian",               "international",  2),
                ("international-bossa-nova", "Bossa Nova",          "international",  3),
                ("international-celtic",     "Celtic",              "international",  4),
                ("international-flamenco",   "Flamenco",            "international",  5),
                ("international-world",      "World Music",         "international",  6),

                // Jazz
                ("jazz-bebop",               "Bebop",               "jazz",           1),
                ("jazz-contemporary",        "Contemporary Jazz",   "jazz",           2),
                ("jazz-cool",                "Cool Jazz",           "jazz",           3),
                ("jazz-crossover",           "Crossover Jazz",      "jazz",           4),
                ("jazz-fusion",              "Fusion",              "jazz",           5),
                ("jazz-hard-bop",            "Hard Bop",            "jazz",           6),
                ("jazz-instrument",          "Jazz Instrument",     "jazz",           7),
                ("jazz-latin",               "Latin Jazz",          "jazz",           8),
                ("jazz-modern-creative",     "Modern Creative",     "jazz",           9),
                ("jazz-post-bop",            "Post-Bop",            "jazz",          10),
                ("jazz-smooth",              "Smooth Jazz",         "jazz",          11),
                ("jazz-standards",           "Standards",           "jazz",          12),
                ("jazz-swing",               "Swing",               "jazz",          13),
                ("jazz-vocal",               "Vocal Jazz",          "jazz",          14),

                // Latin
                ("latin-cumbia",             "Cumbia",              "latin",          1),
                ("latin-merengue",           "Merengue",            "latin",          2),
                ("latin-pop",                "Latin Pop",           "latin",          3),
                ("latin-reggaeton",          "Reggaeton",           "latin",          4),
                ("latin-salsa",              "Salsa",               "latin",          5),
                ("latin-tejano",             "Tejano",              "latin",          6),

                // New Age
                ("new-age-ambient",          "Ambient",             "new-age",        1),
                ("new-age-healing",          "Healing",             "new-age",        2),
                ("new-age-meditation",       "Meditation",          "new-age",        3),
                ("new-age-nature",           "Nature Sounds",       "new-age",        4),

                // Pop/Rock
                ("pop-rock-alternative",     "Alternative",         "pop-rock",       1),
                ("pop-rock-classic-rock",    "Classic Rock",        "pop-rock",       2),
                ("pop-rock-dance-pop",       "Dance Pop",           "pop-rock",       3),
                ("pop-rock-glam",            "Glam Rock",           "pop-rock",       4),
                ("pop-rock-hard-rock",       "Hard Rock",           "pop-rock",       5),
                ("pop-rock-indie",           "Indie Rock",          "pop-rock",       6),
                ("pop-rock-metal",           "Metal",               "pop-rock",       7),
                ("pop-rock-new-wave",        "New Wave",            "pop-rock",       8),
                ("pop-rock-pop",             "Pop",                 "pop-rock",       9),
                ("pop-rock-punk",            "Punk",                "pop-rock",      10),
                ("pop-rock-singer-sw",       "Singer-Songwriter",   "pop-rock",      11),
                ("pop-rock-soft-rock",       "Soft Rock",           "pop-rock",      12),

                // R&B
                ("rb-contemporary",          "Contemporary R&B",    "rb",             1),
                ("rb-funk",                  "Funk",                "rb",             2),
                ("rb-gospel",                "Gospel",              "rb",             3),
                ("rb-motown",                "Motown",              "rb",             4),
                ("rb-neo-soul",              "Neo-Soul",            "rb",             5),
                ("rb-soul",                  "Soul",                "rb",             6),

                // Rap
                ("rap-conscious",            "Conscious Rap",       "rap",            1),
                ("rap-east-coast",           "East Coast",          "rap",            2),
                ("rap-gangsta",              "Gangsta Rap",         "rap",            3),
                ("rap-hip-hop",              "Hip-Hop",             "rap",            4),
                ("rap-old-school",           "Old School",          "rap",            5),
                ("rap-trap",                 "Trap",                "rap",            6),
                ("rap-west-coast",           "West Coast",          "rap",            7),

                // Reggae
                ("reggae-dancehall",         "Dancehall",           "reggae",         1),
                ("reggae-dub",               "Dub",                 "reggae",         2),
                ("reggae-roots",             "Roots Reggae",        "reggae",         3),
                ("reggae-ska",               "Ska",                 "reggae",         4),

                // Stage & Screen
                ("stage-screen-broadway",    "Broadway",            "stage-screen",   1),
                ("stage-screen-film-score",  "Film Score",          "stage-screen",   2),
                ("stage-screen-tv",          "Television",          "stage-screen",   3),
                ("stage-screen-video-game",  "Video Game Music",    "stage-screen",   4),

                // Vocal
                ("vocal-big-band",           "Big Band",            "vocal",          1),
                ("vocal-cabaret",            "Cabaret",             "vocal",          2),
                ("vocal-crooners",           "Crooners",            "vocal",          3),
                ("vocal-standards",          "Standards",           "vocal",          4),
                ("vocal-torch",              "Torch Songs",         "vocal",          5),
            ]

            for s in subgenres {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO genres (id, name, parentId, sortOrder) VALUES (?, ?, ?, ?)",
                    arguments: [s.0, s.1, s.2, s.3]
                )
            }

            // MARK: Seed — iHeart genre xref
            // sourceGenreId = iHeart's numeric genre ID (confirmed via API July 2026)
            // sourceGenreName = iHeart's display name for that genre
            // Maps our canonical AllMusic genre slugs → iHeart genre IDs
            //
            // iHeart genre ID reference:
            // 1=Alternative, 2=Christian&Gospel, 3=Classic Rock, 4=Classical,
            // 5=Country, 6=Hip Hop and R&B, 7=Jazz, 8=Mix&Variety, 10=Oldies,
            // 12=Rock, 13=Mix, 14=Spanish, 16=Top40&Pop, 18=80s&90s,
            // 77=Dance, 93=Public Radio, 97=Holiday, 104=R&B,
            // 1201=iHeart Originals, 1208=Decades, 1209=Commercial Free

            let iheartXref: [(genreId: String, iheartId: String, iheartName: String)] = [
                // Parent genre mappings
                ("pop-rock",       "16",   "Top 40 & Pop"),
                ("pop-rock",       "12",   "Rock"),           // Rock maps to pop-rock parent
                ("blues",          "10",   "Oldies"),         // closest iHeart match
                ("classical",      "4",    "Classical"),
                ("country",        "5",    "Country"),
                ("electronic",     "77",   "Dance"),
                ("holiday",        "97",   "Holiday"),
                ("international",  "14",   "Spanish"),        // closest iHeart match for international
                ("jazz",           "7",    "Jazz"),
                ("latin",          "14",   "Spanish"),
                ("rb",             "104",  "R&B"),
                ("rap",            "6",    "Hip Hop and R&B"),
                ("religious",      "2",    "Christian & Gospel"),
                ("vocal",          "8",    "Mix & Variety"),
                // Subgenre mappings
                ("pop-rock-alternative",  "1",    "Alternative"),
                ("pop-rock-classic-rock", "3",    "Classic Rock"),
                ("pop-rock-hard-rock",    "12",   "Rock"),
                ("rb-gospel",             "2",    "Christian & Gospel"),
                ("jazz-smooth",           "7",    "Jazz"),
                // Decade/era genres
                ("pop-rock",       "18",   "80s & 90s Hits"),
                ("pop-rock",       "1208", "Decades"),
            ]

            // iHeart IDs can map to multiple internal genres — use INSERT OR IGNORE
            // Primary key is (genreId, source) so only first insert per genre wins
            for x in iheartXref {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO genre_source_xref
                    (genreId, source, sourceGenreId, sourceGenreName)
                    VALUES (?, 'iheart', ?, ?)
                    """,
                    arguments: [x.genreId, x.iheartId, x.iheartName]
                )
            }

            print("SORRIVA DB: v3 genre seed complete")
        }

        // v4 — add cume to stations for popularity sort
        migrator.registerMigration("v4_station_cume") { db in
            try db.alter(table: "stations") { t in
                t.add(column: "cume", .integer).notNull().defaults(to: 0)
            }
        }

        // v5 — add Decades and Public Radio parent genres + subgenres + iHeart xref
        migrator.registerMigration("v5_decades_publicradio") { db in

            // Decades parent
            try db.execute(sql: "INSERT OR IGNORE INTO genres (id, name, parentId, sortOrder) VALUES ('decades', 'Decades', NULL, 22)")
            let decadesSubgenres: [(String, String, Int)] = [
                ("decades-50s", "50s", 1),
                ("decades-60s", "60s", 2),
                ("decades-70s", "70s", 3),
                ("decades-80s", "80s", 4),
                ("decades-90s", "90s", 5),
                ("decades-2000s", "2000s", 6),
            ]
            for s in decadesSubgenres {
                try db.execute(sql: "INSERT OR IGNORE INTO genres (id, name, parentId, sortOrder) VALUES (?, ?, 'decades', ?)",
                               arguments: [s.0, s.1, s.2])
            }
            // iHeart xref for decades
            try db.execute(sql: "INSERT OR IGNORE INTO genre_source_xref (genreId, source, sourceGenreId, sourceGenreName) VALUES ('decades', 'iheart', '1208', 'Decades')")
            try db.execute(sql: "INSERT OR IGNORE INTO genre_source_xref (genreId, source, sourceGenreId, sourceGenreName) VALUES ('decades-80s', 'iheart', '18', '80s & 90s Hits')")

            // Public Radio parent
            try db.execute(sql: "INSERT OR IGNORE INTO genres (id, name, parentId, sortOrder) VALUES ('public-radio', 'Public Radio', NULL, 23)")
            let publicRadioSubgenres: [(String, String, Int)] = [
                ("public-radio-news", "News", 1),
                ("public-radio-talk", "Talk", 2),
                ("public-radio-npr",  "NPR",  3),
                ("public-radio-college", "College Radio", 4),
            ]
            for s in publicRadioSubgenres {
                try db.execute(sql: "INSERT OR IGNORE INTO genres (id, name, parentId, sortOrder) VALUES (?, ?, 'public-radio', ?)",
                               arguments: [s.0, s.1, s.2])
            }
            // iHeart xref for public radio
            try db.execute(sql: "INSERT OR IGNORE INTO genre_source_xref (genreId, source, sourceGenreId, sourceGenreName) VALUES ('public-radio', 'iheart', '93', 'Public Radio')")
            try db.execute(sql: "INSERT OR IGNORE INTO genre_source_xref (genreId, source, sourceGenreId, sourceGenreName) VALUES ('public-radio-news', 'iheart', '9', 'News & Talk')")

            print("SORRIVA DB: v5 decades + public radio genres added")
        }

        // v6 — local library music graph
        migrator.registerMigration("v6_local_library") { db in

            // Library sources — SMB shares, local, USB-C
            try db.create(table: "library_sources", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("type", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("host", .text).notNull().defaults(to: "")
                t.column("share", .text).notNull().defaults(to: "")
                t.column("rootPath", .text).notNull().defaults(to: "/")
                t.column("username", .text)
                t.column("password", .text)
                t.column("lastScanned", .integer)
                t.column("trackCount", .integer).notNull().defaults(to: 0)
                t.column("scanState", .text).notNull().defaults(to: "idle")
                t.column("createdAt", .integer).notNull()
                t.column("updatedAt", .integer).notNull()
            }

            // Artists
            try db.create(table: "artists", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("sortName", .text).notNull()
                t.column("imageURL", .text)
                t.column("albumCount", .integer).notNull().defaults(to: 0)
                t.column("trackCount", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .integer).notNull()
                t.column("updatedAt", .integer).notNull()
            }
            try db.create(index: "idx_artists_sortName", on: "artists",
                         columns: ["sortName"], ifNotExists: true)
            try db.create(index: "idx_artists_name", on: "artists",
                         columns: ["name"], ifNotExists: true)

            // Albums
            try db.create(table: "albums", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("sortTitle", .text).notNull()
                t.column("primaryArtistId", .text).notNull()
                    .references("artists", onDelete: .cascade)
                t.column("artistName", .text).notNull()
                t.column("year", .integer)
                t.column("genre", .text)
                t.column("artPath", .text)
                t.column("trackCount", .integer).notNull().defaults(to: 0)
                t.column("sourceId", .text).notNull()
                    .references("library_sources", onDelete: .cascade)
                t.column("folderPath", .text).notNull()
                t.column("createdAt", .integer).notNull()
                t.column("updatedAt", .integer).notNull()
            }
            try db.create(index: "idx_albums_sortTitle", on: "albums",
                         columns: ["sortTitle"], ifNotExists: true)
            try db.create(index: "idx_albums_primaryArtistId", on: "albums",
                         columns: ["primaryArtistId"], ifNotExists: true)

            // Tracks
            try db.create(table: "tracks", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("albumId", .text).notNull()
                    .references("albums", onDelete: .cascade)
                t.column("albumTitle", .text).notNull()
                t.column("primaryArtistId", .text).notNull()
                    .references("artists", onDelete: .cascade)
                t.column("artistName", .text).notNull()
                t.column("trackNumber", .integer)
                t.column("discNumber", .integer)
                t.column("year", .integer)
                t.column("genre", .text)
                t.column("duration", .double)
                t.column("fileFormat", .text).notNull()
                t.column("filePath", .text).notNull().unique()
                t.column("fileSize", .integer)
                t.column("bitrate", .integer)
                t.column("sampleRate", .integer)
                t.column("sourceId", .text).notNull()
                    .references("library_sources", onDelete: .cascade)
                t.column("createdAt", .integer).notNull()
                t.column("updatedAt", .integer).notNull()
            }
            try db.create(index: "idx_tracks_albumId", on: "tracks",
                         columns: ["albumId"], ifNotExists: true)
            try db.create(index: "idx_tracks_primaryArtistId", on: "tracks",
                         columns: ["primaryArtistId"], ifNotExists: true)
            try db.create(index: "idx_tracks_filePath", on: "tracks",
                         columns: ["filePath"], ifNotExists: true)

            // Artist-Album many-to-many
            try db.create(table: "artist_albums", ifNotExists: true) { t in
                t.column("artistId", .text).notNull()
                    .references("artists", onDelete: .cascade)
                t.column("albumId", .text).notNull()
                    .references("albums", onDelete: .cascade)
                t.column("role", .text).notNull().defaults(to: "primary")
                t.primaryKey(["artistId", "albumId"])
            }

            // Track-Artist many-to-many
            try db.create(table: "track_artists", ifNotExists: true) { t in
                t.column("trackId", .text).notNull()
                    .references("tracks", onDelete: .cascade)
                t.column("artistId", .text).notNull()
                    .references("artists", onDelete: .cascade)
                t.column("role", .text).notNull().defaults(to: "primary")
                t.primaryKey(["trackId", "artistId"])
            }

            print("SORRIVA DB: v6 local library schema created")
        }

        // v7 — add change-detection fingerprint columns to library_sources
        migrator.registerMigration("v7_scan_fingerprint") { db in
            try db.alter(table: "library_sources") { t in
                t.add(column: "lastScanFileCount", .integer)
                t.add(column: "lastScanTotalBytes", .integer)
            }
            print("SORRIVA DB: v7 scan fingerprint columns added")
        }

        // v8 — artwork cache: rename artPath → artPathThumb, add artPathFull
        // SQLite doesn't support column rename directly — rebuild albums table.
        migrator.registerMigration("v8_artwork_columns") { db in
            try db.alter(table: "albums") { t in
                t.add(column: "artPathThumb", .text)
                t.add(column: "artPathFull", .text)
            }
            // Copy existing artPath values into artPathThumb
            try db.execute(sql: "UPDATE albums SET artPathThumb = artPath WHERE artPath IS NOT NULL")
            print("SORRIVA DB: v8 artwork columns added")
        }

        // v9 — per-folder scan fingerprints for incremental rescan detection
        migrator.registerMigration("v9_folder_stats") { db in
            try db.create(table: "folder_stats", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("sourceId", .text).notNull()
                    .references("library_sources", onDelete: .cascade)
                t.column("folderPath", .text).notNull()
                t.column("fileCount", .integer).notNull()
                t.column("totalBytes", .integer).notNull()
                t.column("scannedAt", .integer).notNull()
            }
            try db.create(index: "folder_stats_by_source",
                         on: "folder_stats", columns: ["sourceId"], ifNotExists: true)
            try db.create(index: "folder_stats_unique_path",
                         on: "folder_stats", columns: ["sourceId", "folderPath"],
                         unique: true, ifNotExists: true)
            print("SORRIVA DB: v9 folder_stats table created")
        }

        // v10 — add missing album columns (embeddedArtScanned, artManualOverride)
        migrator.registerMigration("v10_album_art_columns") { db in
            let columns = try db.columns(in: "albums").map { $0.name }
            if !columns.contains("embeddedArtScanned") {
                try db.alter(table: "albums") { t in
                    t.add(column: "embeddedArtScanned", .boolean).notNull().defaults(to: false)
                }
            }
            if !columns.contains("artManualOverride") {
                try db.alter(table: "albums") { t in
                    t.add(column: "artManualOverride", .boolean).notNull().defaults(to: false)
                }
            }
            print("SORRIVA DB: v10 album art columns added")
        }

        // v11 — scan retry infrastructure: scan_skips table + embedded art retry columns on albums
        migrator.registerMigration("v11_scan_retry") { db in
            // scan_skips table — one row per audio file that failed tag read during scan
            try db.create(table: "scan_skips", ifNotExists: true) { t in
                t.column("filePath", .text).primaryKey()
                t.column("sourceId", .text).notNull()
                t.column("attemptCount", .integer).notNull().defaults(to: 0)
                t.column("lastAttemptAt", .integer).notNull().defaults(to: 0)
                t.column("resolved", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "idx_scan_skips_sourceId", on: "scan_skips",
                          columns: ["sourceId"], ifNotExists: true)

            // embeddedArtFailed — distinct from embeddedArtScanned; set when a read error occurs
            // embeddedArtRetryCount — number of failed embedded art attempts, capped at 5
            let albumColumns = try db.columns(in: "albums").map { $0.name }
            if !albumColumns.contains("embeddedArtFailed") {
                try db.alter(table: "albums") { t in
                    t.add(column: "embeddedArtFailed", .boolean).notNull().defaults(to: false)
                }
            }
            if !albumColumns.contains("embeddedArtRetryCount") {
                try db.alter(table: "albums") { t in
                    t.add(column: "embeddedArtRetryCount", .integer).notNull().defaults(to: 0)
                }
            }
            print("SORRIVA DB: v11 scan retry infrastructure added")
        }

        // v12 — move SMB credentials from SQLite to Keychain
        migrator.registerMigration("v12_keychain_credentials") { db in
            let cols = try db.columns(in: "library_sources").map { $0.name }
            if !cols.contains("credentialRef") {
                try db.alter(table: "library_sources") { t in
                    t.add(column: "credentialRef", .text)
                }
            }
            // Migrate existing plaintext credentials to Keychain
            let sources = try Row.fetchAll(db, sql: "SELECT id, username, password FROM library_sources")
            for row in sources {
                let sourceId: String = row["id"]
                let username: String? = row["username"]
                let password: String? = row["password"]
                guard let u = username, !u.isEmpty else { continue }
                let ref = KeychainCredentialStore.shared.migrateFromPlaintext(
                    sourceId: sourceId, username: u, password: password
                )
                if ref != nil {
                    try db.execute(
                        sql: "UPDATE library_sources SET credentialRef = ?, username = NULL, password = NULL WHERE id = ?",
                        arguments: [sourceId, sourceId]
                    )
                }
            }
            print("SORRIVA DB: v12 credential migration complete")
        }

        // v13 — canonical music identity tables (additive — no existing rows removed)
        migrator.registerMigration("v13_canonical_identity") { db in
            // Canonical artists
            try db.create(table: "music_artists", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("sort_name", .text).notNull()
                t.column("created_at", .integer).notNull()
            }

            // Canonical albums
            try db.create(table: "music_albums", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("sort_title", .text).notNull()
                t.column("artist_id", .text)
                t.column("year", .integer)
                t.column("genre", .text)
                t.column("created_at", .integer).notNull()
            }

            // Canonical tracks
            try db.create(table: "music_tracks", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("album_id", .text)
                t.column("artist_id", .text)
                t.column("track_number", .integer)
                t.column("disc_number", .integer)
                t.column("duration", .double)
                t.column("sort_title", .text)
                t.column("created_at", .integer).notNull()
            }

            // Track representations — one per physical file / streaming reference
            try db.create(table: "track_representations", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("track_id", .text).notNull()
                t.column("source_id", .text).notNull()
                t.column("household_id", .text)
                t.column("kind", .text).notNull()
                t.column("locator", .text).notNull()
                t.column("normalized_locator", .text).notNull()
                t.column("file_size", .integer)
                t.column("modified_at", .datetime)
                t.column("duration", .double)
                t.column("availability", .text).notNull().defaults(to: "unknown")
                t.column("last_verified_at", .datetime)
                t.uniqueKey(["source_id", "normalized_locator"])
            }

            // Legacy ID mapping — bridges legacy Track.id to canonical track ID
            try db.create(table: "legacy_track_map", ifNotExists: true) { t in
                t.column("legacy_id", .text).primaryKey()    // Track.id
                t.column("canonical_id", .text).notNull()    // music_tracks.id
            }

            // Backfill: one canonical track per existing Track row
            let now = Int(Date().timeIntervalSince1970)
            let tracks = try Row.fetchAll(db, sql: "SELECT id, title, albumId, primaryArtistId, trackNumber, discNumber, duration, sourceId, filePath, fileSize FROM tracks")
            for row in tracks {
                let legacyID: String  = row["id"]
                let canonicalID = UUID().uuidString

                // Insert canonical track
                try db.execute(sql: """
                    INSERT OR IGNORE INTO music_tracks
                    (id, title, album_id, artist_id, track_number, disc_number, duration, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    canonicalID,
                    row["title"] as String,
                    row["albumId"] as String?,
                    row["primaryArtistId"] as String?,
                    row["trackNumber"] as Int?,
                    row["discNumber"] as Int?,
                    row["duration"] as Double?,
                    now
                ])

                // Insert legacy → canonical mapping
                try db.execute(sql: """
                    INSERT OR IGNORE INTO legacy_track_map (legacy_id, canonical_id)
                    VALUES (?, ?)
                """, arguments: [legacyID, canonicalID])

                // Insert SMB representation
                let filePath: String = row["filePath"] ?? ""
                let normalized = filePath.lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let sourceId: String = row["sourceId"] ?? ""
                let reprID = UUID().uuidString

                try db.execute(sql: """
                    INSERT OR IGNORE INTO track_representations
                    (id, track_id, source_id, kind, locator, normalized_locator, file_size, duration, availability)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    reprID, canonicalID, sourceId,
                    "smbFile", filePath, normalized,
                    row["fileSize"] as Int?,
                    row["duration"] as Double?,
                    "unknown"
                ])
            }

            print("SORRIVA DB: v13 canonical identity tables created, \(tracks.count) tracks backfilled")
        }

        // v14 — album_genres: many-to-many, authoritative multi-genre source for albums.
        // Album.genre (single-value) is left untouched — nothing in the UI reads it today,
        // so this is purely additive. Stores raw freeform genre strings from file tags,
        // unlike station_genres which joins to a curated radio-genre taxonomy table —
        // local album/track genres come from whatever a tagger wrote, not a fixed list.
        migrator.registerMigration("v14_album_genres") { db in
            try db.create(table: "album_genres", ifNotExists: true) { t in
                t.column("albumId", .text).notNull().references("albums", onDelete: .cascade)
                t.column("genre", .text).notNull()
                t.primaryKey(["albumId", "genre"])
            }
            print("SORRIVA DB: v14 album_genres table created")
        }

        // v15 — artwork best-wins: two additive columns on albums storing the
        // current winning candidate's pixel dimensions, so the embedded/folder/
        // online passes can compare against each other's results instead of
        // the last pass to run always winning unconditionally.
        migrator.registerMigration("v15_artwork_dimensions") { db in
            try db.alter(table: "albums") { t in
                t.add(column: "artworkWidth", .integer)
                t.add(column: "artworkHeight", .integer)
            }
            print("SORRIVA DB: v15 artwork dimension columns added")
        }

        migrator.registerMigration("v16_scan_session") { db in
            // fScanResume. A killed scan leaves completed-folder records behind,
            // but folder_stats rows carry no indication of WHICH scan wrote them,
            // so they are indistinguishable from rows left by a previous
            // completed scan. Without that distinction, resuming would skip
            // folders the interrupted run never touched — fine on a first-ever
            // import, silently wrong on any re-import.
            //
            // scanSessionId makes "already done by THIS run" a fact rather than
            // an inference. currentScanSessionId on the source is how a resume
            // knows which session it is continuing.
            try db.alter(table: "folder_stats") { t in
                t.add(column: "scanSessionId", .text)
            }
            try db.alter(table: "library_sources") { t in
                t.add(column: "currentScanSessionId", .text)
            }
            try db.create(index: "idx_folder_stats_session", on: "folder_stats",
                          columns: ["sourceId", "scanSessionId"], ifNotExists: true)
            print("SORRIVA DB: v16 scan session columns added")
        }

        migrator.registerMigration("v17_scan_mtime_and_art_passes") { db in
            // fUnifiedScanWalkThenFilter — newest modification time in the
            // folder, so change detection can see tag-only edits. Count and
            // bytes alone cannot: taggers write into the FLAC PADDING block, so
            // the file size is unchanged (bTagEditsNotDetected).
            //
            // Nullable and left NULL for existing rows. A NULL stored mtime is
            // treated as "unknown" and forces a rescan of that folder once,
            // which is the safe direction — the alternative would be silently
            // trusting stats recorded before mtime was tracked.
            try db.alter(table: "folder_stats") { t in
                t.add(column: "maxModifiedAt", .integer)
            }

            // bArtworkPassNotResumable — per-album completion markers for the
            // folder and online passes, matching embeddedArtScanned. Semantics
            // are FolderStat's: the marker means "done for this scan", reset
            // only for albums in the folders being scanned, never reset on
            // resume, and artManualOverride albums skipped permanently.
            try db.alter(table: "albums") { t in
                t.add(column: "folderArtScanned", .boolean).notNull().defaults(to: false)
                t.add(column: "onlineArtAttempted", .boolean).notNull().defaults(to: false)
            }
            print("SORRIVA DB: v17 folder mtime + artwork pass markers added")
        }

        migrator.registerMigration("v18_scan_session_ledger") { db in
            // fScanSessionLedger. Makes a scan session a bounded, auditable unit
            // of work instead of four components that happen to run in sequence.
            //
            // The problem this solves: on 2026-07-31 a full 11,670-file scan
            // finished with 20 tracks and 5 albums outstanding in the retry
            // queue, and those queues later read as empty with no record of the
            // work having been done. Nobody could say what happened to them —
            // not the user, not the log. The app could not answer "what did this
            // scan intend to import, and what actually landed", because nothing
            // recorded the intent.
            //
            // Two tables. scan_sessions is the session itself, with a real
            // lifecycle. scan_ledger is one row per planned file, each moving to
            // a terminal outcome. The audit then becomes arithmetic —
            // planned = written + resolved + permanent + unaccounted — and any
            // unaccounted row names the exact file.

            try db.create(table: "scan_sessions", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("sourceId", .text).notNull()
                    .references("library_sources", onDelete: .cascade)
                // planning | scanning | artwork | retrying | complete | cancelled | failed
                t.column("state", .text).notNull()
                // manual | automatic | resume — a plan of zero files from an
                // automatic check is not something to prompt the user about,
                // which is what bPhantomScanInterruptedDialog is.
                t.column("trigger", .text).notNull()
                t.column("startedAt", .integer).notNull()
                t.column("endedAt", .integer)
                t.column("plannedFiles", .integer).notNull().defaults(to: 0)
                t.column("plannedFolders", .integer).notNull().defaults(to: 0)
                t.column("skippedUnchangedFiles", .integer).notNull().defaults(to: 0)
                t.column("lastProgressAt", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "idx_scan_sessions_source", on: "scan_sessions",
                          columns: ["sourceId", "state"], ifNotExists: true)

            try db.create(table: "scan_ledger", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("sessionId", .text).notNull()
                    .references("scan_sessions", onDelete: .cascade)
                t.column("sourceId", .text).notNull()
                t.column("folderPath", .text).notNull()
                t.column("filePath", .text).notNull()
                t.column("fileSize", .integer).notNull().defaults(to: 0)

                // planned | written | skipped | resolved | permanent | cancelled
                //
                // "planned" is the only non-terminal value. A session with any
                // planned rows left is not complete — which is the enforcement
                // the old scanState string could never provide, since four
                // different code paths wrote to it.
                t.column("outcome", .text).notNull().defaults(to: "planned")

                // timeout | auth | share | read | write | unsupported | notFound
                //
                // Recorded because it changes what the user should do. All 439
                // skips in the 2026-07-31 run were timeouts — very likely
                // recoverable — which is a different message and a different
                // retry policy from a corrupt file or a permission error.
                t.column("failureKind", .text)
                t.column("failureDetail", .text)

                t.column("attemptCount", .integer).notNull().defaults(to: 0)
                t.column("updatedAt", .integer).notNull().defaults(to: 0)
            }
            // Drives the audit query and the per-album "12 of 15 tracks" signal.
            try db.create(index: "idx_scan_ledger_session_outcome", on: "scan_ledger",
                          columns: ["sessionId", "outcome"], ifNotExists: true)
            try db.create(index: "idx_scan_ledger_folder", on: "scan_ledger",
                          columns: ["sessionId", "folderPath"], ifNotExists: true)
            // Lookup by path during the scan loop, recording outcomes.
            try db.create(index: "idx_scan_ledger_file", on: "scan_ledger",
                          columns: ["sessionId", "filePath"], ifNotExists: true)

            print("SORRIVA DB: v18 scan session ledger added")
        }

        migrator.registerMigration("v19_ledger_artwork") { db in
            // fScanSessionLedger, second half. Artwork joins the same ledger as
            // tracks rather than getting a parallel table.
            //
            // Rule 5 of the agreed design is "albums, tracks AND artwork are all
            // auditable". Artwork was still tracked by embeddedArtFailed and the
            // three pass markers — a separate queue with its own lifecycle,
            // which is exactly the shape that produced
            // bArtworkMarkerResetClearsRetryQueue: resetArtworkPassMarkers zeroes
            // embeddedArtFailed, the column the artwork retry queue selects on,
            // so any scan touching those folders silently empties the queue
            // rather than working it.
            //
            // One table means one audit query and one retry loop. Session,
            // source, folder, outcome, failure kind and attempts are identical
            // for both kinds; only the identifier differs (file path vs album
            // id) and artwork additionally records which pass won.
            try db.alter(table: "scan_ledger") { t in
                // track | artwork
                t.add(column: "kind", .text).notNull().defaults(to: "track")
                // embedded | folder | online | manual — artwork rows only.
                // Also the provenance the review tool needs, and what
                // bArtworkArtistQuery wanted for flagging unverified online
                // matches: iTunes always claims 600x600, so an area comparison
                // cannot tell a right match from a wrong one.
                t.add(column: "resolvedBy", .text)
            }
            try db.create(index: "idx_scan_ledger_kind", on: "scan_ledger",
                          columns: ["sessionId", "kind", "outcome"], ifNotExists: true)
            print("SORRIVA DB: v19 ledger artwork rows added")
        }

        migrator.registerMigration("v20_zone_last_playing") { db in
            // Durable "what was this zone last playing", for every zone and whatever
            // started it. zone_state already looks like this but is written only by
            // persistStationPlay, so it records the last station Sorriva *sent* rather
            // than what a zone actually ended up playing — which is why a zone that
            // received a transfer reverted to an older station once it went idle.
            //
            // Keyed by RINCON zone id to match PlaybackStore's own key, so restoring
            // needs no device-UUID mapping.
            try db.create(table: "zone_last_playing", ifNotExists: true) { t in
                t.column("zoneId", .text).primaryKey()
                t.column("uri", .text).notNull()
                t.column("track", .text).notNull().defaults(to: "")
                t.column("artist", .text).notNull().defaults(to: "")
                t.column("albumName", .text).notNull().defaults(to: "")
                t.column("artURL", .text)
                t.column("albumId", .text)
                t.column("isLocal", .boolean).notNull().defaults(to: false)
                t.column("updatedAt", .integer).notNull()
            }
            print("SORRIVA DB: v20 zone_last_playing created")
        }

        try migrator.migrate(dbQueue)
        print("SORRIVA DB: Migrations complete")
    }

    // MARK: - Household operations

    func upsertHousehold(hhid: String, sonosName: String?) throws {
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            if var existing = try Household.fetchOne(db, key: hhid) {
                existing.lastSeen = now
                existing.updatedAt = now
                if let name = sonosName { existing.sonosName = name }
                try existing.update(db)
            } else {
                let household = Household(
                    id: hhid, sonosName: sonosName, userName: nil,
                    lastSeen: now, createdAt: now, updatedAt: now,
                    deletedAt: nil, syncedAt: nil
                )
                try household.insert(db)
                print("SORRIVA DB: New household \(hhid)")
            }
        }
    }

    func household(id: String) throws -> Household? {
        try dbQueue.read { db in try Household.fetchOne(db, key: id) }
    }

    // MARK: - Device operations

    func upsertDevice(sourceId: String, source: String, householdId: String,
                      modelName: String?, sourceName: String?) throws -> Device {
        let now = Int(Date().timeIntervalSince1970)
        return try dbQueue.write { db -> Device in
            if var existing = try Device
                .filter(Device.Columns.source == source)
                .filter(Device.Columns.sourceId == sourceId)
                .fetchOne(db) {
                existing.sourceName = sourceName ?? existing.sourceName
                existing.updatedAt = now
                if let model = modelName, !model.isEmpty {
                    existing.modelName = model
                    let caps = Device.capabilitiesForModel(model)
                    existing.capabilitiesJSON = (try? String(data: JSONEncoder().encode(caps), encoding: .utf8)) ?? "[]"
                }
                try existing.update(db)
                return existing
            } else {
                let caps = modelName.map { Device.capabilitiesForModel($0) } ?? ["eq", "volume", "mute"]
                let capsJSON = (try? String(data: JSONEncoder().encode(caps), encoding: .utf8)) ?? "[]"
                let device = Device(
                    id: UUID().uuidString,
                    householdId: householdId,
                    source: source,
                    sourceId: sourceId,
                    modelName: modelName,
                    sourceName: sourceName,
                    userName: nil,
                    capabilitiesJSON: capsJSON,
                    firstSeen: now,
                    updatedAt: now,
                    deletedAt: nil,
                    syncedAt: nil
                )
                try device.insert(db)
                print("SORRIVA DB: New device \(sourceId) model=\(modelName ?? "unknown")")
                return device
            }
        }
    }

    func device(sourceId: String, source: String) throws -> Device? {
        try dbQueue.read { db in
            try Device
                .filter(Device.Columns.source == source)
                .filter(Device.Columns.sourceId == sourceId)
                .fetchOne(db)
        }
    }

    func allDevices() throws -> [Device] {
        try dbQueue.read { db in try Device.fetchAll(db) }
    }

    // MARK: - Station operations

    func upsertStation(id: Int, source: String, name: String,
                       logoURL: String?, streamURL: String?, cume: Int = 0) throws {
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            if var existing = try Station.fetchOne(db, key: id) {
                existing.name = name
                existing.logoURL = logoURL ?? existing.logoURL
                existing.streamURL = streamURL ?? existing.streamURL
                if cume > 0 { existing.cume = cume }
                existing.lastFetched = now
                existing.updatedAt = now
                try existing.update(db)
            } else {
                let station = Station(
                    id: id, source: source, name: name,
                    logoURL: logoURL, streamURL: streamURL,
                    isFavorite: false, cume: cume, lastFetched: now, updatedAt: now
                )
                try station.insert(db)
                print("SORRIVA DB: New station \(id) \(name)")
            }
        }
    }

    func toggleFavorite(stationId: Int) throws -> Bool {
        let now = Int(Date().timeIntervalSince1970)
        return try dbQueue.write { db -> Bool in
            guard var station = try Station.fetchOne(db, key: stationId) else { return false }
            station.isFavorite.toggle()
            station.updatedAt = now
            try station.update(db)
            print("SORRIVA DB: Station \(stationId) favorite=\(station.isFavorite)")
            return station.isFavorite
        }
    }

    func deleteStation(id: Int) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM station_genres WHERE stationId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM zone_state WHERE stationId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM stations WHERE id = ?", arguments: [id])
        }
    }

    func favoriteStations() throws -> [Station] {
        try dbQueue.read { db in
            try Station.filter(Station.Columns.isFavorite == true).fetchAll(db)
        }
    }

    func station(id: Int) throws -> Station? {
        try dbQueue.read { db in try Station.fetchOne(db, key: id) }
    }

    func allStations(source: String = "iheart") throws -> [Station] {
        try dbQueue.read { db in
            try Station.filter(Station.Columns.source == source).fetchAll(db)
        }
    }

    // MARK: - Zone last-playing operations

    /// Record what a zone was last known to be playing. Upsert — one row per zone.
    func upsertZoneLastPlaying(_ entry: ZoneLastPlaying) throws {
        try dbQueue.write { db in try entry.save(db) }
    }

    /// Every zone's last-playing record, for restoring the store at launch.
    func allZoneLastPlaying() throws -> [ZoneLastPlaying] {
        try dbQueue.read { db in try ZoneLastPlaying.fetchAll(db) }
    }

    /// Every station, from every source.
    ///
    /// Reverse-resolving "what station is this URI?" must not be scoped to one
    /// provider — iHeart and SomaFM are only the first of many, and a stream started
    /// outside Sorriva could be from any of them.
    func allStationsAnySource() throws -> [Station] {
        try dbQueue.read { db in try Station.fetchAll(db) }
    }

    func cachedStreamURL(stationId: Int) throws -> String? {
        try station(id: stationId)?.streamURL
    }

    // MARK: - Zone state operations

    // updateZoneState / zoneState(deviceId:) were removed here.
    //
    // zone_state cached a station name and logo per zone. It became WRITE-ONLY when phase
    // D deleted restoreZoneStateFromDB — its only reader — leaving two sites writing it on
    // every station play and transfer for nobody. PlaybackStore's zone_last_playing (v20)
    // supersedes it: URI-bound, and it carries track, artist, isLocal and the album id
    // needed to restore local artwork, none of which zone_state held.
    //
    // The TABLE is deliberately left in place. Dropping it needs a migration against real
    // data on device for no functional gain; it is inert. Tracked as bZoneStateWriteOnly.


    // MARK: - Genre operations

    /// All top-level (parent) genres, sorted by sortOrder
    func topLevelGenres() throws -> [Genre] {
        try dbQueue.read { db in
            try Genre
                .filter(Genre.Columns.parentId == nil)
                .order(Genre.Columns.sortOrder)
                .fetchAll(db)
        }
    }

    /// Subgenres for a given parent genre ID, sorted by sortOrder
    func subgenres(parentId: String) throws -> [Genre] {
        try dbQueue.read { db in
            try Genre
                .filter(Genre.Columns.parentId == parentId)
                .order(Genre.Columns.sortOrder)
                .fetchAll(db)
        }
    }

    func genre(id: String) throws -> Genre? {
        try dbQueue.read { db in try Genre.fetchOne(db, key: id) }
    }

    /// iHeart search keyword for a given genre ID
    func iheartKeyword(genreId: String) throws -> String? {
        try dbQueue.read { db in
            try GenreSourceXref
                .filter(GenreSourceXref.Columns.genreId == genreId)
                .filter(GenreSourceXref.Columns.source == "iheart")
                .fetchOne(db)?
                .sourceGenreName
        }
    }

    /// All iHeart keywords for a set of genre IDs
    func iheartKeywords(genreIds: [String]) throws -> [String] {
        try dbQueue.read { db in
            try GenreSourceXref
                .filter(genreIds.contains(GenreSourceXref.Columns.genreId))
                .filter(GenreSourceXref.Columns.source == "iheart")
                .fetchAll(db)
                .map { $0.sourceGenreName }
        }
    }

    /// Look up our internal genre ID from an iHeart numeric genre ID
    /// Used when saving stations from the browser to tag them with our canonical genre
    func internalGenreId(forIHeartGenreId iheartId: Int) throws -> String? {
        try dbQueue.read { db in
            try GenreSourceXref
                .filter(GenreSourceXref.Columns.source == "iheart")
                .filter(GenreSourceXref.Columns.sourceGenreId == "\(iheartId)")
                .fetchOne(db)?
                .genreId
        }
    }

    // MARK: - Station-Genre operations

    /// Add a genre tag to a station. Safe to call multiple times (INSERT OR IGNORE).
    func addStationGenre(stationId: Int, genreId: String) throws {
        try dbQueue.write { db in
            let sg = StationGenre(stationId: stationId, genreId: genreId)
            try sg.insert(db, onConflict: .ignore)
        }
    }

    /// All genre IDs for a station
    func genres(forStationId stationId: Int) throws -> [String] {
        try dbQueue.read { db in
            try StationGenre
                .filter(StationGenre.Columns.stationId == stationId)
                .fetchAll(db)
                .map { $0.genreId }
        }
    }

    /// Genres present in the user's station library — for filter chips on See All screen.
    /// Only returns genres that have at least one station saved.
    func genresInStationLibrary() throws -> [Genre] {
        try dbQueue.read { db in
            // Get parent genre IDs that have stations via station_genres join
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT g.id, g.name, g.parentId, g.sortOrder, g.imageURL
                FROM genres g
                INNER JOIN station_genres sg ON sg.genreId = g.id
                WHERE g.parentId IS NULL
                ORDER BY g.sortOrder
            """)
            return rows.map { row in
                Genre(id: row["id"], name: row["name"], parentId: row["parentId"],
                      sortOrder: row["sortOrder"], imageURL: row["imageURL"])
            }
        }
    }

    /// Stations in the user's library filtered by genre ID.
    func stations(inGenre genreId: String, source: String = "iheart") throws -> [Station] {
        try dbQueue.read { db in
            try Station.fetchAll(db, sql: """
                SELECT s.* FROM stations s
                INNER JOIN station_genres sg ON sg.stationId = s.id
                INNER JOIN genres g ON g.id = sg.genreId
                WHERE (g.id = ? OR g.parentId = ?)
                AND s.source = ?
            """, arguments: [genreId, genreId, source])
        }
    }

    /// Returns names of zones currently playing this station (via zone_state).
    func zonesPlayingStation(id: Int) throws -> [String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT d.name FROM zone_state zs
                JOIN devices d ON d.id = zs.deviceId
                WHERE zs.stationId = ?
            """, arguments: [id])
            return rows.map { $0["name"] as String }
        }
    }

    /// Remove a station from the library entirely.
    /// Cascades to station_genres and zone_state via FK onDelete: .cascade.
    func removeStation(id: Int) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM station_genres WHERE stationId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM zone_state WHERE stationId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM stations WHERE id = ?", arguments: [id])
            print("SORRIVA DB: Removed station \(id)")
        }
    }

    // MARK: - iHeart catalog (ephemeral browse table)
    // Dropped and recreated each time the station browser opens.
    // Raw SQL — no GRDB model needed, this is not user data.

    func rebuildIHeartCatalog(stations: [(id: Int, name: String, description: String,
                                          logoURL: String, streamURL: String?,
                                          cume: Int, genreIDs: String)]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS iheart_catalog")
            try db.execute(sql: """
                CREATE TABLE iheart_catalog (
                    id          INTEGER PRIMARY KEY,
                    name        TEXT NOT NULL,
                    description TEXT NOT NULL DEFAULT '',
                    logoURL     TEXT NOT NULL DEFAULT '',
                    streamURL   TEXT,
                    cume        INTEGER NOT NULL DEFAULT 0,
                    genreIDs    TEXT NOT NULL DEFAULT ''
                )
            """)
            for s in stations {
                try db.execute(
                    sql: """
                    INSERT INTO iheart_catalog (id, name, description, logoURL, streamURL, cume, genreIDs)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [s.id, s.name, s.description, s.logoURL, s.streamURL, s.cume, s.genreIDs]
                )
            }
            print("SORRIVA DB: iheart_catalog rebuilt with \(stations.count) stations")
        }
    }

    /// Search the ephemeral iHeart catalog.
    /// Genre filter uses iHeart genre IDs from xref + ONLY the parent genre name as
    /// a description keyword. Using subgenre names was too broad and caused false matches
    /// (e.g. "Soul Blues" subgenre matching 80s stations via "Soul" keyword).
    func searchIHeartCatalog(query: String, parentGenreId: String?,
                              existingIDs: Set<Int>) throws -> [RadioStation] {
        try dbQueue.read { db in
            var sql = "SELECT * FROM iheart_catalog WHERE 1=1"
            var args: [DatabaseValue] = []

            // Search bar — name OR description
            if !query.isEmpty {
                sql += " AND (name LIKE ? OR description LIKE ?)"
                let pattern = "%\(query)%"
                args.append(pattern.databaseValue)
                args.append(pattern.databaseValue)
            }

            // Genre chip filter
            if let parentId = parentGenreId {
                // iHeart genre IDs from xref
                let xrefRows = try Row.fetchAll(db, sql: """
                    SELECT sourceGenreId FROM genre_source_xref
                    WHERE source = 'iheart'
                    AND sourceGenreId IS NOT NULL
                    AND (genreId = ? OR genreId IN (
                        SELECT id FROM genres WHERE parentId = ?
                    ))
                """, arguments: [parentId, parentId])
                let iheartIDs = xrefRows.compactMap { $0["sourceGenreId"] as String? }

                // Parent genre name only as description keyword — avoids subgenre false matches
                let parentName = try Row.fetchOne(db, sql: "SELECT name FROM genres WHERE id = ?",
                                                   arguments: [parentId])?["name"] as String? ?? ""

                var genreClauses: [String] = []

                for iheartID in iheartIDs {
                    genreClauses.append("genreIDs LIKE ?")
                    args.append("%,\(iheartID),%".databaseValue)
                }
                if !parentName.isEmpty {
                    genreClauses.append("description LIKE ?")
                    args.append("%\(parentName)%".databaseValue)
                    genreClauses.append("name LIKE ?")
                    args.append("%\(parentName)%".databaseValue)
                }

                if !genreClauses.isEmpty {
                    sql += " AND (\(genreClauses.joined(separator: " OR ")))"
                }
            }

            sql += " ORDER BY cume DESC"

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { row in
                RadioStation(
                    id: row["id"],
                    name: row["name"],
                    description: row["description"],
                    logoURL: row["logoURL"],
                    streamURL: row["streamURL"],
                    cume: row["cume"]
                )
            }
        }
    }

    func iHeartCatalogCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM iheart_catalog") ?? 0
        }
    }


    // MARK: - Local Library operations

    func upsertLibrarySource(_ source: LibrarySource) throws {
        try dbQueue.write { db in try source.save(db) }
    }

    func allLibrarySources() throws -> [LibrarySource] {
        try dbQueue.read { db in
            try LibrarySource
                .order(LibrarySource.Columns.displayName)
                .fetchAll(db)
        }
    }

    func deleteLibrarySource(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM library_sources WHERE id = ?", arguments: [id])
        }
    }

    func deleteLibrarySourcesByHost(host: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM library_sources WHERE host = ?", arguments: [host])
        }
    }

    func updateServerCredentials(host: String, displayName: String, username: String?, password: String?) throws {
        let now = Int(Date().timeIntervalSince1970)
        let sourceIds = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM library_sources WHERE host = ?", arguments: [host])
        }
        for sourceId in sourceIds {
            if let u = username, !u.isEmpty {
                try KeychainCredentialStore.shared.set(sourceId: sourceId, username: u, password: password ?? "")
            }
        }
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE library_sources
                SET displayName = ?, username = NULL, password = NULL, updatedAt = ?
                WHERE host = ?
            """, arguments: [displayName, now, host])
        }
    }

    func allLibrarySourcesByHost() throws -> [(host: String, sources: [LibrarySource])] {
        let all = try allLibrarySources()
        var grouped: [(host: String, sources: [LibrarySource])] = []
        var seen: [String: Int] = [:]
        for source in all {
            if let idx = seen[source.host] {
                grouped[idx].sources.append(source)
            } else {
                seen[source.host] = grouped.count
                grouped.append((host: source.host, sources: [source]))
            }
        }
        return grouped
    }

    // MARK: - Model fetch from device description

    static func fetchModelName(host: String) async -> String? {
        guard let url = URL(string: "http://\(host):1400/xml/device_description.xml") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let raw = String(data: data, encoding: .utf8) ?? ""
            if let start = raw.range(of: "<modelName>"),
               let end = raw.range(of: "</modelName>") {
                return String(raw[start.upperBound..<end.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {}
        return nil
    }

    // MARK: - Music graph operations

    // MARK: Artist

    /// Insert or update an artist record. Keyed on id.
    func upsertArtist(_ artist: Artist) throws {
        try dbQueue.write { db in try artist.save(db) }
    }

    /// Find an existing artist by exact name match, or return nil.
    func artist(named name: String) throws -> Artist? {
        try dbQueue.read { db in
            try Artist
                .filter(Artist.Columns.name == name)
                .fetchOne(db)
        }
    }

    /// Case-insensitive artist lookup, trimmed of surrounding whitespace.
    /// Used by the scanner so "Yazoo", "yazoo", and "Yazoo " resolve to a single
    /// artist row across scans rather than only within one scan's cache.
    /// COLLATE NOCASE is ASCII-only, which is sufficient for tag matching here.
    func artist(namedNormalized name: String) throws -> Artist? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try dbQueue.read { db in
            try Artist
                .filter(sql: "name = ? COLLATE NOCASE", arguments: [trimmed])
                .fetchOne(db)
        }
    }

    func artist(id: String) throws -> Artist? {
        try dbQueue.read { db in try Artist.fetchOne(db, key: id) }
    }

    /// All artists sorted by sortName — used for library browse.
    func allArtists() throws -> [Artist] {
        try dbQueue.read { db in
            try Artist.order(Artist.Columns.sortName).fetchAll(db)
        }
    }

    // MARK: Album

    /// Insert or update an album record. Keyed on id.
    func upsertAlbum(_ album: Album) throws {
        try dbQueue.write { db in try album.save(db) }
    }

    /// Find an existing album by title + primaryArtistId, or return nil.
    func album(id: String) throws -> Album? {
        try dbQueue.read { db in try Album.fetchOne(db, key: id) }
    }

    func album(folderPath: String) throws -> Album? {
        try dbQueue.read { db in
            try Album
                .filter(Album.Columns.folderPath == folderPath)
                .fetchOne(db)
        }
    }

    func album(title: String, artistId: String) throws -> Album? {
        try dbQueue.read { db in
            try Album
                .filter(Album.Columns.title == title)
                .filter(Album.Columns.primaryArtistId == artistId)
                .fetchOne(db)
        }
    }

    /// All albums for a given artist, sorted by year then title.
    func albums(artistId: String) throws -> [Album] {
        try dbQueue.read { db in
            try Album
                .filter(Album.Columns.primaryArtistId == artistId)
                .order(Album.Columns.year, Album.Columns.sortTitle)
                .fetchAll(db)
        }
    }

    /// All albums for a given source, sorted by sortTitle.
    func albums(sourceId: String) throws -> [Album] {
        try dbQueue.read { db in
            try Album
                .filter(Album.Columns.sourceId == sourceId)
                .order(Album.Columns.sortTitle)
                .fetchAll(db)
        }
    }

    // MARK: Track

    /// Insert or update a track record. Keyed on id.
    func upsertTrack(_ track: Track) throws {
        try dbQueue.write { db in try track.save(db) }
    }

    /// Find an existing track by filePath — the unique natural key.
    func track(filePath: String) throws -> Track? {
        try dbQueue.read { db in
            try Track
                .filter(Track.Columns.filePath == filePath)
                .fetchOne(db)
        }
    }

    /// Look up a track by file path — the WP-02 idempotency key.
    func track(sourceId: String, filePath: String) throws -> Track? {
        try dbQueue.read { db in
            try Track
                .filter(Track.Columns.sourceId == sourceId)
                .filter(Track.Columns.filePath == filePath)
                .fetchOne(db)
        }
    }

    /// Idempotent track upsert keyed on filePath. Reuses existing id on rescan.
    /// Returns the Track as actually persisted — on a rescan this has the
    /// EXISTING row's id, not the caller's freshly-minted one. Callers that
    /// need to reference this track's id afterward (e.g. inserting into
    /// track_artists, which has a foreign key on tracks.id) must use the
    /// returned value, not the id on the Track they passed in.
    @discardableResult
    func upsertTrackIdempotent(_ track: Track) throws -> Track {
        try dbQueue.write { db in
            if let existing = try Track
                .filter(Track.Columns.filePath == track.filePath)
                .fetchOne(db) {
                var updated = track
                updated.id = existing.id
                updated.createdAt = existing.createdAt
                try updated.save(db)
                return updated
            } else {
                try track.save(db)
                return track
            }
        }
    }

    /// All tracks for a given album, sorted by discNumber then trackNumber.
    func tracks(albumId: String) throws -> [Track] {
        try dbQueue.read { db in
            try Track
                .filter(Track.Columns.albumId == albumId)
                .order(Track.Columns.discNumber, Track.Columns.trackNumber)
                .fetchAll(db)
        }
    }

    /// Total track count for a given source.
    func trackCount(sourceId: String) throws -> Int {
        try dbQueue.read { db in
            try Track
                .filter(Track.Columns.sourceId == sourceId)
                .fetchCount(db)
        }
    }

    /// Delete all tracks (and cascade to nothing — tracks are leaves) for a source.
    /// Albums and artists are cleaned up separately via deleteOrphanedAlbums/Artists.
    func deleteTracks(sourceId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM tracks WHERE sourceId = ?",
                arguments: [sourceId]
            )
        }
    }

    /// Delete albums that have no remaining tracks — called after deleteTracks.
    func deleteOrphanedAlbums() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM albums
                WHERE id NOT IN (SELECT DISTINCT albumId FROM tracks)
            """)
        }
    }

    /// Delete artists that are referenced by nothing — called after deleteOrphanedAlbums.
    ///
    /// An artist is orphaned only when no album, no track, and no track_artists row
    /// refers to it. Checking albums alone is not sufficient: since track artist and
    /// album artist are resolved independently, a compilation track's performer owns
    /// no album at all. Deleting that artist cascades through
    /// tracks.primaryArtistId (onDelete: .cascade) and removes every one of their
    /// tracks, which silently wiped all compilation tracks after each scan.
    ///
    /// NOT EXISTS rather than NOT IN — NOT IN evaluates to NULL and deletes nothing
    /// if any referenced column is ever NULL.
    func deleteOrphanedArtists() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM artists
                WHERE NOT EXISTS (
                        SELECT 1 FROM albums WHERE albums.primaryArtistId = artists.id
                      )
                  AND NOT EXISTS (
                        SELECT 1 FROM tracks WHERE tracks.primaryArtistId = artists.id
                      )
                  AND NOT EXISTS (
                        SELECT 1 FROM track_artists WHERE track_artists.artistId = artists.id
                      )
            """)
        }
    }

    // MARK: ArtistAlbum / TrackArtist junction

    func upsertArtistAlbum(artistId: String, albumId: String, role: String = "primary") throws {
        try dbQueue.write { db in
            let rec = ArtistAlbum(artistId: artistId, albumId: albumId, role: role)
            try rec.save(db)
        }
    }

    func upsertTrackArtist(trackId: String, artistId: String, role: String = "primary") throws {
        try dbQueue.write { db in
            let rec = TrackArtist(trackId: trackId, artistId: artistId, role: role)
            try rec.save(db)
        }
    }

    // MARK: Scan state + fingerprint

    /// Update scanState on a source — called by ScanCoordinator during active scan.
    func updateScanState(sourceId: String, state: String) throws {
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE library_sources
                SET scanState = ?, updatedAt = ?
                WHERE id = ?
            """, arguments: [state, now, sourceId])
        }
    }

    /// Update trackCount, lastScanned, and fingerprint on successful scan completion.
    ///
    /// Deliberately does NOT touch scanState. It used to set 'idle' here, which
    /// meant the scanner declared the whole pipeline finished the moment the
    /// FILE pass ended — before the artwork passes had even started. Two
    /// consequences, both observed 2026-07-30: a kill during artwork left the
    /// source at 'idle', which matches no branch in checkForChanges, so no
    /// interrupted-scan alert appeared and the work was lost silently; and any
    /// source left at 'idle' falls through to `default: break`, so change
    /// detection never runs for it again.
    ///
    /// scanState is ScanCoordinator's to own across the whole pipeline —
    /// scanning -> retrying -> complete. This function owns counts and
    /// fingerprint only, which is what its name says.
    func updateScanComplete(sourceId: String, trackCount: Int,
                            fileCount: Int, totalBytes: Int) throws {
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE library_sources
                SET trackCount = ?,
                    lastScanned = ?,
                    lastScanFileCount = ?,
                    lastScanTotalBytes = ?,
                    updatedAt = ?
                WHERE id = ?
            """, arguments: [trackCount, now, fileCount, totalBytes, now, sourceId])
        }
    }

    /// Update denormalized albumCount and trackCount on an artist after scan.
    func updateArtistCounts(artistId: String) throws {
        try dbQueue.write { db in
            let albumCount = try Album
                .filter(Album.Columns.primaryArtistId == artistId)
                .fetchCount(db)
            let trackCount = try Track
                .filter(Track.Columns.primaryArtistId == artistId)
                .fetchCount(db)
            let now = Int(Date().timeIntervalSince1970)
            try db.execute(sql: """
                UPDATE artists
                SET albumCount = ?, trackCount = ?, updatedAt = ?
                WHERE id = ?
            """, arguments: [albumCount, trackCount, now, artistId])
        }
    }

    /// Update denormalized trackCount on an album after scan.
    func updateAlbumTrackCount(albumId: String) throws {
        try dbQueue.write { db in
            let count = try Track
                .filter(Track.Columns.albumId == albumId)
                .fetchCount(db)
            let now = Int(Date().timeIntervalSince1970)
            try db.execute(sql: """
                UPDATE albums SET trackCount = ?, updatedAt = ? WHERE id = ?
            """, arguments: [count, now, albumId])
        }
    }

    // MARK: - Album genres (multi-value, v14)
    // Authoritative source for "what genres does this album span" — Album.genre
    // (single-value) is left untouched and unread by any UI today.

    /// Remove all genre rows for an album — called before rewriting on rescan,
    /// since retagging could change which genres are present.
    func deleteAlbumGenres(albumId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM album_genres WHERE albumId = ?", arguments: [albumId])
        }
    }

    /// Insert one genre row for an album. INSERT OR IGNORE — safe to call
    /// repeatedly for the same (albumId, genre) pair.
    func upsertAlbumGenre(albumId: String, genre: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO album_genres (albumId, genre) VALUES (?, ?)
            """, arguments: [albumId, genre])
        }
    }

    /// All distinct genres recorded for an album, sorted for stable display order.
    func albumGenres(albumId: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT genre FROM album_genres WHERE albumId = ? ORDER BY genre
            """, arguments: [albumId])
        }
    }

    // MARK: - Artwork cache

    /// Update cached artwork paths on an album after download.
    func updateAlbumArtwork(albumId: String, thumbPath: String?, fullPath: String?) throws {
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE albums SET artPathThumb = ?, artPathFull = ?, updatedAt = ? WHERE id = ?
            """, arguments: [thumbPath, fullPath, now, albumId])
        }
    }

    /// Writes artwork paths together with the winning candidate's pixel
    /// dimensions — bArtworkSelectionNotBestWins. All three passes (embedded/
    /// folder/online) call this instead of updateAlbumArtwork so later passes
    /// can compare their own candidate's area against what's already stored.
    func updateAlbumArtworkWithDimensions(
        albumId: String, thumbPath: String?, fullPath: String?, width: Int, height: Int
    ) throws {
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE albums
                SET artPathThumb = ?, artPathFull = ?, artworkWidth = ?, artworkHeight = ?, updatedAt = ?
                WHERE id = ?
            """, arguments: [thumbPath, fullPath, width, height, now, albumId])
        }
    }

    /// All albums with no artwork yet — used by ArtworkCache to find work to do.
    func albumsWithoutArtwork() throws -> [Album] {
        try dbQueue.read { db in
            try Album
                .filter(Album.Columns.artPathThumb == nil)
                .filter(Album.Columns.artManualOverride == false)
                .order(Album.Columns.sortTitle)
                .fetchAll(db)
        }
    }

    /// Albums whose current winning artwork (from any pass so far) is still
    /// below iTunes's known ceiling (600×600 = 360000px²), or has no artwork
    /// at all — online fetch can never produce anything better than 600×600,
    /// so anything already at or above that has nothing to gain from trying.
    func albumsBelowOnlineArtworkCeiling() throws -> [Album] {
        try dbQueue.read { db in
            try Album
                .filter(Album.Columns.artManualOverride == false)
                .filter(sql: "(artworkWidth IS NULL OR artworkWidth * artworkHeight < 360000)")
                .order(Album.Columns.sortTitle)
                .fetchAll(db)
        }
    }

    // MARK: - Scan session ledger (fScanSessionLedger)
    //
    // A session records what it INTENDED to do, then records every outcome
    // against that intent. It is not complete until every planned row has
    // reached a terminal outcome.
    //
    // Everything here is deliberately independent of scanState, which is a
    // string four different code paths write to and which could never express
    // "this session still has unfinished work". That gap is why a kill during
    // artwork used to be silently unrecoverable, why the retry scheduler could
    // restart itself into a hang, and why 20 tracks could leave a queue with no
    // record of being processed.

    enum ScanSessionState: String {
        case planning, scanning, artwork, retrying, complete, cancelled, failed
    }

    enum ScanTrigger: String {
        case manual, automatic, resume
    }

    enum LedgerOutcome: String {
        case planned      // not yet attempted — the ONLY non-terminal value
        case written      // track persisted
        case skipped      // attempted, failed, eligible for retry
        case resolved     // failed once, recovered on retry
        case permanent    // failed and exhausted its attempts
        case cancelled    // session cancelled before this file was reached
    }

    enum LedgerFailureKind: String {
        case timeout, auth, share, read, write, unsupported, notFound
        /// Read succeeded, the file simply contains no embedded artwork.
        /// Terminal on first occurrence — retrying cannot change the file.
        case noArtwork
    }

    enum LedgerKind: String {
        case track, artwork
    }

    enum ArtworkSource: String {
        case embedded, folder, online, manual
    }

    /// Open a session. Created before the walk, so a crash during planning still
    /// leaves a record that something was attempted.
    func createScanSession(sourceId: String, trigger: ScanTrigger) throws -> String {
        let id = UUID().uuidString
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO scan_sessions
                    (id, sourceId, state, trigger, startedAt, lastProgressAt)
                VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [id, sourceId, ScanSessionState.planning.rawValue,
                             trigger.rawValue, now, now])
        }
        return id
    }

    /// Record the plan — one row per file the scan intends to read.
    ///
    /// Written in a single transaction: at 50k files that is roughly a second,
    /// against a scan measured in hours. Recorded AFTER the filter, so the
    /// ledger describes what THIS run intended, not what the library contains.
    func recordScanPlan(sessionId: String, sourceId: String,
                        files: [(path: String, folder: String, size: Int)],
                        plannedFolders: Int, skippedUnchangedFiles: Int) throws {
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            for f in files {
                try db.execute(sql: """
                    INSERT INTO scan_ledger
                        (id, sessionId, sourceId, folderPath, filePath, fileSize,
                         outcome, kind, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, 'planned', 'track', ?)
                """, arguments: [UUID().uuidString, sessionId, sourceId,
                                 f.folder, f.path, f.size, now])
            }
            try db.execute(sql: """
                UPDATE scan_sessions
                SET plannedFiles = ?, plannedFolders = ?, skippedUnchangedFiles = ?,
                    state = ?, lastProgressAt = ?
                WHERE id = ?
            """, arguments: [files.count, plannedFolders, skippedUnchangedFiles,
                             ScanSessionState.scanning.rawValue, now, sessionId])
        }
    }

    /// Plan the artwork work for this session — one row per album whose folder
    /// is being scanned.
    ///
    /// Called after the albums exist (the file pass creates them), so this runs
    /// at the start of the artwork phase rather than at scan start. Idempotent
    /// on resume: rows already present are left alone so their outcomes survive.
    func recordArtworkPlan(sessionId: String, sourceId: String,
                           albums: [(albumId: String, folderPath: String)]) throws {
        guard !albums.isEmpty else { return }
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            for a in albums {
                let exists = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM scan_ledger
                    WHERE sessionId = ? AND kind = 'artwork' AND filePath = ?
                """, arguments: [sessionId, a.albumId]) ?? 0
                guard exists == 0 else { continue }
                try db.execute(sql: """
                    INSERT INTO scan_ledger
                        (id, sessionId, sourceId, folderPath, filePath, fileSize,
                         outcome, kind, updatedAt)
                    VALUES (?, ?, ?, ?, ?, 0, 'planned', 'artwork', ?)
                """, arguments: [UUID().uuidString, sessionId, sourceId,
                                 a.folderPath, a.albumId, now])
            }
        }
    }

    /// Albums in this session still needing artwork, in pass order.
    ///
    /// Replaces albumsNeedingEmbeddedArtScan / albumsNeedingFolderArtScan /
    /// albumsNeedingOnlineArtScan as the queue. The pass markers stay as a
    /// per-pass "already tried this pass" flag, but the SESSION's view of
    /// outstanding artwork now lives here, where nothing else can clear it.
    func artworkLedgerPending(sessionId: String) throws -> [(albumId: String, folderPath: String, attempts: Int)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT filePath, folderPath, attemptCount FROM scan_ledger
                WHERE sessionId = ? AND kind = 'artwork'
                  AND outcome IN ('planned','skipped')
                  AND attemptCount < 5
                ORDER BY folderPath
            """, arguments: [sessionId])
            return rows.map { (albumId: $0["filePath"], folderPath: $0["folderPath"],
                               attempts: $0["attemptCount"]) }
        }
    }

    /// Record the artwork outcome for one album.
    func recordArtworkOutcome(sessionId: String, albumId: String,
                              outcome: LedgerOutcome,
                              resolvedBy: ArtworkSource? = nil,
                              failureKind: LedgerFailureKind? = nil,
                              failureDetail: String? = nil,
                              incrementAttempt: Bool = false) throws {
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE scan_ledger
                SET outcome = ?, resolvedBy = ?, failureKind = ?, failureDetail = ?,
                    attemptCount = attemptCount + ?, updatedAt = ?
                WHERE sessionId = ? AND kind = 'artwork' AND filePath = ?
            """, arguments: [outcome.rawValue, resolvedBy?.rawValue, failureKind?.rawValue,
                             failureDetail, incrementAttempt ? 1 : 0, now, sessionId, albumId])
            try db.execute(sql: """
                UPDATE scan_sessions SET lastProgressAt = ? WHERE id = ?
            """, arguments: [now, sessionId])
        }
    }

    /// Close out artwork rows no pass reached.
    ///
    /// All three passes skip an album that already has artwork, so its row would
    /// stay 'planned' and the session could never report complete. Those albums
    /// are settled, not failed — they have artwork, this run simply had no work
    /// to do on them.
    func settleUntouchedArtworkRows(sessionId: String) throws {
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE scan_ledger
                SET outcome = 'written',
                    resolvedBy = COALESCE(resolvedBy, 'existing'),
                    updatedAt = ?
                WHERE sessionId = ? AND kind = 'artwork' AND outcome = 'planned'
                  AND filePath IN (
                      SELECT id FROM albums WHERE artPathThumb IS NOT NULL
                  )
            """, arguments: [now, sessionId])
            // Anything still planned has no artwork and was never attempted —
            // that IS a defect and must stay visible as unaccounted.
        }
    }

    /// Record what happened to one planned file.
    func recordLedgerOutcome(sessionId: String, filePath: String,
                             outcome: LedgerOutcome,
                             failureKind: LedgerFailureKind? = nil,
                             failureDetail: String? = nil,
                             incrementAttempt: Bool = false) throws {
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE scan_ledger
                SET outcome = ?,
                    failureKind = ?,
                    failureDetail = ?,
                    attemptCount = attemptCount + ?,
                    updatedAt = ?
                WHERE sessionId = ? AND filePath = ?
            """, arguments: [outcome.rawValue, failureKind?.rawValue, failureDetail,
                             incrementAttempt ? 1 : 0, now, sessionId, filePath])
            try db.execute(sql: """
                UPDATE scan_sessions SET lastProgressAt = ? WHERE id = ?
            """, arguments: [now, sessionId])
        }
    }

    func updateScanSessionState(sessionId: String, state: ScanSessionState) throws {
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            let terminal = [ScanSessionState.complete, .cancelled, .failed].contains(state)
            try db.execute(sql: """
                UPDATE scan_sessions
                SET state = ?, lastProgressAt = ?, endedAt = ?
                WHERE id = ?
            """, arguments: [state.rawValue, now, terminal ? now : nil, sessionId])
        }
    }

    /// The session that still has work outstanding for this source, if any.
    ///
    /// This is the enforcement point: no new scan starts while one is live, and
    /// a resume continues THIS session rather than opening another.
    func activeScanSession(sourceId: String) throws -> (id: String, state: String, trigger: String, plannedFiles: Int, lastProgressAt: Int)? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, state, trigger, plannedFiles, lastProgressAt
                FROM scan_sessions
                WHERE sourceId = ? AND state NOT IN ('complete', 'cancelled', 'failed')
                ORDER BY startedAt DESC LIMIT 1
            """, arguments: [sourceId]) else { return nil }
            return (id: row["id"], state: row["state"], trigger: row["trigger"],
                    plannedFiles: row["plannedFiles"], lastProgressAt: row["lastProgressAt"])
        }
    }

    /// Files still to do in a session — the resume list, and the completeness test.
    func unfinishedLedgerFiles(sessionId: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT filePath FROM scan_ledger
                WHERE sessionId = ? AND kind = 'track' AND outcome = 'planned'
            """, arguments: [sessionId])
        }
    }

    /// The audit. planned = written + resolved + permanent + skipped + unaccounted.
    /// Any non-zero `unaccounted` is a bug, and unfinishedLedgerFiles names them.
    func scanSessionAudit(sessionId: String, kind: LedgerKind? = nil) throws -> [String: Int] {
        try dbQueue.read { db in
            var out: [String: Int] = [:]
            let rows: [Row]
            if let kind {
                rows = try Row.fetchAll(db, sql: """
                    SELECT outcome, COUNT(*) AS n FROM scan_ledger
                    WHERE sessionId = ? AND kind = ? GROUP BY outcome
                """, arguments: [sessionId, kind.rawValue])
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT outcome, COUNT(*) AS n FROM scan_ledger
                    WHERE sessionId = ? GROUP BY outcome
                """, arguments: [sessionId])
            }
            for r in rows { out[r["outcome"]] = r["n"] }
            return out
        }
    }

    /// True while ANY row in the session — track or artwork — is still
    /// retryable. One query over one table: this is the completeness test the
    /// two parallel queues could never provide.
    func sessionHasOutstandingWork(sessionId: String) throws -> Bool {
        try dbQueue.read { db in
            let n = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM scan_ledger
                WHERE sessionId = ?
                  AND (outcome = 'planned'
                       OR (outcome = 'skipped' AND attemptCount < 5))
            """, arguments: [sessionId]) ?? 0
            return n > 0
        }
    }

    /// Per-album failure detail for the review tool and the inline
    /// "12 of 15 tracks" signal.
    func scanSessionFailuresByFolder(sessionId: String) throws -> [(folderPath: String, planned: Int, written: Int, failed: Int)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT folderPath,
                       COUNT(*) AS planned,
                       SUM(CASE WHEN outcome IN ('written','resolved') THEN 1 ELSE 0 END) AS written,
                       SUM(CASE WHEN outcome IN ('skipped','permanent') THEN 1 ELSE 0 END) AS failed
                FROM scan_ledger
                WHERE sessionId = ? AND kind = 'track'
                GROUP BY folderPath
                HAVING failed > 0
                ORDER BY folderPath
            """, arguments: [sessionId])
            return rows.map { (folderPath: $0["folderPath"], planned: $0["planned"],
                               written: $0["written"], failed: $0["failed"]) }
        }
    }

    /// Every failed file in a session, with its reason. Drives the report and
    /// the in-place retry actions.
    func scanSessionFailures(sessionId: String) throws -> [(filePath: String, folderPath: String, kind: String?, detail: String?, attempts: Int)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT filePath, folderPath, failureKind, failureDetail, attemptCount
                FROM scan_ledger
                WHERE sessionId = ? AND kind = 'track' AND outcome IN ('skipped','permanent')
                ORDER BY folderPath, filePath
            """, arguments: [sessionId])
            return rows.map { (filePath: $0["filePath"], folderPath: $0["folderPath"],
                               kind: $0["failureKind"], detail: $0["failureDetail"],
                               attempts: $0["attemptCount"]) }
        }
    }

    /// Retention: the record survives automatic scans and is cleared only when
    /// the user manually scans that same share (agreed 2026-07-31).
    func clearScanSessions(sourceId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM scan_sessions WHERE sourceId = ?",
                           arguments: [sourceId])
        }
    }

    /// Sessions for a source, newest first — the review tool's list.
    func scanSessions(sourceId: String, limit: Int = 20) throws -> [Row] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM scan_sessions WHERE sourceId = ?
                ORDER BY startedAt DESC LIMIT ?
            """, arguments: [sourceId, limit])
        }
    }

    // MARK: - Artwork pass markers (bArtworkPassNotResumable)
    //
    // All three passes now use per-album completion markers with FolderStat
    // semantics: the marker means "done for THIS scan", it is reset only for
    // albums in the folders being scanned, and it is never reset on resume.
    //
    // Two problems this solves. Resumability: quitting during the artwork phase
    // used to lose that work entirely, because the folder pass had no marker and
    // restarted from album 1, and the online pass selected on artPathThumb ==
    // nil so albums with no findable art retried forever. Scope: the folder pass
    // re-checked EVERY album on every scan — a rescan that touched 2 folders
    // still checked all 11 albums (observed 2026-07-30), which at ~1000 albums
    // means a full pass of NAS reads for folders nobody touched.
    //
    // artManualOverride albums are excluded everywhere — a human decision is
    // never re-litigated by a pass.

    /// Clear pass markers for albums in the given folders, so a rescan
    /// re-evaluates their artwork. Called at scan start with exactly the folders
    /// that are about to be scanned — NOT the whole source, or an incremental
    /// scan of 2 folders would re-evaluate artwork for every album.
    ///
    /// embeddedArtScanned is included deliberately. It used to be permanent,
    /// but a rescanned folder may contain new or replaced files carrying
    /// different embedded art, and not re-reading it would leave the library
    /// showing stale artwork indefinitely.
    func resetArtworkPassMarkers(sourceId: String, folderPaths: [String]) throws {
        guard !folderPaths.isEmpty else { return }
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            for chunk in stride(from: 0, to: folderPaths.count, by: 400).map({
                Array(folderPaths[$0..<min($0 + 400, folderPaths.count)])
            }) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                try db.execute(sql: """
                    UPDATE albums
                    SET embeddedArtScanned = 0,
                        embeddedArtFailed = 0,
                        folderArtScanned = 0,
                        onlineArtAttempted = 0,
                        updatedAt = ?
                    WHERE sourceId = ?
                      AND artManualOverride = 0
                      AND folderPath IN (\(placeholders))
                """, arguments: StatementArguments(
                    [now as DatabaseValueConvertible, sourceId as DatabaseValueConvertible]
                    + chunk.map { $0 as DatabaseValueConvertible }
                ))
            }
        }
    }

    /// Albums still needing the folder-artwork pass this scan.
    func albumsNeedingFolderArtScan(sourceId: String) throws -> [Album] {
        try dbQueue.read { db in
            try Album
                .filter(Album.Columns.sourceId == sourceId)
                .filter(sql: "folderArtScanned = 0")
                .filter(Album.Columns.artManualOverride == false)
                .order(Album.Columns.sortTitle)
                .fetchAll(db)
        }
    }

    func markFolderArtScanned(albumId: String) throws {
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE albums SET folderArtScanned = 1, updatedAt = ? WHERE id = ?
            """, arguments: [now, albumId])
        }
    }

    /// Albums still needing an online lookup this scan.
    ///
    /// Keeps the hard "no existing artwork" gate deliberately. Online fetch is
    /// gap-filling ONLY — it was reverted from best-wins participation on
    /// 2026-07-27 after a wrong iTunes match overwrote correct folder artwork:
    /// iTunes always claims 600x600, so an area comparison cannot distinguish a
    /// right match from a wrong one (bArtworkArtistQuery). A wrong match may
    /// fill an empty slot; it must never destroy something already correct.
    ///
    /// The marker is what stops albums with no findable art being re-queried on
    /// every pass forever — artPathThumb stays nil for those, so the gate alone
    /// never retires them.
    func albumsNeedingOnlineArtScan(sourceId: String) throws -> [Album] {
        try dbQueue.read { db in
            try Album
                .filter(Album.Columns.sourceId == sourceId)
                .filter(sql: "onlineArtAttempted = 0")
                .filter(Album.Columns.artManualOverride == false)
                .filter(Album.Columns.artPathThumb == nil)
                .order(Album.Columns.sortTitle)
                .fetchAll(db)
        }
    }

    func markOnlineArtAttempted(albumId: String) throws {
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE albums SET onlineArtAttempted = 1, updatedAt = ? WHERE id = ?
            """, arguments: [now, albumId])
        }
    }

    /// True while any artwork pass still has work outstanding for this source.
    /// Drives resumeArtworkIfNeeded — an interrupted artwork phase has no other
    /// way back in, since the passes only ever ran inside a scan's pipeline.
    func hasPendingArtworkWork(sourceId: String) throws -> Bool {
        try dbQueue.read { db in
            // These predicates MUST mirror the three pass selections exactly.
            //
            // They did not, and the result was a foreground loop: the online
            // pass is gap-fill only, so an album that already has artwork is
            // correctly skipped and keeps onlineArtAttempted = 0 forever. A
            // looser check here read that as pending work, so every foreground
            // ran three empty artwork passes and `continue`d past the change
            // check — meaning change detection never ran at all once any album
            // had artwork (observed 2026-07-30).
            //
            // Kept as one query rather than three round trips, at the cost of
            // having to keep it in step with albumsNeedingEmbeddedArtScan,
            // albumsNeedingFolderArtScan and albumsNeedingOnlineArtScan.
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM albums
                WHERE sourceId = ?
                  AND artManualOverride = 0
                  AND (
                        (embeddedArtScanned = 0 AND embeddedArtFailed = 0)
                     OR folderArtScanned = 0
                     OR (onlineArtAttempted = 0 AND artPathThumb IS NULL)
                  )
            """, arguments: [sourceId]) ?? 0
            return count > 0
        }
    }

    func albumsNeedingEmbeddedArtScan(sourceId: String) throws -> [Album] {
        try dbQueue.read { db in
            try Album
                .filter(Album.Columns.sourceId == sourceId)
                .filter(Album.Columns.embeddedArtScanned == false)
                .filter(Album.Columns.artManualOverride == false)
                .filter(Album.Columns.embeddedArtFailed == false)  // exclude errored albums — handled by retry
                .order(Album.Columns.sortTitle)
                .fetchAll(db)
        }
    }

    /// Marks an album as fully done with embedded art consideration — no
    /// further scanning OR retrying needed. Clears embeddedArtFailed too:
    /// without this, a genuinely confirmed "no art in this file" result
    /// (a successful read, not a transient error) still left the album in
    /// the retry queue forever, since that queue filters on embeddedArtFailed
    /// specifically, not embeddedArtScanned. Found via a real repro where an
    /// album retried indefinitely showing "attempt 2/5" without ever
    /// incrementing, since the "no art" branch never touched either flag
    /// the retry queue actually depends on.
    func markEmbeddedArtScanned(albumId: String) throws {
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE albums SET embeddedArtScanned = 1, embeddedArtFailed = 0, updatedAt = ? WHERE id = ?
            """, arguments: [now, albumId])
        }
    }

    func setArtManualOverride(albumId: String, override: Bool) throws {
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE albums SET artManualOverride = ?, updatedAt = ? WHERE id = ?
            """, arguments: [override, now, albumId])
        }
    }

    // MARK: - Embedded art retry

    /// Albums where an embedded art read error occurred and retries remain.
    /// Excludes artManualOverride albums and those permanently given up (embeddedArtScanned = true).
    func albumsNeedingEmbeddedArtRetry() throws -> [Album] {
        try dbQueue.read { db in
            try Album
                .filter(Album.Columns.embeddedArtFailed == true)
                .filter(Album.Columns.artManualOverride == false)
                .order(Album.Columns.sortTitle)
                .fetchAll(db)
        }
    }

    /// Called when an embedded art read errors (not genuine no-art).
    /// Increments retry count. At attempt 5, permanently marks scanned so it never re-queues.
    /// Rows are retained for admin review — the attempt count tells the full story.
    func markEmbeddedArtFailed(albumId: String) throws {
        try dbQueue.write { db in
            let count = try Int.fetchOne(db, sql:
                "SELECT embeddedArtRetryCount FROM albums WHERE id = ?",
                arguments: [albumId]) ?? 0
            let newCount = count + 1
            let now = Int(Date().timeIntervalSince1970)
            if newCount >= 5 {
                // Give up — mark permanently scanned so it never re-queues
                try db.execute(sql: """
                    UPDATE albums
                    SET embeddedArtFailed = 0, embeddedArtScanned = 1,
                        embeddedArtRetryCount = ?, updatedAt = ?
                    WHERE id = ?
                """, arguments: [newCount, now, albumId])
            } else {
                try db.execute(sql: """
                    UPDATE albums
                    SET embeddedArtFailed = 1, embeddedArtScanned = 0,
                        embeddedArtRetryCount = ?, updatedAt = ?
                    WHERE id = ?
                """, arguments: [newCount, now, albumId])
            }
        }
    }

    // MARK: - Scan skip (track retry)

    /// Insert a new scan skip record for a file that failed tag read during main scan.
    /// INSERT OR IGNORE — safe to call even if the file was skipped in a prior interrupted scan.
    func insertScanSkip(filePath: String, sourceId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO scan_skips (filePath, sourceId, attemptCount, lastAttemptAt, resolved)
                VALUES (?, ?, 0, ?, 0)
            """, arguments: [filePath, sourceId, Int(Date().timeIntervalSince1970)])
        }
    }

    /// Increment the attempt count and update lastAttemptAt after a failed retry.
    func incrementScanSkip(filePath: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE scan_skips SET attemptCount = attemptCount + 1, lastAttemptAt = ?
                WHERE filePath = ?
            """, arguments: [Int(Date().timeIntervalSince1970), filePath])
        }
    }

    /// Mark a skip as successfully resolved — tags were recovered.
    func resolveScanSkip(filePath: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE scan_skips SET resolved = 1, lastAttemptAt = ?
                WHERE filePath = ?
            """, arguments: [Int(Date().timeIntervalSince1970), filePath])
        }
    }

    /// All unresolved skips under attempt 5 for a given source — the active retry queue.
    func pendingScanSkips(sourceId: String) throws -> [ScanSkip] {
        try dbQueue.read { db in
            try ScanSkip
                .filter(ScanSkip.Columns.sourceId == sourceId)
                .filter(ScanSkip.Columns.resolved == false)
                .filter(ScanSkip.Columns.attemptCount < 5)
                .fetchAll(db)
        }
    }

    /// Count of permanently failed skips (5 attempts, still unresolved) — for logging and future admin UI.
    func permanentScanSkipCount(sourceId: String) throws -> Int {
        try dbQueue.read { db in
            try ScanSkip
                .filter(ScanSkip.Columns.sourceId == sourceId)
                .filter(ScanSkip.Columns.resolved == false)
                .filter(ScanSkip.Columns.attemptCount >= 5)
                .fetchCount(db)
        }
    }

    // MARK: - Track lookup and tag update (used by retry pass)

    /// Update tag fields on a track after a successful retry read.
    /// Only non-nil values are written — path-derived fields already in place are preserved.
    func updateTrackTags(
        filePath: String,
        title: String?,
        artistName: String?,
        trackNumber: Int?,
        discNumber: Int?,
        year: Int?,
        genre: String?,
        duration: Double?
    ) throws {
        try dbQueue.write { db in
            let now = Int(Date().timeIntervalSince1970)
            var sets: [String] = ["updatedAt = ?"]
            var args: [DatabaseValueConvertible] = [now]
            if let v = title       { sets.append("title = ?");       args.append(v) }
            if let v = artistName  { sets.append("artistName = ?");  args.append(v) }
            if let v = trackNumber { sets.append("trackNumber = ?"); args.append(v) }
            if let v = discNumber  { sets.append("discNumber = ?");  args.append(v) }
            if let v = year        { sets.append("year = ?");        args.append(v) }
            if let v = genre       { sets.append("genre = ?");       args.append(v) }
            if let v = duration    { sets.append("duration = ?");    args.append(v) }
            args.append(filePath)
            let sql = "UPDATE tracks SET \(sets.joined(separator: ", ")) WHERE filePath = ?"
            try db.execute(sql: sql, arguments: StatementArguments(args))
        }
    }

    // MARK: - Library browse queries

    func clearLocalLibrary() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM track_artists")
            try db.execute(sql: "DELETE FROM artist_albums")
            try db.execute(sql: "DELETE FROM tracks")
            try db.execute(sql: "DELETE FROM albums")
            try db.execute(sql: "DELETE FROM artists")
            try db.execute(sql: "DELETE FROM folder_stats")
            try db.execute(sql: "DELETE FROM scan_skips")
            try db.execute(sql: """
                UPDATE library_sources
                SET scanState = 'idle', trackCount = 0, lastScanned = NULL,
                    lastScanFileCount = NULL, lastScanTotalBytes = NULL
            """)
            print("SORRIVA DB: Local library cleared")
        }

        // Delete all cached artwork files — prevents orphaned files accumulating after each clear
        let docsDir  = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let artDir   = docsDir.appendingPathComponent("artwork")
        if FileManager.default.fileExists(atPath: artDir.path) {
            try? FileManager.default.removeItem(at: artDir)
            print("SORRIVA DB: Artwork directory cleared")
        }
    }

    /// All albums sorted by sortTitle — for Albums row and See All grid.
    func allAlbums() throws -> [Album] {
        try dbQueue.read { db in
            try Album.order(Album.Columns.sortTitle).fetchAll(db)
        }
    }

    /// All tracks sorted by title — for Tracks row and See All list.
    func allTracks() throws -> [Track] {
        try dbQueue.read { db in
            try Track.order(Track.Columns.title).fetchAll(db)
        }
    }

    /// All tracks sorted by artistName then title.
    func allTracksByArtist() throws -> [Track] {
        try dbQueue.read { db in
            try Track.order(Track.Columns.artistName, Track.Columns.title).fetchAll(db)
        }
    }

    /// All tracks sorted by albumTitle then trackNumber.
    func allTracksByAlbum() throws -> [Track] {
        try dbQueue.read { db in
            try Track.order(Track.Columns.albumTitle, Track.Columns.trackNumber).fetchAll(db)
        }
    }

    /// All tracks sorted by createdAt descending — most recently added first.
    func allTracksByRecent() throws -> [Track] {
        try dbQueue.read { db in
            try Track.order(Track.Columns.createdAt.desc).fetchAll(db)
        }
    }

    /// Returns a dictionary mapping albumId → artPathThumb for the given album IDs.
    /// Used by TracksView to display album art on track cards without per-row DB calls.
    func artPathsByAlbumId(_ albumIds: Set<String>) throws -> [String: String] {
        guard !albumIds.isEmpty else { return [:] }
        return try dbQueue.read { db in
            let placeholders = albumIds.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, artPathThumb FROM albums WHERE id IN (\(placeholders))",
                arguments: StatementArguments(albumIds.sorted())
            )
            var result: [String: String] = [:]
            for row in rows {
                if let id: String = row["id"], let path: String = row["artPathThumb"] {
                    result[id] = path
                }
            }
            return result
        }
    }

    // MARK: - FolderStat operations

    /// Upsert a folder stat record after a successful folder scan.
    ///
    /// `scanSessionId` is what makes fScanResume safe: a resume only skips
    /// folders stamped with the session it is continuing. Raw SQL for the stamp
    /// because FolderStat (in DatabaseModels.swift) has no property for it —
    /// deliberately, so this change stays inside the scan path.
    func upsertFolderStat(sourceId: String, folderPath: String,
                          fileCount: Int, totalBytes: Int,
                          maxModifiedAt: Int? = nil,
                          scanSessionId: String? = nil) throws {
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            // Check if exists
            let existing = try FolderStat
                .filter(FolderStat.Columns.sourceId == sourceId)
                .filter(FolderStat.Columns.folderPath == folderPath)
                .fetchOne(db)
            if var stat = existing {
                stat.fileCount  = fileCount
                stat.totalBytes = totalBytes
                stat.scannedAt  = now
                try stat.save(db)
            } else {
                let stat = FolderStat(
                    id: UUID().uuidString,
                    sourceId: sourceId,
                    folderPath: folderPath,
                    fileCount: fileCount,
                    totalBytes: totalBytes,
                    scannedAt: now
                )
                try stat.save(db)
            }
            try db.execute(sql: """
                UPDATE folder_stats SET scanSessionId = ?, maxModifiedAt = ?
                WHERE sourceId = ? AND folderPath = ?
            """, arguments: [scanSessionId, maxModifiedAt, sourceId, folderPath])
        }
    }

    /// Folders already completed by a specific scan session, as
    /// folderPath → (fileCount, totalBytes). Used by fScanResume to skip work
    /// the interrupted run had already finished. Returns empty for a nil or
    /// unknown session, so a resume with no recorded session degrades to a
    /// normal full scan rather than skipping everything.
    func completedFolders(sourceId: String, scanSessionId: String) throws -> [String: FolderFingerprint] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT folderPath, fileCount, totalBytes, maxModifiedAt
                FROM folder_stats
                WHERE sourceId = ? AND scanSessionId = ?
            """, arguments: [sourceId, scanSessionId])
            var out: [String: FolderFingerprint] = [:]
            for row in rows {
                let path: String = row["folderPath"]
                out[path] = FolderFingerprint(
                    fileCount: row["fileCount"],
                    totalBytes: row["totalBytes"],
                    maxModifiedAt: row["maxModifiedAt"]
                )
            }
            return out
        }
    }

    /// Every recorded folder for a source, keyed by folderPath. This is the
    /// input to fUnifiedScanWalkThenFilter's skip decision and to deletion
    /// reconciliation (folders present here but absent from the walk have been
    /// removed from disk).
    func folderFingerprints(sourceId: String) throws -> [String: FolderFingerprint] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT folderPath, fileCount, totalBytes, maxModifiedAt
                FROM folder_stats
                WHERE sourceId = ?
            """, arguments: [sourceId])
            var out: [String: FolderFingerprint] = [:]
            for row in rows {
                let path: String = row["folderPath"]
                out[path] = FolderFingerprint(
                    fileCount: row["fileCount"],
                    totalBytes: row["totalBytes"],
                    maxModifiedAt: row["maxModifiedAt"]
                )
            }
            return out
        }
    }

    /// Set (or clear, with nil) the in-flight scan session on a source.
    func setCurrentScanSessionId(sourceId: String, sessionId: String?) throws {
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE library_sources
                SET currentScanSessionId = ?, updatedAt = ?
                WHERE id = ?
            """, arguments: [sessionId, now, sourceId])
        }
    }

    /// The in-flight scan session for a source, if any. Read via raw SQL because
    /// LibrarySource has no property for this column.
    func currentScanSessionId(sourceId: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT currentScanSessionId FROM library_sources WHERE id = ?
            """, arguments: [sourceId])
        }
    }

    /// All folder stats for a source — used by statShare for change detection.
    func folderStats(sourceId: String) throws -> [FolderStat] {
        try dbQueue.read { db in
            try FolderStat
                .filter(FolderStat.Columns.sourceId == sourceId)
                .fetchAll(db)
        }
    }

    /// Delete all folder stats for a source — called on full rescan.
    func deleteFolderStats(sourceId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM folder_stats WHERE sourceId = ?",
                          arguments: [sourceId])
        }
    }

    /// Delete folder stats for specific folders — called after targeted rescan.
    func deleteFolderStats(sourceId: String, folderPaths: [String]) throws {
        guard !folderPaths.isEmpty else { return }
        try dbQueue.write { db in
            for path in folderPaths {
                try db.execute(
                    sql: "DELETE FROM folder_stats WHERE sourceId = ? AND folderPath = ?",
                    arguments: [sourceId, path]
                )
            }
        }
    }
}
