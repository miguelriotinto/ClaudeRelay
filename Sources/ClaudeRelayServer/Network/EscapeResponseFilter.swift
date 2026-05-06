import Foundation

/// Strips stale escape-sequence *responses* (DA, DSR, CPR, DECREQTPARM) out of
/// ring-buffer replays before we hand them to the client.
///
/// Background: while a session is detached, anything the server's `fd` asked
/// of the tty (Device Attributes, cursor position, etc.) got answered into the
/// PTY's output stream and stored in the scrollback ring buffer. On reattach,
/// replaying those bytes verbatim would deliver stale replies as input to the
/// new terminal, which renders them as visible garbage instead of consuming
/// them. This filter drops the reply bytes; the live terminal can issue fresh
/// queries if it needs them.
///
/// Only CSI (`ESC [`) sequences are scanned — the response types we care
/// about all share that prefix. Anything else passes through untouched.
enum EscapeResponseFilter {

    /// Final bytes of the CSI responses we strip:
    ///   0x63 'c' — DA   (Device Attributes)
    ///   0x52 'R' — CPR  (Cursor Position Report)
    ///   0x6E 'n' — DSR  (Device Status Report)
    ///   0x79 'y' — DECREQTPARM response
    private static let strippedFinalBytes: Set<UInt8> = [0x63, 0x52, 0x6E, 0x79]

    /// Return `data` with stale CSI response sequences removed. Pure function;
    /// safe to call from any context.
    static func filter(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }

        let bytes = [UInt8](data)
        var filtered = [UInt8]()
        filtered.reserveCapacity(bytes.count)

        var i = 0
        while i < bytes.count {
            // Look for CSI (ESC [)
            if i < bytes.count - 1 && bytes[i] == 0x1B && bytes[i + 1] == 0x5B {
                var j = i + 2
                // Scan parameter bytes (0x30–0x3F) and intermediate bytes (0x20–0x2F)
                while j < bytes.count && (
                    (bytes[j] >= 0x30 && bytes[j] <= 0x3F) ||
                    (bytes[j] >= 0x20 && bytes[j] <= 0x2F)
                ) {
                    j += 1
                }
                // Final byte is 0x40–0x7E
                if j < bytes.count && bytes[j] >= 0x40 && bytes[j] <= 0x7E {
                    if strippedFinalBytes.contains(bytes[j]) {
                        i = j + 1
                        continue
                    }
                }
            }
            filtered.append(bytes[i])
            i += 1
        }
        return Data(filtered)
    }
}
