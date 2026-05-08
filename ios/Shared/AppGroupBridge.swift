import Foundation
import CoreFoundation
import os

// MARK: - AppGroupBridge

/// Data channel between the container app and the keyboard extension.
///
/// All persistence uses small JSON files under the shared App Group container directory.
/// Cross-process signalling uses Darwin (CFNotificationCenter) notifications — no payload
/// is carried; the receiver reads the corresponding file after waking.
///
/// Safe to import in both an iOS application target and an iOS app-extension target.
/// No UIKit / AppKit symbols are referenced.
public enum AppGroupBridge {

    public static let groupID = "group.ca.nextagent.voiceinput.shared"

    // MARK: - Data types

    /// Pending recording request written by the keyboard, consumed by the container app.
    public struct RecordRequest: Codable {
        public let id: UUID
        public let createdAt: Date
        public let language: String
        /// Bundle ID of the host app the keyboard was active in. Best-effort; may be nil.
        public let hostBundleID: String?

        public init(id: UUID = UUID(),
                    createdAt: Date = Date(),
                    language: String,
                    hostBundleID: String? = nil) {
            self.id = id
            self.createdAt = createdAt
            self.language = language
            self.hostBundleID = hostBundleID
        }
    }

    /// Snapshot of recording state emitted by the container app while it records.
    public struct LiveStatus: Codable {
        public let requestID: UUID
        public let phase: Phase
        public let partialText: String?
        public let audioLevel: Float
        public let errorMessage: String?

        public enum Phase: String, Codable {
            case starting, recording, refining, done, error, cancelled
        }

        public init(requestID: UUID,
                    phase: Phase,
                    partialText: String? = nil,
                    audioLevel: Float = 0,
                    errorMessage: String? = nil) {
            self.requestID = requestID
            self.phase = phase
            self.partialText = partialText
            self.audioLevel = audioLevel
            self.errorMessage = errorMessage
        }
    }

    /// Final transcription result written by the container app for the keyboard to consume.
    public struct Result: Codable {
        public let requestID: UUID
        public let text: String
        public let timestamp: Date

        public init(requestID: UUID, text: String, timestamp: Date = Date()) {
            self.requestID = requestID
            self.text = text
            self.timestamp = timestamp
        }
    }

    // MARK: - Darwin notification names

    public static let didStartRequestNotification = "com.voiceinput.didStartRequest"
    public static let didUpdateStatusNotification = "com.voiceinput.didUpdateStatus"
    public static let didFinishResultNotification = "com.voiceinput.didFinishResult"

    // MARK: - File-backed read / write

    public static func writeRequest(_ req: RecordRequest) {
        write(req, to: .request)
    }

    public static func readRequest() -> RecordRequest? {
        read(RecordRequest.self, from: .request)
    }

    public static func clearRequest() {
        deleteFile(.request)
    }

    public static func writeStatus(_ status: LiveStatus) {
        write(status, to: .status)
    }

    public static func readStatus() -> LiveStatus? {
        read(LiveStatus.self, from: .status)
    }

    public static func writeResult(_ result: Result) {
        write(result, to: .result)
    }

    public static func readResult() -> Result? {
        read(Result.self, from: .result)
    }

    public static func clearResult() {
        deleteFile(.result)
    }

    // MARK: - Darwin notifications

    /// Post a Darwin notification. Fire-and-forget; no payload.
    public static func post(_ name: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(name as CFString),
            nil, nil,
            true
        )
        bridgeLogger.debug("posted \(name, privacy: .public)")
    }

    /// Register a handler for a named Darwin notification.
    ///
    /// Returns an opaque token. **Retain the token** for as long as you want to receive
    /// notifications; releasing it deregisters the observer automatically via `deinit`.
    /// The handler is always dispatched to the main queue.
    public static func observe(_ name: String, handler: @escaping () -> Void) -> NSObjectProtocol {
        let token = DarwinToken(name: name, handler: handler)
        token.register()
        return token
    }

    // MARK: - Smoke-test

    /// Write a sample request, read it back, and post a Darwin notification.
    /// Logs results via os_log. Never crashes — suitable for `#if DEBUG` call sites.
    public static func selfTest() {
        let req = RecordRequest(language: "zh-CN", hostBundleID: "com.example.selftest")
        writeRequest(req)

        if let readBack = readRequest(), readBack.id == req.id {
            bridgeLogger.info("selfTest write→read PASS id=\(req.id, privacy: .public)")
        } else {
            bridgeLogger.error("selfTest write→read FAIL — App Group container may be inaccessible")
        }

        post(didStartRequestNotification)

        let containerPath = containerURL?.path ?? "<nil>"
        bridgeLogger.info("selfTest container=\(containerPath, privacy: .public)")
    }
}

