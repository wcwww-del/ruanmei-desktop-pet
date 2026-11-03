import AppKit
import AVFoundation

// MARK: - 流式句子切分

/// 把流式文本切成适合朗读的短句：遇到句末标点就切，太长的句子在逗号处切。
final class SentenceStreamer {
    private var buffer = ""
    private let terminators: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "\n"]
    private var started = false

    var onSentence: ((String) -> Void)?

    func feed(_ delta: String) {
        buffer += delta
        while let sentence = takeSentence() {
            emit(sentence)
        }
        if buffer.count > 80 {
            if let cut = lastBreakIndex() {
                let head = String(buffer[..<cut])
                buffer = String(buffer[cut...])
                emit(head)
            }
        }
    }

    func flush() {
        let rest = buffer
        buffer = ""
        emit(rest)
        started = false
    }

    private func takeSentence() -> String? {
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let character = buffer[index]
            if terminators.contains(character) {
                var end = buffer.index(after: index)
                // 把连续的标点（……、！！）一起带上
                while end < buffer.endIndex, terminators.contains(buffer[end]) || buffer[end] == "…" {
                    end = buffer.index(after: end)
                }
                let sentence = String(buffer[..<end])
                buffer = String(buffer[end...])
                return sentence
            }
            index = buffer.index(after: index)
        }
        return nil
    }

    private func lastBreakIndex() -> String.Index? {
        let breaks: Set<Character> = ["，", "、", ",", " "]
        var index = buffer.endIndex
        while index > buffer.startIndex {
            index = buffer.index(before: index)
            if breaks.contains(buffer[index]) { return buffer.index(after: index) }
        }
        return nil
    }

    private func emit(_ raw: String) {
        let cleaned = SpeechEngine.cleanForSpeech(raw)
        guard cleaned.count >= 2 else { return }
        guard cleaned.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        if !started {
            started = true
        }
        onSentence?(cleaned)
    }
}

// MARK: - 语音输出

final class SpeechEngine: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = SpeechEngine()

    /// 出错时回调（在主线程），只用于提示，不打断对话。
    var onError: ((String) -> Void)?
    /// 设置窗口「试听」用：还没保存到钥匙串的临时 Key。
    var transientAPIKey: String?

    private var config = TTSConfig()
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var queue: [String] = []
    private var busy = false
    private var generation = 0
    private var reportedError = false

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    func configure(_ config: TTSConfig) {
        self.config = config
    }

    var isSpeaking: Bool {
        busy || !queue.isEmpty
    }

    func enqueue(_ text: String) {
        guard config.enabled else { return }
        let cleaned = Self.cleanForSpeech(text)
        guard cleaned.count >= 2 else { return }
        queue.append(String(cleaned.prefix(400)))
        drain()
    }

    func stop() {
        generation += 1
        queue.removeAll()
        busy = false
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
    }

    /// 去掉 Markdown 符号和括号注释，避免念出「星号星号」。
    static func cleanForSpeech(_ text: String) -> String {
        var result = text
        for token in ["**", "__", "`", "#", ">", "*", "_", "|"] {
            result = result.replacingOccurrences(of: token, with: "")
        }
        if let regex = try? NSRegularExpression(pattern: "\\[([^\\]]*)\\]\\([^\\)]*\\)") {
            result = regex.stringByReplacingMatches(in: result,
                                                    range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: "$1")
        }
        result = result.replacingOccurrences(of: "\n", with: "，")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 队列

    private func drain() {
        guard !busy, !queue.isEmpty else { return }
        let text = queue.removeFirst()
        busy = true
        let token = generation
        if effectiveProvider == .system {
            speakWithSystem(text, token: token)
        } else {
            speakWithRemote(text, token: token)
        }
    }

    private var effectiveProvider: TTSProvider {
        if config.provider == .openAICompatible,
           !config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .openAICompatible
        }
        return .system
    }

    private func finishOne() {
        busy = false
        player = nil
        drain()
    }

    private func fail(_ message: String) {
        if !reportedError {
            reportedError = true
            DispatchQueue.main.async { [weak self] in
                self?.onError?(message)
            }
        }
        finishOne()
    }

    // MARK: 系统语音

    private func speakWithSystem(_ text: String, token: Int) {
        let utterance = AVSpeechUtterance(string: text)
        if !config.systemVoice.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: config.systemVoice) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: config.language)
                ?? AVSpeechSynthesisVoice(language: "zh-CN")
        }
        utterance.rate = 0.47
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finishOne()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finishOne()
    }

    // MARK: 远程 TTS

    private func speakWithRemote(_ text: String, token: Int) {
        guard let url = ChatClient.endpoint(config.baseURL, path: "/audio/speech"),
              EndpointPolicy.isAllowed(config.baseURL) else {
            fail("TTS 接口地址无效，已改用系统语音")
            speakWithSystem(text, token: token)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = transientAPIKey ?? ConfigStore.shared.ttsAPIKey
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": config.model,
            "input": text,
            "voice": config.voice,
            "speed": config.speed,
            "response_format": "mp3"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                if let error {
                    self.fail("TTS 请求失败：\(error.localizedDescription)")
                    return
                }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let data, data.count > 500 else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    self.fail("TTS 返回异常（\(status)）")
                    return
                }
                do {
                    let player = try AVAudioPlayer(data: data)
                    player.delegate = self
                    self.player = player
                    player.play()
                } catch {
                    self.fail("TTS 音频无法播放：\(error.localizedDescription)")
                }
            }
        }.resume()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finishOne()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        fail("TTS 音频解码失败")
    }
}

