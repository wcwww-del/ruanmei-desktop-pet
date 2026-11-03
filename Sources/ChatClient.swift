import Foundation

// MARK: - 错误

enum ChatError: LocalizedError {
    case invalidURL(String)
    case missingKey
    case http(Int, String)
    case emptyResponse
    case cancelled
    case malformed

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "接口地址无效：\(url)"
        case .missingKey:
            return "还没有填写 API Key"
        case .http(let code, let message):
            switch code {
            case 401, 403: return "鉴权失败（\(code)）：请检查 API Key。\(message)"
            case 404: return "接口不存在（404）：请检查 Base URL，例如是否少了 /v1。\(message)"
            case 429: return "请求太频繁或额度用尽（429）：\(message)"
            default: return "请求失败（\(code)）：\(message)"
            }
        case .emptyResponse:
            return "服务端没有返回内容"
        case .cancelled:
            return "已停止"
        case .malformed:
            return "无法解析服务端返回"
        }
    }
}

// MARK: - 数据结构

struct ChatMessage: Codable {
    let role: String
    let content: String

    init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

struct ChatRequestConfig {
    var baseURL: String
    var apiKey: String
    var model: String
    var temperature: Double
    var maxTokens: Int
}

final class ChatTask {
    private var task: Task<Void, Never>?
    private var cancelled = false

    fileprivate func attach(_ task: Task<Void, Never>) {
        self.task = task
        if cancelled { task.cancel() }
    }

    var isCancelled: Bool { cancelled }

    func cancel() {
        cancelled = true
        task?.cancel()
    }
}

// MARK: - OpenAI 兼容客户端

/// 只做最通用的一件事：POST {base}/chat/completions，stream=true，按 SSE 解析。
/// 回调在后台队列触发，界面层需要自己合并到主线程。
final class ChatClient {
    static let shared = ChatClient()

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
    }

    static func endpoint(_ base: String, path: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, let scheme = URL(string: trimmed)?.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        if trimmed.hasSuffix(path) { return URL(string: trimmed) }
        return URL(string: trimmed + path)
    }

    @discardableResult
    func stream(messages: [ChatMessage],
                config: ChatRequestConfig,
                onDelta: @escaping (String) -> Void,
                completion: @escaping (Result<String, Error>) -> Void) -> ChatTask {
        let handle = ChatTask()
        guard !config.apiKey.isEmpty else {
            completion(.failure(ChatError.missingKey))
            return handle
        }
        guard let url = Self.endpoint(config.baseURL, path: "/chat/completions") else {
            completion(.failure(ChatError.invalidURL(config.baseURL)))
            return handle
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        let payload: [String: Any] = [
            "model": config.model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": true,
            "temperature": config.temperature,
            "max_tokens": config.maxTokens
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(.failure(ChatError.malformed))
            return handle
        }
        request.httpBody = body

        let task = Task { [session] in
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw ChatError.malformed }

                if !(200..<300).contains(http.statusCode) {
                    var text = ""
                    for try await line in bytes.lines {
                        text += line
                        if text.count > 4000 { break }
                    }
                    throw ChatError.http(http.statusCode, Self.friendlyMessage(from: text))
                }

                var accumulated = ""
                var raw: [String] = []
                var sawContent = false

                for try await line in bytes.lines {
                    if Task.isCancelled { throw ChatError.cancelled }
                    if line.isEmpty { continue }
                    if raw.count < 2000 { raw.append(line) }
                    guard line.hasPrefix("data:") else { continue }
                    let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if payload.isEmpty { continue }
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                    if let error = object["error"] as? [String: Any],
                       let message = error["message"] as? String {
                        throw ChatError.http(200, message)
                    }
                    guard let choices = object["choices"] as? [[String: Any]],
                          let first = choices.first else { continue }

                    if let delta = first["delta"] as? [String: Any],
                       let text = delta["content"] as? String, !text.isEmpty {
                        sawContent = true
                        accumulated += text
                        if accumulated.count > 120_000 { throw ChatError.emptyResponse }
                        onDelta(text)
                    } else if let message = first["message"] as? [String: Any],
                              let text = message["content"] as? String, !text.isEmpty {
                        // 有些服务端在 stream=true 时直接返回整段 JSON。
                        sawContent = true
                        accumulated = text
                        onDelta(text)
                    }
                }

                if !sawContent {
                    let joined = raw.joined(separator: "\n")
                    if let data = joined.data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let choices = object["choices"] as? [[String: Any]],
                       let message = choices.first?["message"] as? [String: Any],
                       let text = message["content"] as? String, !text.isEmpty {
                        accumulated = text
                        onDelta(text)
                    }
                }

                guard !accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ChatError.emptyResponse
                }
                completion(.success(accumulated))
            } catch {
                if Task.isCancelled || error is CancellationError {
                    completion(.failure(ChatError.cancelled))
                } else {
                    completion(.failure(error))
                }
            }
        }
        handle.attach(task)
        return handle
    }

    /// 一次性收完（记忆提取、摘要用），不暴露增量。
    @discardableResult
    func complete(messages: [ChatMessage],
                  config: ChatRequestConfig,
                  completion: @escaping (Result<String, Error>) -> Void) -> ChatTask {
        stream(messages: messages, config: config, onDelta: { _ in }, completion: completion)
    }

    private static func friendlyMessage(from body: String) -> String {
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String { return message }
            if let message = object["message"] as? String { return message }
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(200))
    }
}

// MARK: - 网络地址校验

enum EndpointPolicy {
    /// 只允许 https；本机回环地址允许 http（方便 Ollama / LM Studio / 本地 mock）。
    static func isAllowed(_ raw: String) -> Bool {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}
