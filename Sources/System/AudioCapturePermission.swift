import Foundation
import Observation

/// System-audio capture permission (macOS 14.4+ process taps require it).
///
/// There is no public API to check/request this specific permission, so — like the
/// AudioCap sample — we call the private TCC SPI for the `kTCCServiceAudioCapture`
/// service. This is fine for a personal/direct-distribution app (it would not pass
/// App Store review, which is not a target here). The prompt text comes from
/// `NSAudioCaptureUsageDescription` in Info.plist.
@Observable
final class AudioCapturePermission {
    enum Status { case unknown, denied, authorized }

    private(set) var status: Status = .unknown

    private static let service = "kTCCServiceAudioCapture" as CFString

    init() { refresh() }

    var isAuthorized: Bool { status == .authorized }

    /// Re-read current authorization (0 = authorized, 1 = denied, else undetermined).
    func refresh() {
        guard let preflight = Self.preflight else { status = .unknown; return }
        switch preflight(Self.service, nil) {
        case 0: status = .authorized
        case 1: status = .denied
        default: status = .unknown
        }
    }

    /// Trigger the system permission prompt (only shows once; afterwards the user
    /// must change it in System Settings → Privacy & Security).
    func request(completion: (() -> Void)? = nil) {
        guard let request = Self.request else { completion?(); return }
        request(Self.service, nil) { [weak self] granted in
            DispatchQueue.main.async {
                self?.status = granted ? .authorized : .denied
                completion?()
            }
        }
    }

    // MARK: - Private TCC SPI (dlopen/dlsym)

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflight: PreflightFn? = {
        guard let handle, let sym = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFn.self)
    }()

    private static let request: RequestFn? = {
        guard let handle, let sym = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(sym, to: RequestFn.self)
    }()
}
