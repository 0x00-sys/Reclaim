import Foundation

struct SubprocessResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool { status == 0 }
}

enum SubprocessError: Error {
    case launchFailed(String)
}

/// Runs an executable with an argument array — never through a shell.
func runSubprocess(
    _ executable: String,
    _ arguments: [String],
    currentDirectory: String? = nil
) async throws -> SubprocessResult {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    if let currentDirectory {
        process.currentDirectoryURL = URL(filePath: currentDirectory)
    }
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    process.standardInput = FileHandle.nullDevice

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: SubprocessError.launchFailed("\(executable): \(error.localizedDescription)"))
                    return
                }
                // Drain both pipes fully before waiting to avoid deadlock on large output.
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: SubprocessResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    } onCancel: {
        if process.isRunning { process.terminate() }
    }
}
