import ApplicationServices
import CoreGraphics
import Foundation

/// A thin, reusable wrapper around a `CGEventTap` installed at
/// `.cgSessionEventTap` with `.defaultTap`, which — unlike an
/// `NSEvent` *global* monitor — can **consume** events.
///
/// Design notes:
/// - The tap is added to the **main** run loop (`CFRunLoopGetMain()`) in
///   `.commonModes`, so the handler runs on the main thread, the same thread
///   `NSEvent` monitors delivered on. That keeps the existing threading
///   contract with `AppDelegate` unchanged.
/// - The C callback cannot capture context, so `self` is handed through
///   `userInfo` as a retained `Unmanaged` pointer and taken back inside.
/// - The system disables a tap that takes too long, delivering
///   `.tapDisabledByTimeout` (or `.tapDisabledByUserInput` after certain
///   user input). The callback re-arms the tap in both cases; without this
///   the tap silently dies mid-session. See `reEnable()`.
/// - The handler must be **fast**: do only the match/no-match decision there
///   and hop any real work off with `DispatchQueue.main.async` /
///   `Task { @MainActor in }`. Blocking is what gets the tap disabled.
final class EventTap {

    /// Called for every event matching the mask.
    /// Return the event to let it through, or `nil` to consume it.
    /// Runs on the main run loop. Must not block.
    typealias Handler = (_ type: CGEventType, _ event: CGEvent) -> CGEvent?

    /// Why a tap could not be installed.
    enum StartFailure: CustomStringConvertible {
        case notTrusted
        case tapCreateFailed

        var description: String {
            switch self {
            case .notTrusted:
                return "Accessibility permission not granted — cannot create a CGEventTap."
            case .tapCreateFailed:
                return "CGEvent.tapCreate returned nil — cannot create a CGEventTap."
            }
        }
    }

    fileprivate let handler: Handler
    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedSelf: Unmanaged<EventTap>?

    /// True while a tap is installed and enabled.
    private(set) var isRunning = false

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit {
        // Can't call stop() here (it would resurrect self via Unmanaged),
        // but if we're deinit'ing then retainedSelf was already released.
        tearDown()
    }

    /// Installs the tap. Returns `nil` on success, or the reason it failed so
    /// the caller can fall back to passive `NSEvent` monitors.
    @discardableResult
    func start(mask: CGEventMask) -> StartFailure? {
        stop()

        guard AXIsProcessTrusted() else {
            NSLog("[EventTap] \(StartFailure.notTrusted.description)")
            return .notTrusted
        }

        let retained = Unmanaged.passRetained(self)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: retained.toOpaque())
        else {
            retained.release()
            NSLog("[EventTap] \(StartFailure.tapCreateFailed.description)")
            return .tapCreateFailed
        }

        retainedSelf = retained
        machPort = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        isRunning = true
        return nil
    }

    /// Disables the tap, removes the run loop source, invalidates the mach
    /// port and releases the pointer handed to the callback. Safe to call
    /// repeatedly and when never started.
    func stop() {
        tearDown()
        retainedSelf?.release()
        retainedSelf = nil
    }

    private func tearDown() {
        if let port = machPort {
            CGEvent.tapEnable(tap: port, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(port)
        }
        runLoopSource = nil
        machPort = nil
        isRunning = false
    }

    /// Re-arms a tap the system disabled. Called from the callback only.
    fileprivate func reEnable() {
        guard let port = machPort else { return }
        CGEvent.tapEnable(tap: port, enable: true)
        isRunning = true
    }
}

/// C function pointer — cannot capture context, so `self` arrives via `userInfo`.
private let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    // The system disabled us (we were too slow, or user input forced it).
    // Re-arm and pass the event through untouched. This must be handled or
    // the tap silently stops delivering events for the rest of the session.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo {
            Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue().reEnable()
        }
        return Unmanaged.passUnretained(event)
    }

    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()
    guard let result = tap.handler(type, event) else { return nil }
    return Unmanaged.passUnretained(result)
}

extension CGEventMask {
    static func mask(for types: CGEventType...) -> CGEventMask {
        types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }
}