// MARK: - 音色参考样本

/// AVAssetExportSession 的完成回调在后台线程，用一个盒子把它带过并发边界。
private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

/// 把内置的几句阮·梅语音拼成一条参考样本，方便上传到支持声音克隆的 TTS 服务。
enum VoiceSampleExporter {
    static func export(urls: [URL], to destination: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        Task {
            let composition = AVMutableComposition()
            guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
                await MainActor.run {
                    completion(.failure(NSError(domain: "RuanMeiPet", code: 1,
                                                userInfo: [NSLocalizedDescriptionKey: "无法创建音轨"])))
                }
                return
            }
            var cursor = CMTime.zero
            for url in urls {
                let asset = AVURLAsset(url: url)
                guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                      let duration = try? await asset.load(.duration) else { continue }
                guard (try? track.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                                  of: source, at: cursor)) != nil else { continue }
                cursor = CMTimeAdd(cursor, duration)
                let gap = CMTime(value: 3, timescale: 10)
                track.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: gap))
                cursor = CMTimeAdd(cursor, gap)
            }

            guard composition.duration.seconds > 1,
                  let exporter = AVAssetExportSession(asset: composition,
                                                      presetName: AVAssetExportPresetAppleM4A) else {
                await MainActor.run {
                    completion(.failure(NSError(domain: "RuanMeiPet", code: 2,
                                                userInfo: [NSLocalizedDescriptionKey: "素材不足，无法生成样本"])))
                }
                return
            }
            try? FileManager.default.removeItem(at: destination)
            exporter.outputURL = destination
            exporter.outputFileType = .m4a
            let box = ExportSessionBox(exporter)
            exporter.exportAsynchronously {
                DispatchQueue.main.async {
                    switch box.session.status {
                    case .completed:
                        completion(.success(()))
                    case .cancelled:
                        completion(.failure(NSError(domain: "RuanMeiPet", code: 3,
                                                    userInfo: [NSLocalizedDescriptionKey: "导出已取消"])))
                    default:
                        completion(.failure(box.session.error ?? NSError(domain: "RuanMeiPet", code: 4,
                                                                         userInfo: [NSLocalizedDescriptionKey: "导出失败"])))
                    }
                }
            }
        }
    }
}
