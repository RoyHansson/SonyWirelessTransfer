import Foundation

struct SonyUSBRegistrationResult: Sendable {
    let output: String
}

enum SonyUSBRegistrationError: LocalizedError {
    case toolMissing
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .toolMissing:
            return "The bundled sony-guid-setter tool is missing."
        case .executionFailed(let message):
            return message
        }
    }
}

struct SonyUSBRegistration {
    func registerCamera(completion: @escaping @Sendable (Result<SonyUSBRegistrationResult, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try self.runRegistration()
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func runRegistration() throws -> SonyUSBRegistrationResult {
        guard let toolPath = Bundle.main.resourceURL?.appendingPathComponent("sony-guid-setter").path else {
            throw SonyUSBRegistrationError.toolMissing
        }

        let escapedToolPath = toolPath.replacingOccurrences(of: "\"", with: "\\\"")
        let command = "\"\(escapedToolPath)\" -g -n Mac 054c:07c3"
        let appleScript = "do shell script \(quotedAppleScriptString(command)) with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let readHandle = outputPipe.fileHandleForReading
        let writeHandle = outputPipe.fileHandleForWriting

        defer {
            try? readHandle.close()
            try? writeHandle.close()
        }

        do {
            try process.run()
            try? writeHandle.close()
            process.waitUntilExit()
        } catch {
            throw SonyUSBRegistrationError.executionFailed("Could not start USB registration: \(error.localizedDescription)")
        }

        let outputData = readHandle.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        if process.terminationStatus != 0 {
            let message = output.isEmpty ? "USB registration failed." : output
            throw SonyUSBRegistrationError.executionFailed(message)
        }

        return SonyUSBRegistrationResult(output: output.isEmpty ? "Camera registration completed." : output)
    }

    private func quotedAppleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
