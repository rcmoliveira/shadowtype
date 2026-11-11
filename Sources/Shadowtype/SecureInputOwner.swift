// SecureInputOwner — names the process holding secure event input.
//
// `IsSecureEventInputEnabled()` is a system-wide boolean: while ANY process holds secure input,
// Shadowtype stays silent in EVERY app (see EditContextTracker.isSecure). That is correct privacy
// policy, but it is also the single most common cause of "Shadowtype stopped working" — the user
// gets no signal about why, and no way to fix it.
//
// The boolean is all the public Carbon API gives back, but the IOKit registry records WHICH session
// object owns secure input under `kCGSSessionSecureInputPID`. Reading it turns the silence into an
// actionable sentence ("held by 1Password — quit it or unlock the app"), which is what FlowIn's
// SecureInputNotifier does with the same source.
//
// Read-only, no private API: `IOConsoleUsers` is a documented IOKit property and the key is part of
// the public CoreGraphics session-dictionary layout.
import Cocoa
import IOKit

enum SecureInputOwner {
    /// The registry property FlowIn's notifier reads; a CFArray of console-session dictionaries.
    private static let consoleUsersKey = "IOConsoleUsers"
    /// Per-session key holding the secure-input owner's PID.
    private static let sessionPIDKey = "kCGSSessionSecureInputPID"

    /// The PID currently holding secure event input, or nil when it cannot be determined.
    /// `sessions` is injectable so the parsing is unit-testable without touching IOKit.
    static func pid(sessions: () -> [[String: Any]] = consoleSessions) -> pid_t? {
        for session in sessions() {
            guard let raw = session[sessionPIDKey] else { continue }
            // The registry hands back a CFNumber; through `Any` that is an Int (occasionally a
            // UInt on older shims). A zero/absent PID means "no owner", not "pid 0".
            let value: Int?
            if let n = raw as? Int { value = n }
            else if let n = raw as? UInt { value = Int(exactly: n) }
            else { value = nil }
            if let pid = value.flatMap({ Int(exactly: $0) }), pid > 0, pid <= pid_t.max {
                return pid_t(pid)
            }
        }
        return nil
    }

    /// Human-readable owner name for a PID ("1Password", "loginwindow"), nil when unknown.
    static func name(forPID pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    /// One-line diagnosis for logs and UI: "1Password (pid 4212)" / "pid 4212" / "unknown process".
    static func describe() -> String {
        guard let pid = pid() else { return "an unknown process" }
        if let name = name(forPID: pid) { return "\(name) (pid \(pid))" }
        return "pid \(pid)"
    }

    // MARK: - IOKit read

    /// The console-session dictionaries from the IOKit registry. Empty on any failure — this must
    /// never be the reason a keystroke path throws or blocks.
    static func consoleSessions() -> [[String: Any]] {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources")
        guard entry != 0 else { return [] }
        defer { IOObjectRelease(entry) }
        guard let property = IORegistryEntryCreateCFProperty(
            entry, consoleUsersKey as CFString, kCFAllocatorDefault, 0) else { return [] }
        return (property.takeRetainedValue() as? [[String: Any]]) ?? []
    }
}
