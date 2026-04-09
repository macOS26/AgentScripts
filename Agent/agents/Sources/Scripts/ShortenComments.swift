import Foundation

func findSwiftFiles(in dir: String) -> [String] {
    let fm = FileManager.default
    var result: [String] = []
    guard let enumerator = fm.enumerator(atPath: dir) else { return result }
    while let file = enumerator.nextObject() as? String {
        if file.hasSuffix(".swift") {
            result.append((dir as NSString).appendingPathComponent(file))
        }
    }
    return result.sorted()
}

func shortenCommentBlock(_ lines: [String]) -> [String] {
    let combined = lines.compactMap { line -> String? in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("//") else { return nil }
        let body = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return body
    }.joined(separator: " ")

    let firstTrimmed = lines[0].trimmingCharacters(in: .whitespaces)
    let isDoc = firstTrimmed.hasPrefix("///")
    let indent = String(lines[0].prefix(while: { $0 == " " || $0 == "\t" }))
    let prefix = isDoc ? "/// " : "// "

    let maxLineLen = 120
    let oneLiner = indent + prefix + combined
    if oneLiner.count <= maxLineLen {
        return [oneLiner]
    }

    let words = combined.split(separator: " ", omittingEmptySubsequences: true)
    var line1Words: [Substring] = []
    var currentLen = indent.count + prefix.count
    for word in words {
        let candidateLen = currentLen + (line1Words.isEmpty ? 0 : 1) + word.count
        if candidateLen <= maxLineLen {
            line1Words.append(word)
            currentLen = candidateLen
        } else { break }
    }
    let line2Words = words.dropFirst(line1Words.count)
    let line1 = indent + prefix + line1Words.joined(separator: " ")
    let line2 = indent + prefix + line2Words.joined(separator: " ")
    return line2Words.isEmpty ? [line1] : [line1, line2]
}

func processFile(_ path: String) -> (edited: Bool, blocks: Int) {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return (false, 0) }
    let originalLines = content.components(separatedBy: "\n")
    var result: [String] = []
    var commentBlock: [String] = []
    var blocksShortened = 0

    func flushBlock() {
        if commentBlock.count >= 3 {
            result.append(contentsOf: shortenCommentBlock(commentBlock))
            blocksShortened += 1
        } else {
            result.append(contentsOf: commentBlock)
        }
        commentBlock = []
    }

    for line in originalLines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") {
            commentBlock.append(line)
        } else {
            flushBlock()
            result.append(line)
        }
    }
    flushBlock()

    if blocksShortened > 0 {
        let newContent = result.joined(separator: "\n")
        do {
            try newContent.write(toFile: path, atomically: true, encoding: .utf8)
            print("  ✅ \(path): \(blocksShortened) blocks")
        } catch {
            print("  ❌ \(path): \(error)")
        }
    }
    return (blocksShortened > 0, blocksShortened)
}

@_cdecl("script_main")
public func scriptMain() -> Int32 {
    let folder = ProcessInfo.processInfo.environment["AGENT_PROJECT_FOLDER"] ?? FileManager.default.currentDirectoryPath
    let agentDir = (folder as NSString).appendingPathComponent("Agent")
    print("Scanning: \(agentDir)")
    let files = findSwiftFiles(in: agentDir)
    print("Found \(files.count) Swift files")

    var totalEdited = 0
    var totalBlocks = 0
    for file in files {
        let (edited, count) = processFile(file)
        if edited { totalEdited += 1; totalBlocks += count }
    }
    print("Edited \(totalEdited) files, shortened \(totalBlocks) comment blocks")
    return 0
}