// MARK: - Internal file I/O

private extension AppGroupBridge {

    enum FileKind: String {
        case request = "record_request.json"
        case status  = "live_status.json"
        case result  = "result.json"
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    static func fileURL(_ kind: FileKind) -> URL? {
        containerURL?.appendingPathComponent(kind.rawValue)
    }

    static func write<T: Encodable>(_ value: T, to kind: FileKind) {
        guard let url = fileURL(kind) else {
            bridgeLogger.error("write \(kind.rawValue, privacy: .public): no container URL — check entitlements")
            return
        }
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: [.atomic])
            bridgeLogger.debug("wrote \(kind.rawValue, privacy: .public)")
        } catch {
            bridgeLogger.error("write \(kind.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func read<T: Decodable>(_ type: T.Type, from kind: FileKind) -> T? {
        guard let url = fileURL(kind), let data = try? Data(contentsOf: url) else { return nil }
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            bridgeLogger.warning("read \(kind.rawValue, privacy: .public): decode failed — stale or corrupt file")
            return nil
        }
        return value
    }

    static func deleteFile(_ kind: FileKind) {
        guard let url = fileURL(kind) else { return }
        try? FileManager.default.removeItem(at: url)
        bridgeLogger.debug("cleared \(kind.rawValue, privacy: .public)")
    }
}

// MARK: - Logger (file-private so both extensions share it)

private let bridgeLogger = Logger(subsystem: "com.voiceinput.app", category: "AppGroupBridge")

// MARK: - Darwin observer token

/// Heap-boxed Swift closure. Round-tripped through a raw `UnsafeMutableRawPointer`
/// that CFNotificationCenter holds as the `observer` identifier.
private final class ClosureBox {
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
}

/// C-function trampoline required by CFNotificationCenterAddObserver.
///
/// `observer` is the `UnsafeMutableRawPointer` we passed at registration time.
/// It points to a `ClosureBox` that is kept alive by `DarwinToken` (via a strong
/// reference stored in `DarwinToken.box`). We take an **unretained** value here —
/// no ARC manipulation in the callback — so lifetime is solely governed by the
/// token's `deinit`.
private let darwinCallbackTrampoline: CFNotificationCallback = { _, observer, _, _, _ in
    guard let observer else { return }
    let box = Unmanaged<ClosureBox>.fromOpaque(observer).takeUnretainedValue()
    DispatchQueue.main.async { box.body() }
}

/// Opaque token returned by `AppGroupBridge.observe(_:handler:)`.
///
/// Retaining this object keeps the Darwin observer alive. Releasing it (or letting
/// it fall out of scope) removes the observer and releases the closure.
///
/// Implementation notes on the trampoline:
///   - `CFNotificationCenterAddObserver` uses the `observer` pointer *both* as the
///     callback context AND as the registration identity for later removal.
///   - We allocate a `ClosureBox` on the Swift heap and store a strong reference in
///     `self.box` so ARC keeps it alive for the token's lifetime.
///   - We pass `Unmanaged.passUnretained(box).toOpaque()` — no extra retain.
///     The trampoline recovers the box with `takeUnretainedValue` — no extra release.
///   - `deinit` calls `CFNotificationCenterRemoveObserver` with the same pointer,
///     then lets `self.box` drop naturally (Swift ARC releases the ClosureBox).
private final class DarwinToken: NSObject {

    private let name: String
    private let box: ClosureBox
    private var observerPtr: UnsafeMutableRawPointer?

    init(name: String, handler: @escaping () -> Void) {
        self.name = name
        self.box = ClosureBox(handler)
    }

    func register() {
        guard observerPtr == nil else { return }

        // Unretained: DarwinToken owns `box` via the strong stored property.
        // The pointer value is stable for the lifetime of `box` (heap object).
        let ptr = Unmanaged.passUnretained(box).toOpaque()
        observerPtr = ptr

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            ptr,
            darwinCallbackTrampoline,
            name as CFString,
            nil,                     // Darwin notifications have no `object`
            .deliverImmediately
        )
        bridgeLogger.debug("registered Darwin observer \(self.name, privacy: .public)")
    }

    deinit {
        if let ptr = observerPtr {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                ptr,
                CFNotificationName(name as CFString),
                nil
            )
            bridgeLogger.debug("removed Darwin observer \(self.name, privacy: .public)")
        }
    }
}
