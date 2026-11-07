import Foundation

/// Step progress of one session, rebuilt from the task-list tool calls in its transcript
/// (~/.claude/projects/<project>/<sessionId>.jsonl): the desktop app's update_plan / wrap_up
/// and the terminal's TodoWrite.
struct TaskProgress {
    var done: Int
    var total: Int
    var current: String?

    var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    var isFinished: Bool { total > 0 && done >= total }
}

final class ProgressTracker {
    private struct PlanItem { var content: String; var status: String }

    private struct Entry {
        var url: URL?
        var offset: UInt64 = 0
        var items: [PlanItem] = []
    }

    private var entries: [String: Entry] = [:]
    private let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")

    func progress(for sessionId: String) -> TaskProgress? {
        var e = entries[sessionId] ?? Entry()
        if e.url == nil { e.url = locate(sessionId) }
        guard let url = e.url else { entries[sessionId] = e; return nil }
        readNewLines(url, into: &e)
        entries[sessionId] = e
        guard !e.items.isEmpty else { return nil }
        let done = e.items.filter { $0.status == "completed" }.count
        let current = e.items.first(where: { $0.status == "in_progress" })?.content
            ?? e.items.first(where: { $0.status == "pending" })?.content
        return TaskProgress(done: done, total: e.items.count, current: done >= e.items.count ? nil : current)
    }

    /// Drops cached state for sessions that are gone.
    func prune(keeping ids: Set<String>) {
        entries = entries.filter { ids.contains($0.key) }
    }

    private func locate(_ sid: String) -> URL? {
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        for d in dirs {
            let f = d.appendingPathComponent("\(sid).jsonl")
            if FileManager.default.fileExists(atPath: f.path) { return f }
        }
        return nil
    }

    private func readNewLines(_ url: URL, into e: inout Entry) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < e.offset { e.offset = 0; e.items = [] }   // file was rewritten
        guard size > e.offset else { return }
        try? h.seek(toOffset: e.offset)
        guard let data = try? h.readToEnd(), !data.isEmpty else { return }
        // Only consume complete lines; a partial last line is read again next time.
        guard let lastNL = data.lastIndex(of: 0x0A) else { return }
        let chunk = data[data.startIndex...lastNL]
        e.offset += UInt64(chunk.count)

        let needles = ["update_plan", "TodoWrite", "wrap_up"].map { Data($0.utf8) }
        for line in chunk.split(separator: 0x0A) {
            guard line.range(of: Data("\"tool_use\"".utf8)) != nil,
                  needles.contains(where: { line.range(of: $0) != nil }),
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { continue }
            for c in content where c["type"] as? String == "tool_use" {
                apply(name: c["name"] as? String ?? "", input: c["input"] as? [String: Any] ?? [:], to: &e.items)
            }
        }
    }

    private func apply(name: String, input: [String: Any], to items: inout [PlanItem]) {
        if name == "TodoWrite", let todos = input["todos"] as? [[String: Any]] {
            items = todos.map { PlanItem(content: ($0["activeForm"] as? String) ?? ($0["content"] as? String) ?? "",
                                         status: $0["status"] as? String ?? "pending") }
            return
        }
        if name.hasSuffix("wrap_up") {
            for i in items.indices { items[i].status = "completed" }
            return
        }
        guard name.hasSuffix("update_plan") else { return }
        if let list = input["items"] as? [[String: Any]] {
            items = list.map { PlanItem(content: $0["content"] as? String ?? "", status: $0["status"] as? String ?? "pending") }
        }
        if input["advance"] as? Bool == true {
            if let i = items.firstIndex(where: { $0.status == "in_progress" }) { items[i].status = "completed" }
            if let j = items.firstIndex(where: { $0.status == "pending" }) { items[j].status = "in_progress" }
        }
        if let done = input["done"] as? [NSNumber] {
            for n in done { let i = n.intValue - 1; if items.indices.contains(i) { items[i].status = "completed" } }
        }
        if let start = (input["start"] as? NSNumber)?.intValue, items.indices.contains(start - 1) {
            for i in items.indices where items[i].status == "in_progress" { items[i].status = "pending" }
            items[start - 1].status = "in_progress"
        }
    }
}
