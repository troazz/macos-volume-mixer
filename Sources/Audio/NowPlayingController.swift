import AppKit
import Foundation
import Observation

/// Current system "Now Playing" media, as reported by the bundled MediaRemote adapter.
struct NowPlaying: Equatable {
    let bundleID: String
    let parentBundleID: String?
    let title: String
    let artist: String?
    let isPlaying: Bool
}

/// Reads the system Now Playing session and sends transport commands, via the bundled
/// `ungive/mediaremote-adapter` (a framework + Perl script run through `/usr/bin/perl`,
/// which is entitled to MediaRemote on macOS 15.4+ where direct access is blocked).
///
/// We stream with `--no-diff` so each update is the complete state (an empty payload
/// means nothing is playing), and `--no-artwork` to keep payloads tiny. Only apps that
/// publish a Now Playing session appear here — which is exactly what separates a music/
/// video source from a meeting app (Teams/Meet publish none).
@Observable
final class NowPlayingController {
    private(set) var current: NowPlaying?
    /// False when the adapter/perl is unavailable — the UI then simply hides transport.
    private(set) var available = false

    enum Command: Int { case play = 0, pause = 1, togglePlayPause = 2, nextTrack = 4, previousTrack = 5 }

    @ObservationIgnored private let perl = "/usr/bin/perl"
    @ObservationIgnored private let scriptPath: String?
    @ObservationIgnored private let frameworkPath: String?
    @ObservationIgnored private var streamProcess: Process?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?

    init() {
        let base = Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteAdapter")
        let script = base?.appendingPathComponent("mediaremote-adapter.pl")
        let framework = base?.appendingPathComponent("MediaRemoteAdapter.framework")
        let fm = FileManager.default
        if let script, let framework,
           fm.isExecutableFile(atPath: perl),
           fm.fileExists(atPath: script.path),
           fm.fileExists(atPath: framework.path) {
            scriptPath = script.path
            frameworkPath = framework.path
            available = true
        } else {
            scriptPath = nil
            frameworkPath = nil
            available = false
        }

        // The Perl helper is a child process; deinit doesn't reliably run on app quit,
        // so terminate it explicitly when the app is about to exit (avoids orphans).
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.stop() }
    }

    // MARK: - Streaming

    func start() {
        guard available, streamProcess == nil, let scriptPath, let frameworkPath else { return }
        stopped = false
        buffer.removeAll(keepingCapacity: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: perl)
        process.arguments = [scriptPath, frameworkPath, "stream", "--no-diff", "--no-artwork"]
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.ingest(chunk)
        }

        process.terminationHandler = { [weak self] _ in
            guard let self, !self.stopped else { return }
            // Unexpected exit — clear state and retry after a short delay.
            DispatchQueue.main.async { self.current = nil }
            self.streamProcess = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
        }

        do {
            try process.run()
            streamProcess = process
        } catch {
            NSLog("NowPlayingController: failed to start stream: \(error)")
        }
    }

    func stop() {
        stopped = true
        streamProcess?.terminate()
        streamProcess = nil
    }

    deinit { stop() }

    /// Accumulate stdout and parse whole newline-delimited JSON objects.
    private func ingest(_ data: Data) {
        buffer.append(data)
        let newline = UInt8(ascii: "\n")
        while let idx = buffer.firstIndex(of: newline) {
            let line = buffer.subdata(in: buffer.startIndex..<idx)
            buffer.removeSubrange(buffer.startIndex...idx)
            parseLine(line)
        }
    }

    private func parseLine(_ line: Data) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (obj["type"] as? String) == "data"
        else { return }

        let payload = obj["payload"] as? [String: Any] ?? [:]
        let parsed = Self.makeNowPlaying(from: payload)
        DispatchQueue.main.async { [weak self] in self?.current = parsed }
    }

    /// Mandatory keys (bundleIdentifier, title, playing) must be present; otherwise the
    /// payload represents "no media playing".
    private static func makeNowPlaying(from payload: [String: Any]) -> NowPlaying? {
        guard let bundleID = payload["bundleIdentifier"] as? String,
              let title = payload["title"] as? String
        else { return nil }
        let isPlaying = (payload["playing"] as? NSNumber)?.boolValue ?? (payload["playing"] as? Bool) ?? false
        return NowPlaying(
            bundleID: bundleID,
            parentBundleID: payload["parentApplicationBundleIdentifier"] as? String,
            title: title,
            artist: payload["artist"] as? String,
            isPlaying: isPlaying
        )
    }

    // MARK: - Commands

    /// Send a transport command to the now-playing app (fire-and-forget).
    func send(_ command: Command) {
        guard available, let scriptPath, let frameworkPath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: perl)
        process.arguments = [scriptPath, frameworkPath, "send", String(command.rawValue)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
