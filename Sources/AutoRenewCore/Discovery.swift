import Foundation

public enum RegexHelp {
    /// Returns all capture groups of the first match (index 0 = whole match).
    public static func firstMatches(_ string: String, _ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = string as NSString
        guard let match = regex.firstMatch(in: string, options: [], range: NSRange(location: 0, length: ns.length)) else { return [] }
        var groups: [String] = []
        for i in 0..<match.numberOfRanges {
            let range = match.range(at: i)
            groups.append(range.location == NSNotFound ? "" : ns.substring(with: range))
        }
        return groups
    }

    /// Line-anchored matching; returns capture groups per match.
    public static func allMatches(_ string: String, _ pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        let ns = string as NSString
        let matches = regex.matches(in: string, options: [], range: NSRange(location: 0, length: ns.length))
        return matches.map { match in
            (0..<match.numberOfRanges).map { i -> String in
                let range = match.range(at: i)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
        }
    }
}

public struct SigningIdentity: Equatable {
    public let hash: String
    public let displayName: String
    public let teamID: String?

    public init(hash: String, displayName: String, teamID: String?) {
        self.hash = hash
        self.displayName = displayName
        self.teamID = teamID
    }
}

public enum Discovery {
    public static func parseSchemes(fromListJSON json: String) -> [String] {
        guard let data = json.data(using: .utf8) else { return [] }
        struct ListJSON: Decodable {
            struct Project: Decodable { let schemes: [String] }
            let project: Project
        }
        guard let decoded = try? JSONDecoder().decode(ListJSON.self, from: data) else { return [] }
        return decoded.project.schemes
    }

    public static func parseBuildSettings(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            guard let range = line.range(of: " = ") else { continue }
            let key = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            var value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    public static func parseIdentities(_ text: String) -> [SigningIdentity] {
        var result: [SigningIdentity] = []
        for groups in RegexHelp.allMatches(text, "^\\s*\\d+\\)\\s+([0-9A-F]{40})\\s+\"(.+)\"\\s*$") {
            guard groups.count >= 3 else { continue }
            let displayName = groups[2]
            let teamGroups = RegexHelp.firstMatches(displayName, "\\(([A-Z0-9]{10})\\)$")
            let teamID = teamGroups.count >= 2 ? teamGroups[1] : nil
            result.append(SigningIdentity(hash: groups[1], displayName: displayName, teamID: teamID))
        }
        return result
    }

    public static func defaultScheme(projectName: String, schemes: [String]) -> String {
        schemes.first { $0.caseInsensitiveCompare(projectName) == .orderedSame } ?? schemes.first ?? ""
    }
}

/// Finds the .xcodeproj / .xcworkspace for a user-chosen path.
public enum ProjectLocator {
    public static func resolveProject(fromPath path: String) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {
            return (path.hasSuffix(".xcodeproj") || path.hasSuffix(".xcworkspace")) ? path : nil
        }
        if path.hasSuffix(".xcodeproj") || path.hasSuffix(".xcworkspace") { return path }

        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return nil }
        var workspace: String?
        var project: String?
        for case let sub as String in enumerator {
            if sub.contains(".xcodeproj/") { continue } // skip internals like project.xcworkspace
            if workspace == nil && sub.hasSuffix(".xcworkspace") { workspace = path + "/" + sub }
            if project == nil && sub.hasSuffix(".xcodeproj") { project = path + "/" + sub }
            if workspace != nil { break }
        }
        return workspace ?? project
    }
}

public struct ToolError: Error {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public struct XcodeTools {
    public let runner: ProcessRunning

    public init(runner: ProcessRunning = RealProcessRunner()) {
        self.runner = runner
    }

    public func listSchemes(projectPath: String) -> Result<[String], ToolError> {
        let flag = projectPath.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
        let result = runner.run(executable: "/usr/bin/xcrun",
                                arguments: ["xcodebuild", flag, projectPath, "-list", "-json"],
                                timeout: 180)
        guard result.exitCode == 0 else { return .failure(ToolError(message: "xcodebuild -list failed: \(Self.tail(result))")) }
        let schemes = Discovery.parseSchemes(fromListJSON: result.stdout)
        if schemes.isEmpty { return .failure(ToolError(message: "xcodebuild -list returned no schemes")) }
        return .success(schemes)
    }

    public func buildSettings(projectPath: String, scheme: String, configuration: String) -> Result<[String: String], ToolError> {
        let flag = projectPath.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
        let result = runner.run(executable: "/usr/bin/xcrun",
                                arguments: ["xcodebuild", flag, projectPath, "-scheme", scheme,
                                            "-configuration", configuration,
                                            "-destination", "generic/platform=iOS",
                                            "-showBuildSettings"],
                                timeout: 300)
        guard result.exitCode == 0 else { return .failure(ToolError(message: "xcodebuild -showBuildSettings failed: \(Self.tail(result))")) }
        return .success(Discovery.parseBuildSettings(result.stdout))
    }

    public func signingIdentities() -> [SigningIdentity] {
        let result = runner.run(executable: "/usr/bin/security",
                                arguments: ["find-identity", "-v", "-p", "codesigning"],
                                timeout: 30)
        return Discovery.parseIdentities(result.stdout).filter { $0.displayName.contains("Apple Development") }
    }

    static func tail(_ result: ProcessResult, maxChars: Int = 400) -> String {
        let combined = result.stderr.isEmpty ? result.stdout : result.stderr
        let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "exit \(result.exitCode)" : String(trimmed.suffix(maxChars))
    }
}
