import CryptoKit
import Foundation

enum EncoderService {
    static let repositoryURL = "https://github.com/AlexisBCD/macos-custom-video-wallpaper-fix.git"

    static func prepare() async throws -> URL {
        if let bundledRepository = AppPaths.bundledEncoderRepository {
            return try await prepareBundled(repository: bundledRepository)
        }
        return try await prepareFromNetwork()
    }

    private static func prepareBundled(repository: URL) async throws -> URL {
        let fileManager = FileManager.default
        try AppPaths.ensureDirectory(AppPaths.bundledEncoderCache)
        for filename in ["encode_temporal.swift", "groups.py", "build.sh", "LICENSE"] {
            let source = repository.appendingPathComponent(filename)
            let destination = AppPaths.bundledEncoderCache.appendingPathComponent(filename)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.copyItem(at: source, to: destination)
            }
        }

        let executable = AppPaths.bundledEncoderCache.appendingPathComponent("encode_temporal")
        if !fileManager.isExecutableFile(atPath: executable.path) {
            let buildScript = AppPaths.bundledEncoderCache.appendingPathComponent("build.sh")
            guard fileManager.fileExists(atPath: buildScript.path) else {
                throw AppError("应用内置编码器缺少 build.sh，无法继续。")
            }
            let result = try await CommandRunner.run(
                URL(fileURLWithPath: "/bin/bash"),
                arguments: [buildScript.path],
                currentDirectory: AppPaths.bundledEncoderCache
            )
            guard result.status == 0 else {
                throw AppError("内置编码器编译失败：\n\(result.output)")
            }
        }
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw AppError("内置编码器编译完成后没有生成 encode_temporal。")
        }
        return executable
    }

    private static func prepareFromNetwork() async throws -> URL {
        let fileManager = FileManager.default
        try AppPaths.ensureDirectory(AppPaths.encoderRepository.deletingLastPathComponent())

        if !fileManager.fileExists(atPath: AppPaths.encoderRepository.path) {
            guard let git = CommandRunner.executable(named: "git") else {
                throw AppError("未找到 Git，无法准备编码器。")
            }
            let result = try await CommandRunner.run(
                git,
                arguments: ["clone", repositoryURL, AppPaths.encoderRepository.path]
            )
            guard result.status == 0 else {
                throw AppError("应用内置编码器不可用，且在线备用下载失败：\n\(result.output)")
            }
        }

        let executable = AppPaths.encoderRepository.appendingPathComponent("encode_temporal")
        if !fileManager.isExecutableFile(atPath: executable.path) {
            let buildScript = AppPaths.encoderRepository.appendingPathComponent("build.sh")
            guard fileManager.fileExists(atPath: buildScript.path) else {
                throw AppError("编码器目录缺少 build.sh，未自动删除现有目录。")
            }
            let bash = URL(fileURLWithPath: "/bin/bash")
            let result = try await CommandRunner.run(bash, arguments: [buildScript.path], currentDirectory: AppPaths.encoderRepository)
            guard result.status == 0 else {
                throw AppError("编码器编译失败：\n\(result.output)")
            }
        }

        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw AppError("编码器编译完成后没有生成 encode_temporal。")
        }
        return executable
    }

    static func encode(input: URL, output: URL, loopCount: Int, bitrateMbps: Int, executable: URL) async throws {
        try AppPaths.ensureDirectory(output.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: output)
        let result = try await CommandRunner.run(
            executable,
            arguments: [input.path, output.path, String(loopCount), String(bitrateMbps)],
            currentDirectory: executable.deletingLastPathComponent()
        )
        guard result.status == 0 else {
            throw AppError("视频编码失败：\n\(result.output)")
        }
        guard FileManager.default.isReadableFile(atPath: output.path),
              (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw AppError("编码器没有生成有效输出文件。")
        }
    }

    static func validate(output: URL, repository: URL) async throws -> String {
        guard let python = CommandRunner.executable(named: "python3") else {
            throw AppError("未找到 Python 3，无法验证 temporal sample groups。")
        }
        let groups = repository.appendingPathComponent("groups.py")
        guard FileManager.default.fileExists(atPath: groups.path) else {
            throw AppError("编码器仓库缺少 groups.py，无法进行安全验证。")
        }
        let result = try await CommandRunner.run(python, arguments: [groups.path, output.path])
        guard result.status == 0 else {
            throw AppError("sample group 验证程序失败：\n\(result.output)")
        }

        let required = [
            "[sgpd] grouping_type='tscl'",
            "[sgpd] grouping_type='tsas'",
            "[csgm] grouping_type='tscl'",
            "[csgm] grouping_type='tsas'"
        ]
        let missing = required.filter { !result.output.contains($0) }
        guard missing.isEmpty else {
            throw AppError("视频未通过 Aerial 兼容性验证，缺少：\n\(missing.joined(separator: "\n"))\n\n原始验证输出：\n\(result.output)")
        }
        return result.output
    }
}

