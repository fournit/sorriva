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
        // Database path — persists across app launches
        let appSupport = try! FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dbURL = appSupport.appendingPathComponent("sorriva.sqlite")

        dbQueue = try! DatabaseQueue(path: dbURL.path)
        try! migrate()

        print("SORRIVA DB: Initialized at \(dbURL.path)")
    }

    // MARK: - Migrations

    private func migrate() throws {
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

            // Index for fast source_id lookup (e.g. RINCON → device)
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
            // Look up by source + sourceId
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
                       logoURL: String?, streamURL: String?) throws {
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            if var existing = try Station.fetchOne(db, key: id) {
                existing.name = name
                existing.logoURL = logoURL ?? existing.logoURL
                existing.streamURL = streamURL ?? existing.streamURL
                existing.lastFetched = now
                existing.updatedAt = now
                try existing.update(db)
            } else {
                let station = Station(
                    id: id, source: source, name: name,
                    logoURL: logoURL, streamURL: streamURL,
                    isFavorite: false, lastFetched: now, updatedAt: now
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
}
