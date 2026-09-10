import Foundation

enum TemporalSampleGroupValidator {
    private struct Box {
        let type: String
        let offset: Int
        let size: Int
        let headerSize: Int

        var end: Int { offset + size }
        var payloadStart: Int { offset + headerSize }
    }

    private static let requiredGroups: [(box: String, groupingType: String)] = [
        ("sgpd", "tscl"),
        ("sgpd", "tsas"),
        ("csgm", "tscl"),
        ("csgm", "tsas")
    ]

    static func validate(at url: URL) throws -> String {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw AppError("无法读取视频，无法验证 temporal sample groups：\(url.path)")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw AppError("无法读取视频，无法验证 temporal sample groups：\(error.localizedDescription)")
        }
        guard !data.isEmpty else {
            throw AppError("视频文件为空，无法验证 temporal sample groups。")
        }

        let topLevel = try boxes(in: data, from: 0, to: data.count)
        let stbls = try findPaths(
            in: data,
            candidates: topLevel,
            components: ["moov", "trak", "mdia", "minf", "stbl"]
        )
        guard !stbls.isEmpty else {
            throw AppError("视频缺少 moov/trak/mdia/minf/stbl 结构，无法验证 temporal sample groups。")
        }

        var trackFailures: [String] = []
        for (index, stbl) in stbls.enumerated() {
            do {
                let missing = try missingGroups(in: data, stbl: stbl)
                if missing.isEmpty {
                    return requiredGroups.map { "[\($0.box)] grouping_type='\($0.groupingType)'" }
                        .joined(separator: "\n")
                }
                trackFailures.append("轨道 \(index + 1) 缺少：\n" + missing.joined(separator: "\n"))
            } catch {
                trackFailures.append("轨道 \(index + 1)：\(error.localizedDescription)")
            }
        }

        throw AppError(
            "视频未通过 Aerial temporal sample group 验证，所有轨道均不完整：\n" +
            trackFailures.joined(separator: "\n")
        )
    }

    private static func missingGroups(in data: Data, stbl: Box) throws -> [String] {
        let children = try boxes(in: data, from: stbl.payloadStart, to: stbl.end)
        var found = Set<String>()
        for child in children where child.type == "sgpd" || child.type == "csgm" {
            let groupingTypeStart = child.payloadStart + 4
            guard groupingTypeStart + 4 <= child.end else {
                throw AppError("视频中的 \(child.type) box 缺少 grouping_type。")
            }
            let groupingType = String(
                bytes: data[groupingTypeStart..<(groupingTypeStart + 4)],
                encoding: .ascii
            ) ?? ""
            if requiredGroups.contains(where: {
                $0.box == child.type && $0.groupingType == groupingType
            }) {
                found.insert("[\(child.type)] grouping_type='\(groupingType)'")
            }
        }

        let missing = requiredGroups.compactMap { item -> String? in
            let value = "[\(item.box)] grouping_type='\(item.groupingType)'"
            return found.contains(value) ? nil : value
        }
        return missing
    }

    private static func findPaths(
        in data: Data,
        candidates: [Box],
        components: [String]
    ) throws -> [Box] {
        guard let component = components.first else { return [] }
        var matches: [Box] = []
        for box in candidates where box.type == component {
            if components.count == 1 {
                matches.append(box)
                continue
            }
            let children = try boxes(in: data, from: box.payloadStart, to: box.end)
            matches.append(contentsOf: try findPaths(
                in: data,
                candidates: children,
                components: Array(components.dropFirst())
            ))
        }
        return matches
    }

    private static func boxes(in data: Data, from start: Int, to end: Int) throws -> [Box] {
        guard start >= 0, start <= end, end <= data.count else {
            throw AppError("视频 box 范围无效，无法验证 temporal sample groups。")
        }
        var cursor = start
        var result: [Box] = []
        while cursor < end {
            guard end - cursor >= 8 else {
                throw AppError("视频包含不完整的 box header，无法验证 temporal sample groups。")
            }
            guard let size32 = readUInt32(data, at: cursor) else {
                throw AppError("视频 box size 无法读取，无法验证 temporal sample groups。")
            }
            let type = String(
                bytes: data[(cursor + 4)..<(cursor + 8)],
                encoding: .ascii
            ) ?? ""
            let headerSize: Int
            let boxSize: UInt64
            switch size32 {
            case 0:
                headerSize = 8
                boxSize = UInt64(end - cursor)
            case 1:
                guard end - cursor >= 16,
                      let extended = readUInt64(data, at: cursor + 8) else {
                    throw AppError("视频 extended box size 不完整，无法验证 temporal sample groups。")
                }
                headerSize = 16
                boxSize = extended
            default:
                headerSize = 8
                boxSize = UInt64(size32)
            }
            guard boxSize >= UInt64(headerSize),
                  boxSize <= UInt64(end - cursor),
                  boxSize <= UInt64(Int.max) else {
                throw AppError("视频 box size 损坏或越界，无法验证 temporal sample groups。")
            }
            let size = Int(boxSize)
            result.append(Box(type: type, offset: cursor, size: size, headerSize: headerSize))
            cursor += size
        }
        return result
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(data[offset + index])
        }
        return value
    }
}
