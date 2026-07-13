import Foundation
import GRDB

// MARK: - SorrivaDatabase
// Singleton database instance. Initialized on app launch.
// SQLite stored in app's Application Support directory.
// Uses GRDB migrations for schema versioning — safe across app updates.

final class SorrivaDatabase {

    static let shared = SorrivaDatabase()

    let dbQueue: DatabaseQueue

    private init() {
        let appSupport = try! FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dbURL = appSupport.appendingPathComponent("sorriva.sqlite")

        var queue = try! DatabaseQueue(path: dbURL.path)
        var migrationSucceeded = false
        do {
            try Self.runMigrations(on: queue)
            migrationSucceeded = true
        } catch {
            print("SORRIVA DB: Migration failed (\(error)) — wiping DB and retrying")
        }
        if !migrationSucceeded {
            try? FileManager.default.removeItem(at: dbURL)
            queue = try! DatabaseQueue(path: dbURL.path)
            try! Self.runMigrations(on: queue)
        }
        dbQueue = queue
        print("SORRIVA DB: Initialized at \(dbURL.path)")
    }

    // MARK: - Migrations

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

    func cachedStreamURL(stationId: Int) throws -> String? {
        try station(id: stationId)?.streamURL
    }

    // MARK: - Zone state operations

    func updateZoneState(deviceId: String, stationId: Int?,
                         stationName: String?, logoURL: String?) throws {
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            if var existing = try ZoneState.fetchOne(db, key: deviceId) {
                existing.stationId = stationId ?? existing.stationId
                existing.stationName = stationName ?? existing.stationName
                existing.stationLogoURL = logoURL ?? existing.stationLogoURL
                existing.lastUsed = now
                existing.updatedAt = now
                try existing.update(db)
            } else {
                let state = ZoneState(
                    deviceId: deviceId,
                    stationId: stationId,
                    stationName: stationName,
                    stationLogoURL: logoURL,
                    lastUsed: now,
                    updatedAt: now
                )
                try state.insert(db)
            }
        }
    }

    func zoneState(deviceId: String) throws -> ZoneState? {
        try dbQueue.read { db in try ZoneState.fetchOne(db, key: deviceId) }
    }

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
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE library_sources
                SET displayName = ?, username = ?, password = ?, updatedAt = ?
                WHERE host = ?
            """, arguments: [displayName, username, password, now, host])
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

    /// Delete artists that have no remaining albums — called after deleteOrphanedAlbums.
    func deleteOrphanedArtists() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM artists
                WHERE id NOT IN (SELECT DISTINCT primaryArtistId FROM albums)
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
    func updateScanComplete(sourceId: String, trackCount: Int,
                            fileCount: Int, totalBytes: Int) throws {
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE library_sources
                SET scanState = 'idle',
                    trackCount = ?,
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
}
