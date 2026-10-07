#if os(macOS)
import DaybookCore
import Foundation

/// Gathers coding work on the Mac: commits (yours only) from every repo in
/// ~/Documents/GitHub, and pull requests, issues, reviews and comments from
/// GitHub through the `gh` command line, which is already signed in. Reads
/// commit times, messages and repo names; never code. Nothing leaves the Mac.
enum WorkCollector {
    static let reposFolder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/GitHub")

    /// Takes a few seconds (a `git log` per repo, a few GitHub requests), so run it
    /// off the main thread.
    static func gather(days: Int = 90) async -> Work.Snapshot {
        await Task.detached(priority: .utility) { collect(days: days) }.value
    }

    nonisolated static func collect(days: Int) -> Work.Snapshot {
        var problems: [String] = []
        let commits = localCommits(days: days, problems: &problems)
        let activities = gitHubActivities(problems: &problems)
        return Work.Snapshot(gathered: .now, commits: commits, activities: activities, problems: problems)
    }

    // MARK: Local repos

    nonisolated static func localCommits(days: Int, problems: inout [String]) -> [Work.Commit] {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: reposFolder, includingPropertiesForKeys: nil) else {
            problems.append("Couldn\u{2019}t read \(reposFolder.path)")
            return []
        }
        let me = identity()
        var seen: Set<String> = []
        var commits: [Work.Commit] = []
        for folder in folders where FileManager.default.fileExists(atPath: folder.appending(path: ".git").path) {
            // Each commit starts with %x1e (ASCII 30), its fields split by %x1f (ASCII 31):
            // characters that never show up in commit messages. --shortstat adds
            // the files/insertions/deletions line (see Work.parseGitLog).
            let result = run(git, ["-C", folder.path, "log", "--all", "--no-merges", "--since=\(days).days", "--shortstat",
                                   "--pretty=format:%x1e%H%x1f%at%x1f%an%x1f%ae%x1f%s"])
            guard result.status == 0 else { continue } // an empty repo or a broken one: skip it
            for commit in Work.parseGitLog(result.output, repo: folder.lastPathComponent, isMine: me.matches)
            where seen.insert(commit.hash).inserted {
                commits.append(commit)
            }
        }
        return commits.sorted { $0.date < $1.date }
    }

    /// Who "you" are in commits: your git name, and the addresses you commit with
    /// (GitHub's private one, and the one set in git).
    struct Identity {
        let name: String
        let emails: Set<String>
        func matches(name: String, email: String) -> Bool {
            let email = email.lowercased()
            return emails.contains(email) || email.contains("masonkimball05") || (!self.name.isEmpty && name == self.name)
        }
    }

    nonisolated static func identity() -> Identity {
        let name = run(git, ["config", "--global", "user.name"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = run(git, ["config", "--global", "user.email"]).output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Identity(name: name, emails: Set([email, "mason.kimball05@gmail.com"].filter { !$0.isEmpty }))
    }

    // MARK: GitHub

    nonisolated static func gitHubActivities(problems: inout [String]) -> [Work.Activity] {
        guard let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: FileManager.default.isExecutableFile) else {
            problems.append("The gh command isn\u{2019}t installed, so GitHub pull requests and issues aren\u{2019}t included.")
            return []
        }
        let login = run(gh, ["api", "user", "--jq", ".login"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty else {
            problems.append("gh isn\u{2019}t signed in (run: gh auth login), so GitHub pull requests and issues aren\u{2019}t included.")
            return []
        }
        // --paginate fetches every page (GitHub keeps 90 days, up to 300 events);
        // --jq '.[]' prints one event per line, which joins back into one JSON array.
        let result = run(gh, ["api", "/users/\(login)/events?per_page=100", "--paginate", "--jq", ".[]"])
        guard result.status == 0 else {
            problems.append("GitHub didn\u{2019}t answer: \(result.error.prefix(200))")
            return []
        }
        let lines = result.output.split(separator: "\n").filter { !$0.isEmpty }
        return Work.activities(fromEvents: Data(("[" + lines.joined(separator: ",") + "]").utf8))
    }

    // MARK: Running commands

    static let git = "/usr/bin/git"

    struct Output {
        let status: Int32
        let output: String
        let error: String
    }

    /// Runs a command and waits. `GIT_OPTIONAL_LOCKS=0` stops git from writing lock
    /// files just to read, so this never gets in the way of git running elsewhere.
    nonisolated static func run(_ program: String, _ arguments: [String]) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return Output(status: -1, output: "", error: error.localizedDescription)
        }
        // Read before waiting: a full pipe would otherwise block the command forever.
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self),
                      error: String(decoding: errors, as: UTF8.self))
    }
}
#endif