enum AerialService {
    private static let uuidPattern = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#

    static func normalizeUUID(_ value: String) -> String? {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".mov", with: "", options: [.caseInsensitive, .anchored])
        guard candidate.range(of: uuidPattern, options: .regularExpression) != nil else { return nil }
        return candidate.uppercased()
    }

    static func uuidFromFilename(_ url: URL) -> String? {
        normalizeUUID(url.deletingPathExtension().lastPathComponent)
    }

    static func targets() -> [AerialTarget] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.aerialDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "mov",
                  let uuid = uuidFromFilename(url),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return AerialTarget(uuid: uuid, url: url)
        }.sorted { $0.uuid < $1.uuid }
    }

    static func targetURL(uuid: String) throws -> URL {
        guard let normalized = normalizeUUID(uuid) else {
            throw AppError("UUID 格式不正确。")
        }
        return AppPaths.aerialDirectory.appendingPathComponent("\(normalized).mov")
    }

    static func createBackup(of target: URL, uuid: String, suffix: String? = nil) throws -> URL {
        try AppPaths.ensureDirectory(AppPaths.backupsDirectory)
        let timestamp = DateFormatter.fileTimestamp.string(from: Date())
        let middle = suffix.map { "-\($0)" } ?? ""
        let destination = uniqueURL(
            directory: AppPaths.backupsDirectory,
            filename: "\(uuid)\(middle)-\(timestamp).mov"
        )
        try FileManager.default.copyItem(at: target, to: destination)
        try verifyNonEmpty(destination)
        return destination
    }

    static func archiveOriginalOnDesktop(of target: URL, customName: String? = nil) throws -> URL {
        try AppPaths.ensureDirectory(AppPaths.desktopArchiveDirectory)
        let number = nextArchiveNumber()
        let filename = try archiveFilename(for: target, customName: customName)
        let destination = AppPaths.desktopArchiveDirectory.appendingPathComponent(
            "\(number)-\(filename)"
        )
        try FileManager.default.copyItem(at: target, to: destination)
        try verifyNonEmpty(destination)
        return destination
    }

    private static func archiveFilename(for target: URL, customName: String?) throws -> String {
        guard let customName else { return target.lastPathComponent }
        let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\\") else {
            throw AppError("自定义归档名称无效，不能包含路径分隔符。")
        }

        var stem = trimmed
        if stem.lowercased().hasSuffix(".mov") {
            stem.removeLast(4)
        }
        guard !stem.isEmpty, stem != ".", stem != ".." else {
            throw AppError("自定义归档名称无效。")
        }
        return "\(stem).mov"
    }

    static func backups(for uuid: String) -> [BackupEntry] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.backupsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "mov", url.lastPathComponent.hasPrefix(uuid) else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return BackupEntry(
                url: url,
                date: values?.contentModificationDate ?? .distantPast,
                size: Int64(values?.fileSize ?? 0)
            )
        }.sorted { $0.date > $1.date }
    }

    static func replaceAtomically(source: URL, target: URL) throws {
        let staging = target.deletingLastPathComponent().appendingPathComponent(
            ".wallpaper-converter-\(UUID().uuidString).mov"
        )
        defer { try? FileManager.default.removeItem(at: staging) }

        try FileManager.default.copyItem(at: source, to: staging)
        guard try sha256(source) == sha256(staging) else {
            throw AppError("安装前临时文件校验不一致，已停止替换。")
        }
        _ = try FileManager.default.replaceItemAt(
            target,
            withItemAt: staging,
            backupItemName: nil,
            options: [.usingNewMetadataOnly]
        )
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verifyNonEmpty(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
            throw AppError("文件备份失败或为空：\(url.path)")
        }
    }

    private static func uniqueURL(directory: URL, filename: String) -> URL {
        let base = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let stem = base.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let candidate = directory.appendingPathComponent("\(stem)-\(index).mov")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private static func nextArchiveNumber() -> Int {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.desktopArchiveDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let numbers = urls.compactMap { url -> Int? in
            let first = url.lastPathComponent.split(separator: "-", maxSplits: 1).first
            return first.flatMap { Int($0) }
        }
        return (numbers.max() ?? 0) + 1
    }
}
