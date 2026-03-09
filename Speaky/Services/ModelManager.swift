import Foundation
import FluidAudio
import os

private let logger = Logger.speaky(category: "ModelManager")

@Observable
final class ModelManager: @unchecked Sendable {
    var downloadProgress: [String: Double] = [:]  // modelID → progress 0…1
    var downloadedModels: Set<String> = []

    private let modelsDirectory: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        modelsDirectory = appSupport.appendingPathComponent("Speaky/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        scanDownloadedModels()
    }

    func modelPath(for model: TranscriptionModelInfo) -> URL? {
        guard let fileName = model.fileName else { return nil }
        let path = modelsDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    func isDownloaded(_ model: TranscriptionModelInfo) -> Bool {
        if model.type == .groq {
            return true // Cloud model, always "available"
        }
        if model.type == .parakeet {
            return isParakeetDownloaded(model)
        }
        return downloadedModels.contains(model.id)
    }

    func ensureModel(_ model: TranscriptionModelInfo) async throws -> String {
        if let path = modelPath(for: model) {
            return path.path
        }
        guard let url = model.downloadURL, let fileName = model.fileName else {
            throw ModelManagerError.noDownloadURL
        }
        return try await downloadModel(id: model.id, from: url, fileName: fileName)
    }

    @discardableResult
    func downloadModel(id: String, from url: URL, fileName: String) async throws -> String {
        let destination = modelsDirectory.appendingPathComponent(fileName)

        await MainActor.run { self.downloadProgress[id] = 0 }
        logger.info("Starting download for model \(id) from \(url.absoluteString)")

        let data = try await downloadFileWithProgress(from: url, progressKey: id)

        try data.write(to: destination)
        logger.info("Model \(id) saved to \(destination.path) (\(data.count) bytes)")

        await MainActor.run {
            self.downloadProgress[id] = 1.0
            self.downloadedModels.insert(id)
        }

        return destination.path
    }

    func deleteModel(_ model: TranscriptionModelInfo) throws {
        guard let fileName = model.fileName else { return }
        let path = modelsDirectory.appendingPathComponent(fileName)
        try FileManager.default.removeItem(at: path)
        downloadedModels.remove(model.id)
        downloadProgress.removeValue(forKey: model.id)
        logger.info("Deleted model \(model.id)")
    }

    func importCustomModel(from sourceURL: URL) throws -> String {
        let fileName = sourceURL.lastPathComponent
        let destination = modelsDirectory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        let modelID = "custom-\(fileName)"
        downloadedModels.insert(modelID)
        return destination.path
    }

    // MARK: - Parakeet

    private func parakeetVersion(for modelID: String) -> AsrModelVersion {
        modelID.lowercased().contains("v2") ? .v2 : .v3
    }

    private func parakeetDefaultsKey(for modelID: String) -> String {
        "ParakeetModelDownloaded_\(modelID)"
    }

    func isParakeetDownloaded(_ model: TranscriptionModelInfo) -> Bool {
        UserDefaults.standard.bool(forKey: parakeetDefaultsKey(for: model.id))
    }

    @MainActor
    func downloadParakeetModel(_ model: TranscriptionModelInfo) async throws {
        let version = parakeetVersion(for: model.id)
        downloadProgress[model.id] = 0

        // Simulate progress since FluidAudio doesn't expose download progress
        let progressTask = Task { @MainActor in
            var progress = 0.0
            while progress < 0.9 {
                try await Task.sleep(for: .milliseconds(500))
                progress += Double.random(in: 0.02...0.08)
                progress = min(progress, 0.9)
                self.downloadProgress[model.id] = progress
            }
        }

        do {
            _ = try await AsrModels.downloadAndLoad(version: version)
            progressTask.cancel()
            downloadProgress[model.id] = 1.0
            downloadedModels.insert(model.id)
            UserDefaults.standard.set(true, forKey: parakeetDefaultsKey(for: model.id))
            logger.info("Parakeet model \(model.id) downloaded successfully")
        } catch {
            progressTask.cancel()
            downloadProgress.removeValue(forKey: model.id)
            UserDefaults.standard.set(false, forKey: parakeetDefaultsKey(for: model.id))
            logger.error("Parakeet download failed: \(error.localizedDescription)")
            throw error
        }
    }

    func deleteParakeetModel(_ model: TranscriptionModelInfo) {
        let version = parakeetVersion(for: model.id)
        let cacheDirectory = AsrModels.defaultCacheDirectory(for: version)

        do {
            if FileManager.default.fileExists(atPath: cacheDirectory.path) {
                try FileManager.default.removeItem(at: cacheDirectory)
            }
        } catch {
            logger.error("Failed to delete Parakeet model: \(error.localizedDescription)")
        }

        downloadedModels.remove(model.id)
        downloadProgress.removeValue(forKey: model.id)
        UserDefaults.standard.set(false, forKey: parakeetDefaultsKey(for: model.id))
        logger.info("Deleted Parakeet model \(model.id)")
    }

    // MARK: - Private

    private func downloadFileWithProgress(from url: URL, progressKey: String) async throws -> Data {
        let tempDestination = modelsDirectory.appendingPathComponent(UUID().uuidString + ".tmp")
        let state = DownloadState()
        let weakSelf = WeakBox(self)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
                if let error {
                    logger.error("Download error: \(error.localizedDescription)")
                    state.finishOnce(continuation: continuation, result: .failure(error))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      let tempURL else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                    logger.error("Bad response: HTTP \(statusCode)")
                    state.finishOnce(continuation: continuation, result: .failure(ModelManagerError.downloadFailed("HTTP \(statusCode)")))
                    return
                }

                do {
                    if FileManager.default.fileExists(atPath: tempDestination.path) {
                        try FileManager.default.removeItem(at: tempDestination)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: tempDestination)
                    let data = try Data(contentsOf: tempDestination, options: .mappedIfSafe)
                    state.finishOnce(continuation: continuation, result: .success(data))
                    try? FileManager.default.removeItem(at: tempDestination)
                } catch {
                    logger.error("File error: \(error.localizedDescription)")
                    state.finishOnce(continuation: continuation, result: .failure(error))
                }
            }

            // Track progress with throttling
            let observation = task.progress.observe(\.fractionCompleted) { progress, _ in
                let now = Date()
                let timeSince = now.timeIntervalSince(state.lastUpdateTime)
                let currentProgress = round(progress.fractionCompleted * 100) / 100

                if timeSince >= 0.5 && abs(currentProgress - state.lastProgress) >= 0.01 {
                    state.lastUpdateTime = now
                    state.lastProgress = currentProgress

                    DispatchQueue.main.async {
                        weakSelf.value?.downloadProgress[progressKey] = currentProgress
                    }
                }
            }

            state.observation = observation
            task.resume()
            logger.info("Download task started for \(progressKey)")
        }
    }

    private func scanDownloadedModels() {
        for model in TranscriptionModels.all {
            if model.type == .parakeet {
                if isParakeetDownloaded(model) {
                    downloadedModels.insert(model.id)
                }
            } else if modelPath(for: model) != nil {
                downloadedModels.insert(model.id)
            }
        }
        // Also scan for custom models
        if let files = try? FileManager.default.contentsOfDirectory(atPath: modelsDirectory.path) {
            for file in files where file.hasSuffix(".bin") {
                let knownFile = TranscriptionModels.all.contains { $0.fileName == file }
                if !knownFile {
                    downloadedModels.insert("custom-\(file)")
                }
            }
        }
        logger.info("Scanned models: \(self.downloadedModels)")
    }
}

// MARK: - Thread-safe download helpers

private final class DownloadState: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false
    var lastUpdateTime = Date()
    var lastProgress: Double = 0
    var observation: NSKeyValueObservation?

    func finishOnce(continuation: CheckedContinuation<Data, Error>, result: Result<Data, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        observation?.invalidate()
        continuation.resume(with: result)
    }
}

private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

enum ModelManagerError: LocalizedError {
    case noDownloadURL
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDownloadURL: "No download URL for this model"
        case .downloadFailed(let msg): "Download failed: \(msg)"
        }
    }
}
