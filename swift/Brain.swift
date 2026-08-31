// Мозг Писаря: локальная нейронка правит надиктованный текст по команде.
//
// Говоришь текст, в конце добавляешь обращение обычными словами:
//   «…жду ответа. Писарь, исправь»
//   «…созвон в пять. Гига Писарь, переведи на английский»
// Всё после слова «Писарь» — команда. Не позвал Писаря — текст вставляется
// сырым и мгновенно, нейронка его даже не видит.
//
// Нейронка — просто файл на диске (~/Library/Application Support/Giga Pisar/
// models), крутится локально через приложенный llama-server (движок llama.cpp,
// Contents/Frameworks/llama). Ничего в интернет не уходит — как и распознавание.
// Сервер поднимается при выборе модели и живёт рядом; думает 1–4 секунды.
//
// Если нейронка не ответила за разумное время или упала — вставляем сырой
// текст: диктовка не имеет права сломаться из-за мозга.

import AppKit

struct BrainModel {
    let id: String
    let name: String        // короткое имя для меню
    let details: String     // честное описание: вес, чей русский, какие маки
    let file: String
    let url: String
    let sizeText: String    // «6,5 ГБ» — для пункта «скачать»
    let minRAMGB: UInt64    // ниже этого объёма памяти отговариваем
}

var BRAIN_MODELS: [BrainModel] { [
    BrainModel(id: "gigachat",
               name: "GigaChat (Сбер)",
               details: L("родной русский · 6,5 ГБ · маки от 16 ГБ",
                          "native Russian · 6.5 GB · Macs with 16 GB"),
               file: "GigaChat3.1-10B-A1.8B-q4_K_M.gguf",
               url: "https://huggingface.co/ai-sage/GigaChat3.1-10B-A1.8B-GGUF/resolve/main/GigaChat3.1-10B-A1.8B-q4_K_M.gguf",
               sizeText: L("6,5 ГБ", "6.5 GB"),
               minRAMGB: 16),
    BrainModel(id: "qwen",
               name: "Qwen",
               details: L("лёгкая · 2,5 ГБ · русский неродной, но аккуратная",
                          "light · 2.5 GB · non-native Russian, but tidy"),
               file: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
               url: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
               sizeText: L("2,5 ГБ", "2.5 GB"),
               minRAMGB: 8),
] }

final class Brain: NSObject, URLSessionDownloadDelegate {
    static let shared = Brain()
    static let port: UInt16 = 8617

    /// Что выбрано в меню. nil — мозг выключен.
    var chosenId: String? {
        get {
            guard let v = UserDefaults.standard.string(forKey: "brainModel"),
                  v != "off" else { return nil }
            return v
        }
        set { UserDefaults.standard.set(newValue ?? "off", forKey: "brainModel") }
    }
    var chosenModel: BrainModel? { BRAIN_MODELS.first { $0.id == chosenId } }

