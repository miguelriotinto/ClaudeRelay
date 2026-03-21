import Foundation

public enum OutputFormatter {

    // MARK: - JSON

    /// Format any Encodable value as a pretty-printed JSON string.
    public static func formatJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    // MARK: - Human-Readable Status

    /// Format service status for human reading.
    public static func formatStatus(
        running: Bool,
        pid: Int?,
        uptime: Int?,
        sessions: Int
    ) -> String {
        var lines: [String] = []

        let statusIcon = running ? "Running" : "Stopped"
        lines.append("Status:     \(statusIcon)")

        if let pid = pid {
            lines.append("PID:        \(pid)")
        }

        if let uptime = uptime {
            lines.append("Uptime:     \(formatUptime(uptime))")
        }

        lines.append("Sessions:   \(sessions)")

        return lines.joined(separator: "\n")
    }

    // MARK: - Table

    /// Format a list of items as an aligned table with headers.
    public static func formatTable(headers: [String], rows: [[String]]) -> String {
        guard !headers.isEmpty else { return "" }

        // Calculate column widths
        var widths = headers.map { $0.count }
        for row in rows {
            for (i, cell) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], cell.count)
            }
        }

        // Build header line
        let headerLine = headers.enumerated().map { i, h in
            h.padding(toLength: widths[i], withPad: " ", startingAt: 0)
        }.joined(separator: "  ")

        // Build separator
        let separator = widths.map { String(repeating: "-", count: $0) }
            .joined(separator: "  ")

        // Build data rows
        let dataLines = rows.map { row in
            row.enumerated().map { i, cell in
                let w = i < widths.count ? widths[i] : cell.count
                return cell.padding(toLength: w, withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }

        return ([headerLine, separator] + dataLines).joined(separator: "\n")
    }

    // MARK: - Private Helpers

    private static func formatUptime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m \(secs)s"
        } else if minutes > 0 {
            return "\(minutes)m \(secs)s"
        } else {
            return "\(secs)s"
        }
    }
}
