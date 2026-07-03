import Core
import Foundation
import GRDB

/// GRDB persistence record for a row in the `ai_results` table (created in the
/// M2 `v3_ai_results` migration). Bridges to and from `Core.AIResult`.
struct AIResultRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "ai_results"

    var id: String
    var transcriptId: String
    var modeId: String
    var modeName: String
    var output: String
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case transcriptId = "transcript_id"
        case modeId = "mode_id"
        case modeName = "mode_name"
        case output
        case createdAt = "created_at"
    }
}

extension AIResultRecord {
    init(result: AIResult) {
        self.id = result.id
        self.transcriptId = result.transcriptId
        self.modeId = result.modeId
        self.modeName = result.modeName
        self.output = result.output
        self.createdAt = result.createdAt
    }

    var result: AIResult {
        AIResult(
            id: id,
            transcriptId: transcriptId,
            modeId: modeId,
            modeName: modeName,
            output: output,
            createdAt: createdAt
        )
    }
}
