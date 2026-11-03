import Foundation

/// 记忆检索与整理。检索是纯本地的关键词/二元组打分，不额外调用模型；
/// 只有「整理记忆 / 生成摘要」会调用一次模型（可在设置里关闭）。
enum MemoryEngine {

    /// 太常见的单字不进检索，避免「的/了/我」把一切记忆都匹配上。
    static let stopCharacters: Set<Character> = Set("的了是在我你他她它不也就都很和与这那有个着过要会说等着呢吧啊吗把被让给对从到为以而且但或如所之其么什")

    static let stopBigrams: Set<String> = [
        "我们", "你们", "他们", "我的", "你的", "他的", "她的", "这个", "那个", "这些", "那些",
        "什么", "怎么", "可以", "没有", "一个", "然后", "因为", "所以", "如果", "但是", "不是",
        "还是", "一下", "这样", "时候", "现在", "今天", "明天", "昨天", "知道", "觉得", "感觉",
        "应该", "可能", "已经", "比较", "有点", "真的", "就是", "而且", "不过", "其实", "自己",
        "这里", "那里", "一次", "一点", "很多", "非常", "特别", "不太", "不要", "需要", "东西"
    ]

    // MARK: - 分词

    static func tokens(_ text: String) -> Set<String> {
        var result = Set<String>()
        var latin = ""
        var cjk: [Character] = []

        func flushLatin() {
            if latin.count >= 2 { result.insert(latin.lowercased()) }
            latin = ""
        }
        func flushCJK() {
            for character in cjk where !stopCharacters.contains(character) {
                result.insert(String(character))
            }
            if cjk.count >= 2 {
                for index in 0..<(cjk.count - 1) {
                    result.insert(String(cjk[index...index + 1]))
                }
            }
            cjk.removeAll(keepingCapacity: true)
        }

        for character in text {
            if character.isASCII && (character.isLetter || character.isNumber) {
                flushCJK()
                latin.append(character)
            } else if character.isCJK {
                flushLatin()
                cjk.append(character)
            } else {
                flushLatin()
                flushCJK()
            }
        }
        flushLatin()
        flushCJK()
        return result.subtracting(stopBigrams)
    }

    // MARK: - 检索

    static func score(query: Set<String>, memory: ChatStore.Memory, now: Date = Date()) -> Double {
        let memoryTokens = tokens(memory.content + " " + memory.keywords)
        let overlap = query.intersection(memoryTokens)
        guard !overlap.isEmpty else { return 0 }

        // 二元组比单字更可信。
        var value = overlap.reduce(0.0) { $0 + ($1.count >= 2 ? 2.0 : 0.7) }
        switch memory.kind {
        case "preference": value += 0.6
        case "relationship": value += 0.4
        case "plan": value += 0.3
        default: break
        }
        let days = max(0, now.timeIntervalSince(memory.updatedAt) / 86_400)
        value += max(0, 0.5 - days * 0.01)
        value -= Double(memory.hits) * 0.02
        return value
    }

    /// 按当前这句话去挑相关记忆；没有相关记忆就不注入，省 token。
    static func relevantMemories(from store: ChatStore, query: String, limit: Int) -> [ChatStore.Memory] {
        guard limit > 0 else { return [] }
        let queryTokens = tokens(query)
        guard !queryTokens.isEmpty else { return [] }
        let now = Date()
        let scored = store.memories().map { ($0, score(query: queryTokens, memory: $0, now: now)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        let picked = scored.prefix(limit).map { $0.0 }
        store.markMemoriesUsed(picked.map { $0.id })
        return picked
    }

    // MARK: - 注入

    /// 把当前时间告诉模型：否则问「今天周几」只能瞎猜。
    static func currentTimeLine(_ now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm EEEE"
        return "【当前时间】\(formatter.string(from: now))（\(TimeZone.current.identifier)）。涉及日期、星期、时间的问题以此为准，不要猜。"
    }

    static func systemPrompt(persona: Persona, memories: [ChatStore.Memory], summary: String?) -> String {
        var parts = [persona.systemPrompt, currentTimeLine()]
        if let summary, !summary.isEmpty {
            parts.append("【之前聊天的提要】\n\(summary)")
        }
        if !memories.isEmpty {
            let lines = memories.map { "- \($0.content)" }.joined(separator: "\n")
            parts.append("""
            【你记得关于对方的事】（只在和当前话题相关时自然地用上；不要逐条复述，不要说明你记得的原因）
            \(lines)
            """)
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - 整理提示词

    static func conversationText(_ messages: [ChatStore.Message], personaName: String) -> String {
        messages.map { message in
            let speaker = message.role == "user" ? "用户" : personaName
            return "\(speaker)：\(message.content)"
        }.joined(separator: "\n")
    }

    static func extractionPrompt(conversation: String, existing: [String]) -> String {
        let existingText = existing.isEmpty ? "（暂无）" : existing.map { "- \($0)" }.joined(separator: "\n")
        return """
        你是一个只负责整理记忆的模块，不参与聊天。
        请从下面的对话中，提取值得长期记住的、关于「用户」的信息（偏好、习惯、重要事实、计划、关系）。

        规则：
        - 只输出 JSON 数组，不要解释，不要 Markdown 代码块。
        - 每项格式：{"kind": "preference|fact|plan|relationship", "content": "第三人称短句，不超过 40 字"}
        - 只写对话里有明确依据的内容；不要猜测，不要编造。
        - 不要和「已有记忆」重复。
        - 没有值得记的就输出 []。

        已有记忆：
        \(existingText)

        对话：
        \(conversation)
        """
    }

    static func summaryPrompt(conversation: String) -> String {
        """
        请把下面的对话压缩成一段不超过 120 字的中文提要，保留：聊了什么、对方的近况与情绪、你答应过的事。
        只输出提要本身，不要解释，不要 Markdown。

        对话：
        \(conversation)
        """
    }

    // MARK: - 解析

    static func parseMemoryJSON(_ text: String) -> [(kind: String, content: String)] {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = body.firstIndex(of: "["), let end = body.lastIndex(of: "]") {
            body = String(body[start...end])
        }
        guard let data = body.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        let allowed: Set<String> = ["preference", "fact", "plan", "relationship"]
        var result: [(String, String)] = []
        var seen = Set<String>()
        for item in array.prefix(12) {
            guard let kind = (item["kind"] as? String)?.lowercased(),
                  allowed.contains(kind),
                  let raw = item["content"] as? String else { continue }
            let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty, content.count <= 120, !seen.contains(content) else { continue }
            seen.insert(content)
            result.append((kind, content))
        }
        return result
    }
}

extension Character {
    /// 常用 CJK 统一表意文字范围（含扩展 A）。
    var isCJK: Bool {
        for scalar in unicodeScalars {
            let value = scalar.value
            if (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value) {
                return true
            }
        }
        return false
    }
}
