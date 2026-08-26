// Самообновление: скачать выпуск с GitHub, проверить, подменить себя,
// перезапуститься. Без нотаризации это законно, потому что обновление
// ставит не человек (скачанному из браузера Gatekeeper устроил бы допрос),
// а само приложение, которому уже доверяют: оно стоит и работает.
//
// Безопасность — три замка перед подменой:
//   1) подпись нового бандла цела (codesign --verify --deep --strict);
//   2) команда подписи (TeamIdentifier) та же, что у работающей копии, —
//      чужой архив, даже подсунутый на странице выпусков, не пройдёт;
//   3) bundle id совпадает — это точно Гига Писарь, а не что-то ещё.
// Подмена — после выхода приложения, маленьким шелл-скриптом: ждёт выхода,
// меняет бандл, запускает новый, прибирает за собой.

import AppKit

enum SelfUpdate {
    private(set) static var inProgress = false

    /// Команда подписи бандла («CXX972W555») или nil, если подписи нет.
    static func teamID(of path: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-dvv", path]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        for line in out.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let v = String(line.dropFirst("TeamIdentifier=".count))
            return v == "not set" ? nil : v
        }
        return nil
    }

    /// Подпись бандла цела и ничего внутри не подменено?
    static func signatureIntact(_ path: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--verify", "--deep", "--strict", path]
        p.standardError = Pipe()
        p.standardOutput = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Качает zip выпуска, проверяет и подменяет работающее приложение.
    /// При любой беде зовёт fail(причина) на главной очереди и НИЧЕГО не трогает.
    static func run(zip: URL, version: String, fail: @escaping (String) -> Void) {
        guard !inProgress else { return }
        inProgress = true
        func bail(_ m: String) {
            DispatchQueue.main.async { inProgress = false; fail(m) }
        }

        let dest = Bundle.main.bundlePath
        let fm = FileManager.default
        guard dest.hasSuffix(".app"),
              fm.isWritableFile(atPath: dest),
              fm.isWritableFile(atPath: (dest as NSString).deletingLastPathComponent)
        else {
            bail(L("нет прав заменить \(dest)", "no permission to replace \(dest)"))
            return
        }

        let task = URLSession.shared.downloadTask(with: zip) { tmp, _, err in
            guard let tmp, err == nil else {
                bail(L("не скачалось: \(err?.localizedDescription ?? "обрыв")",
                       "download failed: \(err?.localizedDescription ?? "interrupted")"))
                return
            }
            let dir = NSTemporaryDirectory() + "giga-update-\(version)"
            try? fm.removeItem(atPath: dir)
            do {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try fm.moveItem(atPath: tmp.path, toPath: dir + "/update.zip")
            } catch {
                bail(L("не сохранилось во временную папку", "couldn't save to a temp folder"))
                return
            }

            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-xk", dir + "/update.zip", dir]
            do { try unzip.run(); unzip.waitUntilExit() } catch {
                bail(L("архив не распаковался", "couldn't unpack the archive")); return
            }
            guard unzip.terminationStatus == 0,
                  let name = (try? fm.contentsOfDirectory(atPath: dir))?
                      .first(where: { $0.hasSuffix(".app") })
            else {
                bail(L("в архиве не нашлось приложения", "no app inside the archive")); return
            }
            let newApp = dir + "/" + name

            // три замка
            guard signatureIntact(newApp) else {
                bail(L("подпись обновления повреждена", "the update's signature is broken")); return
            }
            guard let newTeam = teamID(of: newApp), newTeam == teamID(of: dest) else {
                bail(L("обновление подписано не нами", "the update is signed by someone else")); return
            }
            guard Bundle(path: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                bail(L("в архиве не Гига Писарь", "the archive isn't Giga Pisar")); return
            }

            // подмена после нашего выхода
            let script = dir + "/swap.sh"
            let sh = """
            #!/bin/sh
            while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.3; done
            /bin/rm -rf "\(dest)"
            /usr/bin/ditto "\(newApp)" "\(dest)"
            /usr/bin/open "\(dest)"
            /bin/rm -rf "\(dir)"
            """
            do {
                try sh.write(toFile: script, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = [script]
                try p.run() // НЕ ждём: он ждёт нас
            } catch {
                bail(L("не запустился установщик", "the installer didn't start")); return
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        task.resume()
    }
}
