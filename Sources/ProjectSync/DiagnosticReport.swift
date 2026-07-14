import AppKit
import Foundation
import UniformTypeIdentifiers

/// Produces a support report without opening source/destination files or
/// including job notes, SSH usernames, log paths, or exclusion names.
struct DiagnosticReportBuilder {
    let jobs: [SyncJob]
    let runRecords: [RunRecord]
    let appVersion: String
    let settingsSummary: [String: String]
    let recentLogTails: [UUID: String]

    init(
        jobs: [SyncJob],
        runRecords: [RunRecord],
        appVersion: String,
        settingsSummary: [String: String] = [:],
        recentLogTails: [UUID: String] = [:]
    ) {
        self.jobs = jobs
        self.runRecords = runRecords
        self.appVersion = appVersion
        self.settingsSummary = settingsSummary
        self.recentLogTails = recentLogTails
    }

    func makeText(generatedAt: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var lines = [
            "Project Sync Diagnostic Report",
            "Generated: \(formatter.string(from: generatedAt))",
            "App version: \(redact(appVersion))",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Architecture: \(Self.architecture)",
            "",
            "Privacy note: This report does not read or include file contents, job notes, SSH usernames, SSH secrets, or full log paths.",
            ""
        ]

        lines.append("Settings")
        if settingsSummary.isEmpty {
            lines.append("- No settings supplied")
        } else {
            for (key, value) in settingsSummary.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
                let safeValue = isSensitiveSetting(key) ? "<redacted>" : redact(value)
                lines.append("- \(redact(key)): \(safeValue)")
            }
        }

        lines.append("")
        lines.append("Jobs (\(jobs.count))")
        if jobs.isEmpty {
            lines.append("- No jobs configured")
        }
        for job in jobs {
            lines.append("- \(redact(job.name)) [\(job.id.uuidString)]")
            lines.append("  Enabled: \(job.enabled ? "Yes" : "No")")
            lines.append("  Mode: \(job.mode.rawValue)")
            lines.append("  Schedule: \(redact(job.schedule.summary))")
            lines.append("  Source: \(endpointSummary(job.source))")
            lines.append("  Destination: \(endpointSummary(job.destination))")
            lines.append("  Exclusions: \(job.exclusions.count) configured (names omitted)")
            lines.append("  Preserve extended attributes: \(job.preserveExtendedAttributes ? "Yes" : "No")")
            lines.append("  Last state: \(job.lastState.rawValue)")
            if let lastRunAt = job.lastRunAt {
                lines.append("  Last run: \(formatter.string(from: lastRunAt))")
            }
        }

