import Cocoa
import Foundation

enum Decision {
    case kill
    case restart
    case toggle
}

enum ScriptError: Error {
    case appleScript(String?)
}

extension ScriptError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .appleScript(let message):
            return message ?? "AppleScript execution failed."
        }
    }
}

enum SoundSourceWorkflow {
    /// Read the current system output volume (0-100) via AppleScript.
    /// Used as a fallback when the device exposes no CoreAudio volume property.
    static func currentOutputVolume() throws -> Int {
        try getOutputVolume()
    }

    /// Run the kill/restart/toggle flow for the given decision.
    /// `lowVolume` is the output volume the system is ramped down to before
    /// SoundSource is killed (the GUI passes no CLI arg, so it defaults to 0).
    /// `progress` is invoked from a background thread with status updates.
    static func run(
        decision: Decision,
        lowVolume: Int = 0,
        progress: @Sendable (String) -> Void
    ) throws {
        if decision == .toggle {
            let running = try soundSourceAppIsRunning()
            if running {
                progress("Killing SoundSource…")
                killSoundSourceQuietly()
                try waitUntilSoundSourceTerminated()
            } else {
                progress("Starting SoundSource…")
                try openSoundSource()
                try waitUntilSoundSourceRunning()
            }
            // progress("Done toggling SoundSource")
            return
        }

        let original = try getOutputVolume()
        progress("Volume from \(original) to \(lowVolume)…")
        try rampOutputVolume(from: original, to: lowVolume, step: -7, pauseSec: 0.1)

        progress("Killing SoundSource…")
        killSoundSourceQuietly()
        try waitUntilSoundSourceTerminated()

        if decision == .restart {
            progress("reStarting SoundSource…")
            try openSoundSource()
            try waitUntilSoundSourceRunning()
            Thread.sleep(forTimeInterval: 3)
        }

        let restoreDelaySec: Double = decision == .kill ? 0.5 : 0.4
        let restoreVolume: Int = decision == .kill ? Int(Double(original) * 0.667) : original

        progress("Volume from \(lowVolume) to \(restoreVolume)…")
        try rampOutputVolume(from: lowVolume, to: restoreVolume, step: 3, pauseSec: restoreDelaySec)

        progress(decision == .kill ? "Done killing SoundSource" : "Done reStarting SoundSource")
    }
}

private func execAppleScript(_ source: String) throws -> NSAppleEventDescriptor {
    var err: NSDictionary?
    guard let script = NSAppleScript(source: source) else {
        throw ScriptError.appleScript("Could not compile AppleScript snippet.")
    }
    let output = script.executeAndReturnError(&err)
    if let err {
        let message = err[NSLocalizedDescriptionKey] as? String ?? "\(err)"
        throw ScriptError.appleScript(message)
    }
    return output
}

private func rampOutputVolume(from startV: Int, to endV: Int, step: Int, pauseSec: Double) throws {
    let source = """
    repeat with vol from \(startV) to \(endV) by \(step)
        set volume output volume vol
        delay \(pauseSec)
    end repeat
    set volume output volume \(endV)
    """
    _ = try execAppleScript(source)
}

private func getOutputVolume() throws -> Int {
    let d = try execAppleScript("output volume of (get volume settings)")
    return Int(d.int32Value)
}

private func soundSourceAppIsRunning() throws -> Bool {
    let d = try execAppleScript("application \"SoundSource\" is running")
    return d.booleanValue
}

private func killSoundSourceQuietly() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    task.arguments = ["SoundSource"]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        /* ignore — matches 2>/dev/null */
    }
}

private func openSoundSource() throws {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-a", "SoundSource"]
    try task.run()
    task.waitUntilExit()
}

private func waitUntilSoundSourceTerminated() throws {
    var count = 0
    let timeout = 50
    while true {
        let running = try soundSourceAppIsRunning()
        count += 1
        if count >= timeout {
            fputs(
                "SoundSource still running after 5s; continuing anyway\n",
                stderr
            )
            break
        }
        if !running { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
}

private func waitUntilSoundSourceRunning() throws {
    var count = 0
    let timeout = 10
    while true {
        count += 1
        let running = try soundSourceAppIsRunning()
        if count >= timeout {
            fputs(
                "SoundSource failed to reopen after \(timeout) seconds\n",
                stderr
            )
            break
        }
        if running { break }
        Thread.sleep(forTimeInterval: 0.5)
    }
}
