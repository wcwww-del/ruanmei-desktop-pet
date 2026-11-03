import AppKit
import Security

// MARK: - 路径

enum PetPaths {
#if RUANMEI_TESTING
    /// 只给测试脚手架用，发布构建里不存在。
    static var overrideSupport: URL?
    static var support: URL? { overrideSupport ?? PetSecurity.userAssetDirectory() }
#else
    static var support: URL? { PetSecurity.userAssetDirectory() }
#endif
    static var configURL: URL? { support?.appendingPathComponent("config.json") }
    static var databaseURL: URL? { support?.appendingPathComponent("pet.sqlite3") }
}

// MARK: - 钥匙串

/// API Key 存在钥匙串里（service 固定）。读写失败时返回错误，由界面提示，
/// 绝不静默写进明文配置文件。
enum PetKeychain {
    static let service = "com.wangchao.ruanmeipet"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) -> OSStatus {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(value.utf8)
        var status = SecItemUpdate(base as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func describe(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? { return message }
        return "OSStatus \(status)"
    }
}

// MARK: - 配置

enum TTSProvider: String, Codable, CaseIterable {
    case system
    case openAICompatible

    var title: String {
        switch self {
        case .system: return "系统语音（离线）"
        case .openAICompatible: return "OpenAI 兼容 TTS（可填克隆音色）"
        }
    }
}

struct LLMConfig: Codable {
    var baseURL = ""
    var model = ""
    var temperature = 0.85
    var maxTokens = 400

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = c.value(.baseURL, "")
        model = c.value(.model, "")
        temperature = c.value(.temperature, 0.85)
        maxTokens = c.value(.maxTokens, 400)
    }
}

struct TTSConfig: Codable {
    var enabled = true
    var provider: TTSProvider = .system
    var baseURL = ""
    var model = "tts-1"
    var voice = ""
    var speed = 1.0
    var systemVoice = ""
    var language = "zh-CN"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, true)
        provider = c.value(.provider, TTSProvider.system)
        baseURL = c.value(.baseURL, "")
        model = c.value(.model, "tts-1")
        voice = c.value(.voice, "")
        speed = c.value(.speed, 1.0)
        systemVoice = c.value(.systemVoice, "")
        language = c.value(.language, "zh-CN")
    }
}

struct MemoryConfig: Codable {
    var enabled = true
    var autoExtractEvery = 6
    var maxInjected = 6
    var historyTurns = 12
    var summarizeEvery = 12

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, true)
        autoExtractEvery = c.value(.autoExtractEvery, 6)
        maxInjected = c.value(.maxInjected, 6)
        historyTurns = c.value(.historyTurns, 12)
        summarizeEvery = c.value(.summarizeEvery, 12)
    }
}

struct PetConfig: Codable {
    var llm = LLMConfig()
    var tts = TTSConfig()
    var memory = MemoryConfig()
    var activePersonaID = PersonaLibrary.defaultID
    var customPersonas: [Persona] = []
    var chatVoiceEnabled = true
    var windowWidth = 400.0
    var windowHeight = 600.0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        llm = c.value(.llm, LLMConfig())
        tts = c.value(.tts, TTSConfig())
        memory = c.value(.memory, MemoryConfig())
        activePersonaID = c.value(.activePersonaID, PersonaLibrary.defaultID)
        customPersonas = c.value(.customPersonas, [])
        chatVoiceEnabled = c.value(.chatVoiceEnabled, true)
        windowWidth = c.value(.windowWidth, 400)
        windowHeight = c.value(.windowHeight, 600)
    }
}

private extension KeyedDecodingContainer {
    /// 字段缺失或类型不符时退回默认值，方便以后加字段而不清空用户配置。
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decode(T.self, forKey: key)) ?? fallback
    }
}

// MARK: - 配置读写

final class ConfigStore {
    static let shared = ConfigStore()

    var config = PetConfig()
    private(set) var loadError: String?

    /// API Key 只在内存里缓存，落盘靠钥匙串。
    /// 延迟到真正要用时才读钥匙串：避免启动时就弹系统授权框。
    private var cachedLLMKey = ""
    private var cachedTTSKey = ""
    private var didLoadLLMKey = false
    private var didLoadTTSKey = false

    var llmAPIKey: String {
        if !didLoadLLMKey {
            didLoadLLMKey = true
            cachedLLMKey = PetKeychain.read("llm.apiKey") ?? ""
        }
        return cachedLLMKey
    }

    var ttsAPIKey: String {
        if !didLoadTTSKey {
            didLoadTTSKey = true
            cachedTTSKey = PetKeychain.read("tts.apiKey") ?? ""
        }
        return cachedTTSKey
    }

    private init() {}

    func load() {
        guard let url = PetPaths.configURL else {
            loadError = "无法访问配置目录（~/Library/Application Support/RuanMeiPet 权限异常）"
            return
        }
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            config = try JSONDecoder().decode(PetConfig.self, from: data)
        } catch {
            loadError = "配置文件解析失败，已使用默认设置：\(error.localizedDescription)"
        }
    }

    func save() {
        guard let url = PetPaths.configURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        do {
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            loadError = "配置保存失败：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func setLLMKey(_ key: String) -> String? {
        didLoadLLMKey = true
        cachedLLMKey = key
        if key.isEmpty {
            PetKeychain.delete("llm.apiKey")
            return nil
        }
        let status = PetKeychain.write(key, account: "llm.apiKey")
        return status == errSecSuccess ? nil : "钥匙串写入失败：\(PetKeychain.describe(status))"
    }

    @discardableResult
    func setTTSKey(_ key: String) -> String? {
        didLoadTTSKey = true
        cachedTTSKey = key
        if key.isEmpty {
            PetKeychain.delete("tts.apiKey")
            return nil
        }
        let status = PetKeychain.write(key, account: "tts.apiKey")
        return status == errSecSuccess ? nil : "钥匙串写入失败：\(PetKeychain.describe(status))"
    }

    var activePersona: Persona {
        PersonaLibrary.find(config.activePersonaID, custom: config.customPersonas)
    }

    var allPersonas: [Persona] {
        PersonaLibrary.builtIns + config.customPersonas
    }

#if RUANMEI_TESTING
    func setRuntimeKeysForTesting(llm: String, tts: String) {
        didLoadLLMKey = true
        didLoadTTSKey = true
        cachedLLMKey = llm
        cachedTTSKey = tts
    }
#endif

    func llmReady() -> Bool {
        !config.llm.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !config.llm.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !llmAPIKey.isEmpty
    }
}
