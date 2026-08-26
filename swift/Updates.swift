// Проверка обновлений.
//
// Раз в несколько часов спрашиваем у GitHub номер последнего выпуска и
// сравниваем со своим. Ничего не скачиваем и не ставим сами — если вышла
// новая версия, показываем её в меню и предлагаем открыть страницу выпуска.
// В сеть уходит один запрос без каких-либо данных о пользователе.

import Foundation

let RELEASES_PAGE = "https://github.com/moznoazachem/giga/releases/latest"
private let LATEST_API = "https://api.github.com/repos/moznoazachem/giga/releases/latest"

/// Спрашивает у GitHub последний выпуск: номер («2.5») и ссылку на zip
/// с приложением — для самообновления. nil — не дозвонились.
func fetchLatestRelease(_ done: @escaping (String?, URL?) -> Void) {
    guard let url = URL(string: LATEST_API) else { done(nil, nil); return }
    var req = URLRequest(url: url)
    req.timeoutInterval = 10
    URLSession.shared.dataTask(with: req) { data, _, _ in
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { done(nil, nil); return }
        let zip = (json["assets"] as? [[String: Any]])?
            .first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap { URL(string: $0) }
        done(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, zip)
    }.resume()
}

/// Сравнение номеров по частям: «2.10» новее «2.9».
func isNewerVersion(_ a: String, than b: String) -> Bool {
    let pa = a.split(separator: ".").map { Int($0) ?? 0 }
    let pb = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0
        let y = i < pb.count ? pb[i] : 0
        if x != y { return x > y }
    }
    return false
}
