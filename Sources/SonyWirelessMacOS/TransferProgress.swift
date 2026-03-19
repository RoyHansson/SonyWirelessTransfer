import Foundation

enum TransferPhase: String, Sendable {
    case idle
    case connecting
    case preparing
    case listing
    case transferring
    case finished
}

struct TransferProgressSnapshot: Sendable {
    let phase: TransferPhase
    let totalFiles: Int
    let completedFiles: Int
    let currentFileName: String
    let currentFileBytes: UInt64
    let currentFileTotalBytes: UInt64
    let downloadedImages: Int
    let downloadedMovies: Int
    let skippedExisting: Int

    static let idle = TransferProgressSnapshot(
        phase: .idle,
        totalFiles: 0,
        completedFiles: 0,
        currentFileName: "",
        currentFileBytes: 0,
        currentFileTotalBytes: 0,
        downloadedImages: 0,
        downloadedMovies: 0,
        skippedExisting: 0
    )
}
