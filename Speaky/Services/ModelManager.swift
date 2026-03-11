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

        try await downloadFileToDisk(from: url, destination: destination, progressKey: id)
        let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
        let size = attrs[.size] as? UInt64 ?? 0
        logger.info("Model \(id) saved to \(destination.path) (\(size) bytes)")

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

    func isParakeetDownloaded(_ model: TranscriptionModelInfo) -> Bool {
        let version = parakeetVersion(for: model.id)
        let cacheDir = AsrModels.defaultCacheDirectory(for: version)
        return AsrModels.modelsExist(at: cacheDir, version: version)
    }

    /// Current phase of the Parakeet download (observed by onboarding UI).
    var parakeetDownloadPhase: ParakeetDownloadPhase = .idle

    @MainActor
    func downloadParakeetModel(_ model: TranscriptionModelInfo) async throws {
        let version = parakeetVersion(for: model.id)
        let cacheDir = AsrModels.defaultCacheDirectory(for: version)
        let expectedBytes: Int64 = model.sizeBytes ?? 484_000_000

        downloadProgress[model.id] = 0
        parakeetDownloadPhase = .downloading

        // Hybrid progress: real directory monitoring + time-based interpolation.
        // FluidAudio downloads each file to a system temp dir then atomically moves it,
        // so the cache dir can go from 0 → 425MB in one instant when the encoder weight
        // file lands. We smooth this with time-based interpolation during stalls.
        let modelID = model.id
        let weakSelf = WeakBox(self)
        let monitorTask = Task.detached(priority: .utility) {
            var highWaterMark: Double = 0
            var stallStartTime = ContinuousClock.now
            var stallStartProgress: Double = 0
            var lastSize: Int64 = 0

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                let currentSize = ModelManager.directorySize(at: cacheDir)
                let realProgress = min(Double(currentSize) / Double(expectedBytes), 0.99)

                var candidate: Double
                if currentSize > lastSize {
                    // Bytes increased — file(s) landed, use real progress
                    lastSize = currentSize
                    stallStartTime = .now
                    stallStartProgress = max(realProgress, highWaterMark)
                    candidate = realProgress
                } else {
                    // No new bytes — large file downloading to system temp.
                    // Asymptotic curve: ~50% of gap at 60s, ~67% at 120s.
                    let elapsed = ContinuousClock.now - stallStartTime
                    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    let target = min(stallStartProgress + 0.45, 0.92)
                    let gap = target - stallStartProgress
                    if gap > 0.01 && seconds > 1.0 {
                        candidate = stallStartProgress + gap * (1.0 - 1.0 / (1.0 + seconds / 50.0))
                    } else {
                        candidate = highWaterMark
                    }
                }

                // Progress only goes up — never backward
                highWaterMark = max(highWaterMark, candidate)

                await MainActor.run {
                    weakSelf.value?.downloadProgress[modelID] = highWaterMark
                }
            }
        }

        do {
            // Download + compile (AsrModels.download calls DownloadUtils.loadModels
            // internally which downloads files and compiles CoreML models)
            _ = try await AsrModels.download(version: version)
            monitorTask.cancel()

            // Verify model files exist on disk
            guard AsrModels.modelsExist(at: cacheDir, version: version) else {
                throw ModelManagerError.downloadFailed("Model files not found after download")
            }

            downloadProgress[model.id] = 1.0
            parakeetDownloadPhase = .idle
            downloadedModels.insert(model.id)
            logger.info("Parakeet model \(model.id) downloaded and compiled successfully")
        } catch {
            monitorTask.cancel()
            downloadProgress.removeValue(forKey: model.id)
            parakeetDownloadPhase = .idle
            logger.error("Parakeet download failed: \(error.localizedDescription)")
            throw error
        }
    }

    private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
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
        logger.info("Deleted Parakeet model \(model.id)")
    }

    // MARK: - Private

    /// Download a file directly to disk — avoids loading the entire model into memory.
    private func downloadFileToDisk(from url: URL, destination: URL, progressKey: String) async throws {
        let state = DownloadState()
        let weakSelf = WeakBox(self)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
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
                    // Move downloaded file directly to destination — no memory copy
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    state.finishOnce(continuation: continuation, result: .success(()))
                } catch {
                    logger.error("File move error: \(error.localizedDescription)")
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

    func finishOnce(continuation: CheckedContinuation<Void, Error>, result: Result<Void, Error>) {
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

enum ParakeetDownloadPhase {
    case idle
    case downloading
    case compiling
    case warmingUp
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
