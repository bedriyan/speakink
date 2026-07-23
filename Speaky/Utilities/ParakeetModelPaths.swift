import Foundation
import FluidAudio

enum ParakeetModelPaths {
    static func cacheDirectory(for version: AsrModelVersion) -> URL {
        #if DEBUG
        let folderName: String
        switch version {
        case .v2:
            folderName = "parakeet-tdt-0.6b-v2-coreml"
        case .v3:
            folderName = "parakeet-tdt-0.6b-v3-coreml"
        case .tdtCtc110m:
            folderName = "parakeet-tdt-ctc-110m-coreml"
        }

        return Constants.modelsPath
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        #else
        return AsrModels.defaultCacheDirectory(for: version)
        #endif
    }
}
