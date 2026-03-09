import Foundation

/// Abstraction over model download and lifecycle management for testability.
protocol ModelManaging: AnyObject, Sendable {
    var downloadProgress: [String: Double] { get set }
    var downloadedModels: Set<String> { get set }

    func isDownloaded(_ model: TranscriptionModelInfo) -> Bool
    func ensureModel(_ model: TranscriptionModelInfo) async throws -> String
    func deleteModel(_ model: TranscriptionModelInfo) throws
    func importCustomModel(from sourceURL: URL) throws -> String
    func downloadModel(id: String, from url: URL, fileName: String) async throws -> String
    @MainActor func downloadParakeetModel(_ model: TranscriptionModelInfo) async throws
    func deleteParakeetModel(_ model: TranscriptionModelInfo)
}

extension ModelManager: ModelManaging {}
