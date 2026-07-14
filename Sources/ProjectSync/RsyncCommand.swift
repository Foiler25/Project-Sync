import Foundation

struct RsyncCommand: Equatable {
    let executable: String
    let arguments: [String]

    var preview: String {
        ([executable] + arguments).map(Self.shellQuoted).joined(separator: " ")
    }

    static func build(for job: SyncJob, dryRun: Bool = false) throws -> RsyncCommand {
        try validate(job.source, role: "source")
        try validate(job.destination, role: "destination")

        guard !(job.source.kind == .remote && job.destination.kind == .remote) else {
            throw SyncError.invalidConfiguration("Remote-to-remote jobs are not supported. Use a local or mounted NAS endpoint on one side.")
        }
        guard job.source != job.destination else {
            throw SyncError.invalidConfiguration("Source and destination must be different.")
        }
        guard !localPathsOverlap(job) else {
            throw SyncError.invalidConfiguration("Source and destination folders cannot contain one another.")
        }

        var arguments = ["-a", "-v", "--human-readable", "--itemize-changes", "--partial"]
        if job.preserveExtendedAttributes { arguments.append("-E") }
        if job.mode == .mirror { arguments.append("--delete") }
        if dryRun { arguments.append("--dry-run") }

        for exclusion in job.exclusions.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }) {
            arguments += ["--exclude", exclusion]
        }

        if job.source.kind == .remote || job.destination.kind == .remote {
            let remote = job.source.kind == .remote ? job.source : job.destination
            arguments += ["-e", "ssh -p \(remote.port) -o BatchMode=yes -o ConnectTimeout=15"]
        }

        arguments.append(endpointArgument(job.source, isSource: true))
        arguments.append(endpointArgument(job.destination, isSource: false))
        return RsyncCommand(executable: "/usr/bin/rsync", arguments: arguments)
    }

    static func localPathsOverlap(_ job: SyncJob) -> Bool {
        guard job.source.kind != .remote, job.destination.kind != .remote else { return false }
        let source = URL(fileURLWithPath: job.source.path).standardizedFileURL.path
        let destination = URL(fileURLWithPath: job.destination.path).standardizedFileURL.path
        return source == destination ||
            destination.hasPrefix(source.withTrailingSlash) ||
            source.hasPrefix(destination.withTrailingSlash)
    }

    private static func validate(_ endpoint: SyncEndpoint, role: String) throws {
        guard !endpoint.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SyncError.invalidConfiguration("Choose a \(role) folder.")
        }
        if endpoint.kind == .remote {
            guard !endpoint.host.isEmpty else {
                throw SyncError.invalidConfiguration("Enter the remote \(role) host.")
            }
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
            guard endpoint.host.unicodeScalars.allSatisfy(allowed.contains) else {
                throw SyncError.invalidConfiguration("The remote host contains unsupported characters.")
            }
            guard (1...65535).contains(endpoint.port) else {
                throw SyncError.invalidConfiguration("The SSH port must be between 1 and 65535.")
            }
        } else if role == "source" {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: endpoint.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw SyncError.invalidConfiguration("The source folder is unavailable. If it is on a NAS, connect the network drive first.")
            }
        }
        if endpoint.kind == .network {
            let components = URL(fileURLWithPath: endpoint.path).standardized.pathComponents
            if components.count >= 3, components[1] == "Volumes" {
                let mountPath = "/Volumes/\(components[2])"
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: mountPath, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw SyncError.invalidConfiguration("The network drive \(components[2]) is not mounted. Connect it in Finder and try again.")
                }
            }
        }
    }

    private static func endpointArgument(_ endpoint: SyncEndpoint, isSource: Bool) -> String {
        var path = endpoint.path
        if isSource && !path.hasSuffix("/") { path += "/" }
        if !isSource && !path.hasSuffix("/") { path += "/" }

        guard endpoint.kind == .remote else { return path }
        let account = endpoint.username.isEmpty ? endpoint.host : "\(endpoint.username)@\(endpoint.host)"
        return "\(account):\(quoteRemotePath(path))"
    }

    private static func quoteRemotePath(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:@%+=,-")
        if value.unicodeScalars.allSatisfy(safe.contains) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension String {
    var withTrailingSlash: String { hasSuffix("/") ? self : self + "/" }
}
