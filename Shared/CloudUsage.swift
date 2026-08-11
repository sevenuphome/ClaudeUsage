import Foundation
import CloudKit

/// Mac → iPhone bridge: the Mac app publishes the raw usage JSON into the
/// CloudKit private database; the iOS app and widget fetch it. One record,
/// always overwritten in place.
enum CloudUsage {
    static let containerID = "iCloud.com.ekkasit.ClaudeUsage"

    private static var database: CKDatabase {
        CKContainer(identifier: containerID).privateCloudDatabase
    }
    private static let recordID = CKRecord.ID(recordName: "current")

    /// Mac side: push the raw usage payload (the API response, verbatim).
    static func publish(raw: Any) async throws {
        let payload = try JSONSerialization.data(withJSONObject: raw)
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: "Usage", recordID: recordID)
        }
        record["payload"] = String(decoding: payload, as: UTF8.self)
        record["updatedAt"] = Date()
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }

    struct Fetched {
        let data: UsageData
        let updated: Date
    }

    /// iOS side: pull the latest snapshot. nil = Mac has never published.
    static func fetch() async throws -> Fetched? {
        do {
            let record = try await database.record(for: recordID)
            guard let payload = record["payload"] as? String,
                  let updated = record["updatedAt"] as? Date else { return nil }
            let data = try UsageCache.decoder.decode(UsageData.self, from: Data(payload.utf8))
            return Fetched(data: data, updated: updated)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }
}