    /// Кнопочки-подсказки после вставки. По умолчанию включены.
    var chipsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "brainChips") == nil
              || UserDefaults.standard.bool(forKey: "brainChips") }
        set { UserDefaults.standard.set(newValue, forKey: "brainChips") }
    }
    /// Мозг готов: модель выбрана и лежит на диске.
    var ready: Bool { chosenModel.map { downloaded($0) } ?? false }

    /// Меню перерисовать (и процент скачивания показать) — дергает App.
    var onChange: (() -> Void)?

    // MARK: файлы моделей

    static var modelsDir: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("Giga Pisar/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }
    func path(_ m: BrainModel) -> String { Self.modelsDir + "/" + m.file }
    func downloaded(_ m: BrainModel) -> Bool {
        FileManager.default.fileExists(atPath: path(m))
    }

    // MARK: скачивание модели (с процентами и докачкой после обрывов)

    private(set) var downloadingId: String?
    private(set) var downloadPercent = 0
    private var dlSession: URLSession?
    private var dlTask: URLSessionDownloadTask?
    private var dlResume: Data?
    private var dlRetries = 0

    func startDownload(_ m: BrainModel) {
        cancelDownload()
        downloadingId = m.id
        downloadPercent = 0
        dlRetries = 0
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        dlSession = s
        dlTask = s.downloadTask(with: URL(string: m.url)!)
        dlTask?.resume()
        onChange?()
    }

    func cancelDownload() {
        dlTask?.cancel()
        dlSession?.invalidateAndCancel()
        dlTask = nil; dlSession = nil; dlResume = nil
        downloadingId = nil
        onChange?()
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Int(100 * totalBytesWritten / totalBytesExpectedToWrite)
        guard p != downloadPercent else { return }
        downloadPercent = p
        DispatchQueue.main.async { self.onChange?() }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = downloadingId, let m = BRAIN_MODELS.first(where: { $0.id == id })
        else { return }
        try? FileManager.default.removeItem(atPath: path(m))
        do {
            try FileManager.default.moveItem(atPath: location.path, toPath: path(m))
            DispatchQueue.main.async {
                self.downloadingId = nil
                self.dlTask = nil; self.dlSession = nil
                self.chosenId = id       // скачал — сразу и выбрал
                self.ensureServer()
                self.onChange?()
                Toast.shared.show(L("\(m.name) скачан — Писарь слушает команды",
                                    "\(m.name) is ready — Pisar takes commands now"))
            }
        } catch {
            NSLog("Гига мозг: не сохранил модель — \(error)")
            DispatchQueue.main.async {
                self.downloadingId = nil
                self.onChange?()
            }
        }
        s.finishTasksAndInvalidate()
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, downloadingId != nil else { return }
        // Сеть мигнула — докачиваем с места обрыва, до пяти попыток.
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        DispatchQueue.main.async {
            if let resume, self.dlRetries < 5, let sess = self.dlSession {
                self.dlRetries += 1
                NSLog("Гига мозг: обрыв, докачиваю (попытка \(self.dlRetries))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    guard self.downloadingId != nil else { return }
                    self.dlTask = sess.downloadTask(withResumeData: resume)
                    self.dlTask?.resume()
                }
            } else {
                NSLog("Гига мозг: скачивание сорвалось — \(error)")
                self.downloadingId = nil
                self.onChange?()
                Toast.shared.show(L("Скачивание сорвалось — попробуй ещё раз из меню",
                                    "Download failed — try again from the menu"))
            }
        }
    }

    // MARK: llama-server рядом с нами

    private var server: Process?
    private var serverModelId: String?

    private var serverBinary: String {
        Bundle.main.bundlePath + "/Contents/Frameworks/llama/llama-server"
    }
    /// Движок вложен только для Apple Silicon: на M-чипах нейронка летает,
    /// на Intel мучилась бы. Там мозг в меню честно говорит, что не судьба.
    var engineAvailable: Bool {
        #if arch(arm64)
        return FileManager.default.fileExists(atPath: serverBinary)
        #else
        return false
        #endif
    }

    /// Поднять сервер под выбранную модель (или погасить, если мозг выключен).
    func ensureServer() {
        guard let m = chosenModel, downloaded(m), engineAvailable else {
            stopServer()
            return
        }
        if let s = server, s.isRunning, serverModelId == m.id { return }
        stopServer()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: serverBinary)
        p.arguments = ["-m", path(m), "--host", "127.0.0.1", "--port", "\(Self.port)",
                       "-c", "4096", "-ngl", "99", "--no-webui"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            server = p
            serverModelId = m.id
            NSLog("Гига мозг: поднял \(m.name) на порту \(Self.port)")
        } catch {
            NSLog("Гига мозг: сервер не поднялся — \(error)")
        }
    }

    func stopServer() {
        server?.terminate()
        server = nil
        serverModelId = nil
    }

    // MARK: обращение «Писарь, …»

    /// Ищет в тексте обращение к Писарю. Всё после него — команда.
    /// Берём ПОСЛЕДНЕЕ вхождение: если в самом тексте шла речь про Писаря,
    /// сработает только хвостовое обращение. Распознавание может услышать
    /// «песарь» или «писарь» с разными окончаниями — сравнение мягкое.
    static func parseCommand(_ text: String) -> (body: String, command: String)? {
        let pat = "(?:гига[\\s,—-]+)?п[еиэ]сар[ьяюе]?\\b[\\s,.:!—-]*"
        guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive])
        else { return nil }
        let ns = text as NSString
        let all = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let m = all.last else { return nil }
        let command = ns.substring(from: m.range.location + m.range.length)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var body = ns.substring(to: m.range.location)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // висячие запятые и тире перед обращением («…текст, Писарь исправь»)
        while let last = body.last, ",—-–".contains(last) {
            body = String(body.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !command.isEmpty, !body.isEmpty else { return nil }
        return (body, command)
    }

    // MARK: сама работа

    private static let systemPrompt = """
    Ты обрабатываешь надиктованный голосом текст перед вставкой. Правила: \
    убери слова-паразиты и оговорки (э, ну, типа, вот, как бы), убери повторы \
    и самоисправления, расставь знаки препинания, исправь очевидные ошибки \
    распознавания. Сохраняй смысл, лексику и живой тон автора, ничего не \
    добавляй от себя и не комментируй. Выполни команду пользователя. \
    Верни ТОЛЬКО готовый текст, без кавычек вокруг него.
    """

    /// Прогнать текст через нейронку. done зовётся на любом исходе:
    /// с готовым текстом — или с nil, если мозг не справился (тогда
    /// вызывающий вставляет сырой текст, диктовка не ломается).
    func transform(_ body: String, command: String, done: @escaping (String?) -> Void) {
        ensureServer()
        let deadline = Date().addingTimeInterval(40)
        waitHealthy(until: deadline) { [weak self] ok in
            guard ok else { done(nil); return }
            self?.chat(body: body, command: command, done: done)
        }
    }

    /// Сервер мог только-только подняться и ещё грузить модель с диска —
    /// ждём его «ok», спрашивая раз в полсекунды.
    private func waitHealthy(until deadline: Date, _ done: @escaping (Bool) -> Void) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/health")!)
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data, String(data: data, encoding: .utf8)?.contains("ok") == true {
                done(true)
            } else if Date() < deadline {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    self.waitHealthy(until: deadline, done)
                }
            } else {
                done(false)
            }
        }.resume()
    }

    private func chat(body: String, command: String, done: @escaping (String?) -> Void) {
        let messages: [[String: String]] = [
            ["role": "system", "content": Self.systemPrompt],
            ["role": "user", "content": "\(body)\n\nКоманда: \(command)"],
        ]
        let payload: [String: Any] = ["messages": messages,
                                      "temperature": 0.3, "max_tokens": 2048]
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 60
        URLSession.shared.dataTask(with: req) { data, _, error in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let text = (msg["content"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else {
                NSLog("Гига мозг: не ответил — \(error?.localizedDescription ?? "пустой ответ")")
                done(nil)
                return
            }
            done(text)
        }.resume()
    }
}
