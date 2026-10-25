import CloudKit
import Foundation
import MuxCore

actor CloudSync {
    struct Snapshot {
        var profiles: [ConnectionProfile] = []
        var keys: [SSHKeyRecord] = []
    }
    private let container: CKContainer
    init(identifier: String) { container = CKContainer(identifier: identifier) }

    func synchronize(profiles: [ConnectionProfile], keys: [SSHKeyRecord]) async throws -> Snapshot {
        guard try await container.accountStatus() == .available else {
            throw MuxError.message("Sign in to iCloud to sync. Your saved connections remain available on this device.")
        }
        let database = container.privateCloudDatabase
        let records = try await fetchAll(database)
        let decoder = JSONDecoder()
        var remote = Snapshot()
        for record in records {
            guard let payload = record["payload"] as? Data,
                  let kind = record["kind"] as? String else { continue }
            if kind == "profile" { remote.profiles.append(try decoder.decode(ConnectionProfile.self, from: payload)) }
            if kind == "key" { remote.keys.append(try decoder.decode(SSHKeyRecord.self, from: payload)) }
        }
        let merged = Snapshot(profiles: ProfileMerge.merge(local: profiles, remote: remote.profiles),
                              keys: ProfileMerge.keys(local: keys, remote: remote.keys))
        let indexed = Dictionary(uniqueKeysWithValues: records.map { ($0.recordID.recordName, $0) })
        var updates: [CKRecord] = []
        let encoder = JSONEncoder()
        func add<T: Encodable>(_ value: T, kind: String, id: UUID, modified: Date) throws {
            let name = "\(kind)-\(id.uuidString)"
            let payload = try encoder.encode(value)
            if let existing = indexed[name], let date = existing["modifiedAt"] as? Date, date >= modified { return }
            let record = indexed[name] ?? CKRecord(recordType: "MuxRecord", recordID: CKRecord.ID(recordName: name))
            record["kind"] = kind as CKRecordValue
            record["payload"] = payload as CKRecordValue
            record["modifiedAt"] = modified as CKRecordValue
            updates.append(record)
        }
        for value in merged.profiles { try add(value, kind: "profile", id: value.id, modified: value.modifiedAt) }
        for value in merged.keys { try add(value, kind: "key", id: value.id, modified: value.modifiedAt) }
        for offset in stride(from: 0, to: updates.count, by: 100) {
            let batch = Array(updates[offset..<min(offset + 100, updates.count)])
            let result = try await database.modifyRecords(saving: batch, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
            for (_, saved) in result.saveResults { _ = try saved.get() }
        }
        return merged
    }

    private func fetchAll(_ database: CKDatabase) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        var page = try await database.records(matching: CKQuery(recordType: "MuxRecord", predicate: NSPredicate(value: true)), resultsLimit: 200)
        while true {
            for (_, value) in page.matchResults { records.append(try value.get()) }
            guard let cursor = page.queryCursor else { return records }
            page = try await database.records(continuingMatchFrom: cursor, resultsLimit: 200)
        }
    }
}
