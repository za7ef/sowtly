import Foundation
import SwiftUI

/// يتحقق من وجود إصدار أحدث بدون أي توكن أو بيانات عن المستخدم.
/// أول شي يقرأ إصدارات المستودع العام من واجهة GitHub، وإذا ما نفع (مثلًا صار المستودع خاص)
/// يرجع لملف update.json العام في مستودع منفصل.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let feed = URL(string: "https://raw.githubusercontent.com/za7ef/sawt-releases/main/update-lite.json")!
    /// صوت لايت يُبنى في مستودع Sowtly نفسه، وكل إصدار فيه الملفّان (Sowtly.ipa وSawtLite.ipa)
    static let releasesAPI = URL(string: "https://api.github.com/repos/za7ef/sowtly/releases?per_page=30")!

    private struct GHRelease: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
        let draft: Bool
    }

    /// أحدث بناء من إصدارات GitHub العامة (الوسم build-N). nil إذا ما قدر.
    private func fromReleases() async -> Info? {
        var req = URLRequest(url: Self.releasesAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONDecoder().decode([GHRelease].self, from: data) else { return nil }
        let builds = list.compactMap { r -> (Int, GHRelease)? in
            guard !r.draft, r.tag_name.hasPrefix("build-"), let n = Int(r.tag_name.dropFirst(6)) else { return nil }
            return (n, r)
        }
        guard let (n, r) = builds.max(by: { $0.0 < $1.0 }) else { return nil }
        // اسم الإصدار: «صوت 0.4.12 · صوت لايت 0.1 (بناء N)»؛ نأخذ الرقم بعد «لايت»
        let version = (r.name ?? "").firstMatch(of: /لايت (\d+\.\d+(\.\d+)?)/).map { String($0.output.1) } ?? AppVersion.version
        return Info(version: version, build: n, notes: r.body, url: r.html_url)
    }

    private func fromFeed() async -> Info? {
        var req = URLRequest(url: Self.feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data)
    }

    struct Info: Codable, Identifiable {
        var version: String
        var build: Int
        var notes: String?
        var url: String
        var id: Int { build }
    }

    @Published var available: Info?
    @Published var lastMessage: String?
    private let d = UserDefaults.standard

    func check(force: Bool = false) async {
        let now = Date().timeIntervalSince1970
        if !force {
            if now - d.double(forKey: "updLastCheck") < 86_400 { return }
            if now < d.double(forKey: "updSnoozeUntil") { return }
        }
        // بدون إنترنت مفتوح: التحقق التلقائي يتخطى بصمت، واليدوي يطلب سماح
        if force {
            guard await NetworkGate.shared.permit(L("التحقق من التحديثات")) else { return }
        } else if !NetworkGate.shared.on { return }
        d.set(now, forKey: "updLastCheck")
        var found = await fromReleases()
        if found == nil { found = await fromFeed() }
        guard let info = found else {
            if force { lastMessage = L("تعذّر التحقق من التحديثات الآن.") }
            return
        }
        // ما نقبل إلا روابط إصدارات المطوّر نفسه
        guard info.url.hasPrefix("https://github.com/za7ef/") else { return }
        if info.build > AppVersion.build {
            available = info
        } else if force {
            lastMessage = L("لديك أحدث إصدار (%1$@ البناء %2$@).", AppVersion.version, String(AppVersion.build))
        }
    }

    func snooze() {
        d.set(Date().timeIntervalSince1970 + 86_400, forKey: "updSnoozeUntil")
        available = nil
    }
}

struct UpdateSheet: View {
    let info: UpdateChecker.Info
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "arrow.down.app.fill").font(.largeTitle).foregroundStyle(Theme.accent)
                VStack(alignment: .leading) {
                    Text("تحديث جديد متوفر").font(.title3.bold())
                    Text(L("الإصدار %1$@ (البناء %2$@)", info.version, String(info.build))).foregroundStyle(.secondary)
                    Text(L("لديك: %1$@ (البناء %2$@)", AppVersion.version, String(AppVersion.build))).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let n = info.notes, !n.isEmpty {
                Text("ما الجديد").font(.headline)
                ScrollView {
                    Text((try? AttributedString(markdown: n, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(n))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button("لاحقًا") { UpdateChecker.shared.snooze() }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
                Button("تحديث") {
                    if info.url.hasPrefix("https://github.com/za7ef/"), let u = URL(string: info.url) { openURL(u) }
                    UpdateChecker.shared.available = nil
                }
                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .padding(24)
        .presentationDetents([.medium, .large])
    }
}