        let recentRecords = runRecords
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(50)
        lines.append("")
        lines.append("Recent Runs (\(recentRecords.count) of \(runRecords.count))")
        if recentRecords.isEmpty {
            lines.append("- No runs recorded")
        }
        for record in recentRecords {
            lines.append("- \(formatter.string(from: record.startedAt)) — \(redact(record.jobName))")
            lines.append("  Outcome: \(record.state.rawValue)\(record.dryRun ? " (preview)" : "")")
            lines.append("  Duration: \(String(format: "%.1f", max(0, record.duration))) sec")
            if let trigger = record.trigger {
                lines.append("  Trigger: \(trigger.rawValue)")
            }
            lines.append("  Message: \(redact(record.message))")
            if let summary = record.transferSummary {
                lines.append("  Transfer: \(transferSummary(summary))")
            }
            if let verification = record.verification {
                lines.append("  Verification: \(verification.matches ? "passed" : "failed") — \(redact(verification.message))")
                if verification.hasDetailedResults {
                    lines.append("  Verification categories: content=\(verification.contentDifferences ?? 0), permissions=\(verification.permissionDifferences ?? 0), metadata=\(verification.metadataDifferences ?? 0), destination-only=\(verification.destinationOnlyItems ?? 0), permission-check=\((verification.permissionVerificationEnabled ?? false) ? "required" : "advisory")")
                }
            }
            if let logTail = recentLogTails[record.id], !logTail.isEmpty {
                lines.append("  Sanitized log tail:")
                for logLine in sanitizedLogTail(logTail) {
                    lines.append("    \(logLine)")
                }
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    func data(generatedAt: Date = Date()) -> Data {
        Data(makeText(generatedAt: generatedAt).utf8)
    }

    func save(to url: URL, generatedAt: Date = Date()) throws {
        try data(generatedAt: generatedAt).write(to: url, options: .atomic)
    }

    private func endpointSummary(_ endpoint: SyncEndpoint) -> String {
        switch endpoint.kind {
        case .remote:
            let host = endpoint.host.isEmpty ? "<not configured>" : redact(endpoint.host)
            let path = endpoint.path.isEmpty ? "<not configured>" : redact(endpoint.path)
            return "\(endpoint.kind.rawValue), <redacted-user>@\(host):\(path), port \(endpoint.port)"
        case .local, .network:
            let path = endpoint.path.isEmpty ? "<not configured>" : redact(endpoint.path)
            return "\(endpoint.kind.rawValue), \(path)"
        }
    }

    private func transferSummary(_ summary: TransferSummary) -> String {
        var values: [String] = []
        if let filesChanged = summary.filesChanged { values.append("\(filesChanged) changed") }
        if let filesTransferred = summary.filesTransferred { values.append("\(filesTransferred) transferred") }
        if let filesDeleted = summary.filesDeleted { values.append("\(filesDeleted) deleted") }
        if let transferredBytes = summary.transferredBytes { values.append("\(transferredBytes) bytes transferred") }
        if let bytesPerSecond = summary.bytesPerSecond { values.append("\(Int(bytesPerSecond)) bytes/sec") }
        return values.isEmpty ? "No statistics recorded" : values.joined(separator: ", ")
    }

    private func sanitizedLogTail(_ value: String) -> [String] {
        let normalized = value.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).suffix(40)
        return lines.map { String(redact(String($0)).prefix(500)) }
    }

    private func redact(_ value: String) -> String {
        var result = value

        let home = NSHomeDirectory()
        if !home.isEmpty {
            result = result.replacingOccurrences(of: home, with: "~", options: [.caseInsensitive])
        }

        // Redact any macOS user directory, including paths from another machine.
        result = replacingMatches(
            in: result,
            pattern: #"/Users/[^/\s:]+"#,
            template: "/Users/<redacted>"
        )
        result = replacingMatches(
            in: result,
            pattern: #"/home/[^/\s:]+"#,
            template: "/home/<redacted>"
        )
        for username in jobs.flatMap({ [$0.source.username, $0.destination.username] }) where !username.isEmpty {
            result = result.replacingOccurrences(
                of: username,
                with: "<redacted-user>",
                options: [.caseInsensitive]
            )
        }
        // Remote account names commonly appear in rsync/SSH output as user@host.
        result = replacingMatches(
            in: result,
            pattern: #"(?i)\b[A-Z0-9._%+\-]+@([A-Z0-9.\-]+)"#,
            template: "<redacted-user>@$1"
        )
        // Remove secret-like values from supplied settings, messages, and log tails.
        result = replacingMatches(
            in: result,
            pattern: #"(?i)\b(password|passphrase|token|secret|private[_ -]?key)\s*[:=]\s*[^\s,;]+"#,
            template: "$1=<redacted>"
        )
        result = replacingMatches(
            in: result,
            pattern: #"(?i)(identityfile|identity-file|\-i)\s+[^\s]+"#,
            template: "$1 <redacted>"
        )
        result = replacingMatches(
            in: result,
            pattern: #"(?i)\bauthorization\s*:\s*(bearer|basic)\s+[^\s]+"#,
            template: "Authorization: $1 <redacted>"
        )

        return result
    }

    private func isSensitiveSetting(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return ["password", "passphrase", "token", "secret", "private key", "identity file"]
            .contains { normalized.contains($0) }
    }

    private func replacingMatches(in value: String, pattern: String, template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

@MainActor
extension JobStore {
    /// Presents a save panel and writes a bounded, redacted support report.
    /// Only log files inside Project Sync's own Logs directory are considered.
    func exportDiagnosticReport() {
        let panel = NSSavePanel()
        panel.title = "Export Diagnostic Report"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Project-Sync-Diagnostic-\(Self.diagnosticFileDate).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let notifications = SystemNotificationManager.shared
        let settings = [
            "History limit": "\(historyLimit)",
            "Maximum simultaneous jobs": "\(maximumConcurrentRuns)",
            "Retry limit": "\(retryLimit)",
            "Retry base delay": "\(retryBaseDelaySeconds) seconds",
            "Stale reminder": staleReminderDays == 0 ? "Off" : "\(staleReminderDays) days",
            "Notify on start": notifications.notifyOnStart ? "On" : "Off",
            "Notify on success": notifications.notifyOnSuccess ? "On" : "Off",
            "Notify on failure": notifications.notifyOnFailure ? "On" : "Off",
            "Notify on retry/waiting": notifications.notifyOnRetryOrWaiting ? "On" : "Off",
            "Notify on stale backup": notifications.notifyOnStaleBackup ? "On" : "Off"
        ]
        let builder = DiagnosticReportBuilder(
            jobs: jobs,
            runRecords: history,
            appVersion: Self.diagnosticAppVersion,
            settingsSummary: settings,
            recentLogTails: Self.diagnosticLogTails(
                from: Array(history.prefix(10)),
                applicationSupportURL: applicationSupportURL
            )
        )

        do {
            try builder.save(to: url)
        } catch {
            bannerMessage = "Could not export the diagnostic report: \(error.localizedDescription)"
        }
    }

    private static var diagnosticAppVersion: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    private static var diagnosticFileDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func diagnosticLogTails(
        from records: [RunRecord],
        applicationSupportURL: URL
    ) -> [UUID: String] {
        let logsDirectory = applicationSupportURL
            .appendingPathComponent("Logs", isDirectory: true)
            .standardizedFileURL
        var result: [UUID: String] = [:]

        for record in records where !record.logPath.isEmpty {
            let url = URL(fileURLWithPath: record.logPath).standardizedFileURL
            guard url.path.hasPrefix(logsDirectory.path + "/"),
                  let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }

            do {
                let length = try handle.seekToEnd()
                let limit: UInt64 = 32 * 1_024
                try handle.seek(toOffset: length > limit ? length - limit : 0)
                let data = try handle.read(upToCount: Int(limit)) ?? Data()
                if let text = String(data: data, encoding: .utf8) {
                    result[record.id] = text
                }
            } catch {
                continue
            }
        }
        return result
    }
}
