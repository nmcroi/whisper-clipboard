import Foundation

/// The result of running an AI post-processing "mode" over a transcript.
/// This is new in v2 and has no direct Python v1/v3 equivalent yet, but
/// follows the same naming and Codable conventions as the other models.
public struct AIResult: Codable, Equatable, Sendable {
    public var id: String
    public var transcriptId: String
    public var modeId: String
    public var modeName: String
    public var output: String
    public var createdAt: Date

    public init(
        id: String,
        transcriptId: String,
        modeId: String,
        modeName: String,
        output: String,
        createdAt: Date
    ) {
        self.id = id
        self.transcriptId = transcriptId
        self.modeId = modeId
        self.modeName = modeName
        self.output = output
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case transcriptId = "transcript_id"
        case modeId = "mode_id"
        case modeName = "mode_name"
        case output
        case createdAt = "created_at"
    }
}
