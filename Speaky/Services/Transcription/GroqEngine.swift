import Foundation
import os

private let logger = Logger.speaky(category: "GroqEngine")

actor GroqEngine: TranscriptionEngine {
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func transcribe(audioFileURL: URL, language: String) async throws -> TranscriptionResult {
        let audioData = try Data(contentsOf: audioFileURL)
        let boundary = UUID().uuidString

        var request = URLRequest(url: Constants.Groq.apiURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // File field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        body.append("\r\n")

        // Model field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.append(Constants.Groq.modelName)
        body.append("\r\n")

        // Language field
        if language != "auto" {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            body.append(language)
            body.append("\r\n")
        }

        // Response format
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        body.append("verbose_json")
        body.append("\r\n")

        body.append("--\(boundary)--\r\n")
        request.httpBody = body

        let startTime = Date()
        logger.info("Sending \(audioData.count) bytes to Groq API")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.engineError("Invalid response from Groq")
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            logger.error("Groq API error (\(httpResponse.statusCode)): \(errorBody, privacy: .public)")
            throw TranscriptionError.engineError("Groq API error: HTTP \(httpResponse.statusCode)")
        }

        let decoded = try JSONDecoder().decode(GroqResponse.self, from: data)
        let duration = Date().timeIntervalSince(startTime)

        let segments = decoded.segments?.map { seg in
            TranscriptionResult.Segment(
                text: seg.text,
                start: seg.start,
                end: seg.end
            )
        } ?? []

        return TranscriptionResult(
            text: decoded.text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: decoded.language,
            duration: duration,
            segments: segments
        )
    }

    func cleanup() {
        // No resources to release
    }
}

// MARK: - Response types

private struct GroqResponse: Decodable {
    let text: String
    let language: String?
    let segments: [GroqSegment]?
}

private struct GroqSegment: Decodable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

// MARK: - Data helper

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
