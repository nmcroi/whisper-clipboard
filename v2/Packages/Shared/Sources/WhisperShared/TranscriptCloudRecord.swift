import CloudKit
import Core
import Foundation

/// The CloudKit ↔ local mapping for a transcript, plus the last-writer-wins
/// conflict decision. Kept free of any `CKSyncEngine` reference so it is fully
/// unit-testable without a CloudKit account (the engine wiring lives in
/// `HistorySyncEngine`).
///
/// One `CKRecord` of type `Transcript` maps to one `TranscriptRecord`
/// (recordName == entry id). All fields are stored inline; the two structured
/// blobs (segments, speakerNames) travel as JSON `Data`, exactly as they are
/// persisted locally, so no lossy re-encoding happens in transit.
public enum TranscriptCloudRecord {

    /// The CloudKit record type.
    public static let recordType = "Transcript"

    /// The custom private-database zone holding all transcript records.
    public static let zoneName = "Transcripts"

    /// Field keys on the `Transcript` record.
    public enum Field {
        public static let text = "text"
        public static let createdAt = "createdAt"
        public static let name = "name"
        public static let pinned = "pinned"
        public static let language = "language"
        public static let model = "model"
        public static let source = "source"
        public static let duration = "duration"
        public static let segments = "segments"          // JSON Data
        public static let speakerNames = "speakerNames"  // JSON Data
        public static let modifiedAt = "modifiedAt"      // Int64 epoch ms (LWW clock)
    }

    /// Writes the local record's fields onto a `CKRecord` (create the CKRecord
    /// with the transcript id as its recordName in the transcripts zone first,
    /// or reuse the server-provided one to preserve its change tag).
    public static func apply(_ local: TranscriptRecord, to ck: CKRecord) {
        ck[Field.text] = local.text as CKRecordValue
        ck[Field.createdAt] = local.createdAt as CKRecordValue
        ck[Field.name] = local.name as CKRecordValue
        ck[Field.pinned] = (local.pinned ? 1 : 0) as CKRecordValue
        ck[Field.language] = local.language as CKRecordValue
        ck[Field.model] = local.model as CKRecordValue
        ck[Field.source] = local.source as CKRecordValue
        ck[Field.duration] = local.duration as CKRecordValue
        ck[Field.segments] = Data(local.segments.utf8) as CKRecordValue
        ck[Field.speakerNames] = Data(local.speakerNames.utf8) as CKRecordValue
        ck[Field.modifiedAt] = local.modifiedAt as CKRecordValue
    }

    /// Reconstructs a local `TranscriptRecord` from a fetched `CKRecord`.
    /// Tolerant: missing/oddly-typed fields fall back to the same defaults the
    /// local schema uses, so a record written by a newer/older client version
    /// still decodes rather than being dropped.
    public static func local(from ck: CKRecord) -> TranscriptRecord {
        func string(_ key: String, _ fallback: String = "") -> String {
            ck[key] as? String ?? fallback
        }
        func jsonString(_ key: String, _ fallback: String) -> String {
            if let data = ck[key] as? Data, let s = String(data: data, encoding: .utf8) {
                return s
            }
            // Also accept a raw string (defensive against schema drift).
            return ck[key] as? String ?? fallback
        }
        let pinned: Bool
        if let n = ck[Field.pinned] as? Int64 { pinned = n != 0 }
        else if let n = ck[Field.pinned] as? Int { pinned = n != 0 }
        else if let b = ck[Field.pinned] as? Bool { pinned = b }
        else { pinned = false }

        let modifiedAt: Int64 = (ck[Field.modifiedAt] as? Int64)
            ?? Int64(ck[Field.modifiedAt] as? Int ?? 0)

        // Derive the sort key from createdAt (matches the local insert path).
        let createdAt = string(Field.createdAt)
        let sortKey = TranscriptEntry(id: ck.recordID.recordName, text: "", createdAt: createdAt)
            .timestamp?.timeIntervalSince1970 ?? 0

        return TranscriptRecord(
            id: ck.recordID.recordName,
            text: string(Field.text),
            createdAt: createdAt,
            name: string(Field.name),
            pinned: pinned,
            language: string(Field.language),
            model: string(Field.model),
            source: string(Field.source, "mic"),
            duration: ck[Field.duration] as? Double ?? 0,
            segments: jsonString(Field.segments, "[]"),
            sortKey: sortKey,
            speakerNames: jsonString(Field.speakerNames, "{}"),
            modifiedAt: modifiedAt
        )
    }

    // MARK: - Conflict resolution (last-writer-wins)

    /// The decision the sync engine takes when it holds both a local `modifiedAt`
    /// and a remote one for the same id.
    public enum Resolution: Equatable, Sendable {
        /// The remote copy is newer (or equal): apply it locally.
        case takeRemote
        /// The local copy is strictly newer: keep it and resubmit to the server.
        case keepLocal
    }

    /// Last-writer-wins by `modifiedAt` (epoch ms). A remote record for an id we
    /// do not have locally (`localModifiedAt == nil`) is always taken. On an
    /// exact tie the remote wins — this is deterministic and avoids a resubmit
    /// storm when two devices independently converge on the same content.
    public static func resolve(localModifiedAt: Int64?, remoteModifiedAt: Int64) -> Resolution {
        guard let local = localModifiedAt else { return .takeRemote }
        return remoteModifiedAt >= local ? .takeRemote : .keepLocal
    }
}
