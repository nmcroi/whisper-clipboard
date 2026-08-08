import CloudKit
import Foundation

/// CloudKit mapping for a note. Note contents remain individual Transcript
/// records; the Note record stores only title/order metadata.
public enum NoteCloudRecord {
    public static let recordType = "Note"
    public static let zoneName = "Notes"

    public enum Field {
        public static let title = "title"
        public static let createdAt = "createdAt"
        public static let modifiedAt = "modifiedAt"
        public static let modifiedAtMillis = "modifiedAtMillis"
    }

    public static func apply(_ local: NoteRecord, to ck: CKRecord) {
        ck[Field.title] = local.title as CKRecordValue
        ck[Field.createdAt] = local.createdAt as CKRecordValue
        ck[Field.modifiedAt] = local.modifiedAt as CKRecordValue
        ck[Field.modifiedAtMillis] = local.modifiedAtMillis as CKRecordValue
    }

    public static func local(from ck: CKRecord) -> NoteRecord {
        let createdAt = ck[Field.createdAt] as? String ?? ""
        let modifiedAt = ck[Field.modifiedAt] as? String ?? createdAt
        let millis = (ck[Field.modifiedAtMillis] as? Int64)
            ?? Int64(ck[Field.modifiedAtMillis] as? Int ?? 0)
        return NoteRecord(
            id: ck.recordID.recordName,
            title: ck[Field.title] as? String ?? "",
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            sortKey: millis > 0 ? Double(millis) / 1000 : NoteRecord.sortKey(for: modifiedAt)
        )
    }

    public enum Resolution: Equatable, Sendable {
        case takeRemote
        case keepLocal
    }

    public static func resolve(localModifiedAt: Int64?, remoteModifiedAt: Int64) -> Resolution {
        guard let localModifiedAt else { return .takeRemote }
        return remoteModifiedAt >= localModifiedAt ? .takeRemote : .keepLocal
    }
}
