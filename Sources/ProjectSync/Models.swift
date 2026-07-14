import Foundation

enum EndpointKind: String, Codable, CaseIterable, Identifiable {
    case local = "Mac"
    case network = "NAS / Network Drive"
    case remote = "Remote (SSH)"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .local: return "laptopcomputer"
        case .network: return "externaldrive.connected.to.line.below"
        case .remote: return "network"
        }
    }
}

struct SyncEndpoint: Codable, Equatable {
    var kind: EndpointKind = .local
    var path: String = ""
    var host: String = ""
    var username: String = ""
    var port: Int = 22

    var displayName: String {
        if kind == .remote {
            let account = username.isEmpty ? host : "\(username)@\(host)"
            return "\(account):\(path)"
        }
        return NSString(string: path).abbreviatingWithTildeInPath
    }
}

enum TransferMode: String, Codable, CaseIterable, Identifiable {
    case backup = "Backup"
    case mirror = "Mirror"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .backup: return "Copy new and changed files; never delete destination files."
        case .mirror: return "Make the destination match the source, including deletions."
        }
    }
}

enum ScheduleKind: String, Codable, CaseIterable, Identifiable {
    case manual = "Manual"
    case realtime = "Real-time"
    case hourly = "Hourly"
    case daily = "Daily"
    case weekly = "Weekly"

    var id: String { rawValue }
}

struct JobSchedule: Codable, Equatable {
    var kind: ScheduleKind = .manual
    var minute: Int = 0
    var hour: Int = 2
    var weekday: Int = 2 // Calendar: Sunday = 1, Monday = 2

    var summary: String {
        let calendar = Calendar.current
        let date = calendar.date(from: DateComponents(hour: hour, minute: minute)) ?? Date()
        let time = date.formatted(date: .omitted, time: .shortened)
        switch kind {
        case .manual: return "Manual only"
        case .realtime: return "When files change"
        case .hourly: return "Hourly at :\(String(format: "%02d", minute))"
        case .daily: return "Every day at \(time)"
        case .weekly:
            let names = calendar.weekdaySymbols
            let name = names[max(0, min(6, weekday - 1))]
            return "Every \(name) at \(time)"
        }
    }

    func nextDate(after date: Date, calendar: Calendar = .current) -> Date? {
        switch kind {
        case .manual, .realtime:
            return nil
        case .hourly:
            return calendar.nextDate(
                after: date,
                matching: DateComponents(minute: minute, second: 0),
                matchingPolicy: .nextTime
            )
        case .daily:
            return calendar.nextDate(
                after: date,
                matching: DateComponents(hour: hour, minute: minute, second: 0),
                matchingPolicy: .nextTime
            )
        case .weekly:
            return calendar.nextDate(
                after: date,
                matching: DateComponents(hour: hour, minute: minute, second: 0, weekday: weekday),
                matchingPolicy: .nextTime
            )
        }
    }
}

enum JobState: String, Codable {
    case idle
    case running
    case succeeded
    case failed
    case cancelled

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .running: return "Syncing"
        case .succeeded: return "Up to date"
        case .failed: return "Needs attention"
        case .cancelled: return "Cancelled"
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }
}

struct SyncJob: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "New Sync"
    var source = SyncEndpoint()
    var destination = SyncEndpoint(kind: .network)
    var mode: TransferMode = .backup
    var schedule = JobSchedule()
    var exclusions: [String] = [".DS_Store", ".Trash", ".Spotlight-V100"]
    var enabled = true
    var preserveExtendedAttributes = true
    var lastRunAt: Date?
    var lastState: JobState = .idle
    var lastMessage: String?
    var notes: String?
    var archiveReplacedFiles: Bool?
    var archiveRetentionCount: Int?
    var verifyAfterSync: Bool?
    var runWhenVolumeMounts: Bool?
    var realtimePausedUntil: Date?
    var lastVerificationAt: Date?
    var lastVerificationSucceeded: Bool?
}

extension SyncJob {
    var keepsVersionedArchive: Bool { archiveReplacedFiles ?? false }
    var archiveVersionLimit: Int { max(1, archiveRetentionCount ?? 5) }
    var verifiesAfterSync: Bool { verifyAfterSync ?? false }
    var runsWhenVolumeMounts: Bool { runWhenVolumeMounts ?? false }

    func realtimeIsPaused(at date: Date = Date()) -> Bool {
        guard let realtimePausedUntil else { return false }
        return realtimePausedUntil > date
    }
}

struct TransferSummary: Codable, Equatable {
    var filesChanged: Int?
    var filesTransferred: Int?
    var filesDeleted: Int?
    var totalBytes: Int64?
    var transferredBytes: Int64?
    var bytesPerSecond: Double?
}

struct VerificationReport: Codable, Equatable {
    let verifiedAt: Date
    let matches: Bool
    let message: String
}

enum RunTrigger: String, Codable, CaseIterable {
    case manual
    case preview
    case schedule
    case realtime
    case volumeMount
    case retry
    case verification
}

struct RunRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    let jobID: UUID
    let jobName: String
    let startedAt: Date
    let endedAt: Date
    let state: JobState
    let dryRun: Bool
    let message: String
    let logPath: String
    var transferSummary: TransferSummary? = nil
    var verification: VerificationReport? = nil
    var trigger: RunTrigger? = nil

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

enum SyncError: LocalizedError {
    case invalidConfiguration(String)
    case processFailed(Int32, String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): message
        case .processFailed(let code, let message): "rsync exited with code \(code). \(message)"
        case .cancelled: "The sync was cancelled."
        }
    }
}
