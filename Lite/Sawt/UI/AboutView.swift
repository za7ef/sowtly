import SwiftUI

enum AppVersion {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var build: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }
    static var label: String { L("الإصدار %1$@ (البناء %2$@)", version, String(build)) }
}

/// يقرأ ملف Markdown من مجلد About داخل التطبيق.
enum AboutText {
    static func load(_ name: String) -> String {
        // النسخة الإنجليزية (about.en.md…) حين تكون الواجهة بالإنجليزية
        if !AppLang.isArabic, let u = Bundle.main.url(forResource: name + ".en", withExtension: "md")
            ?? Bundle.main.url(forResource: name + ".en", withExtension: "md", subdirectory: "About"),
           let s = try? String(contentsOf: u, encoding: .utf8) { return s }
        guard let url = Bundle.main.url(forResource: name, withExtension: "md")
            ?? Bundle.main.url(forResource: name, withExtension: "md", subdirectory: "About"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return L("تعذّر العثور على النص.") }
        return s
    }
}

/// عرض بسيط لـ Markdown: عناوين، قوائم، فقرات، مع الروابط والخط العريض.
struct MarkdownPage: View {
    let title: String
    let file: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in b }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var blocks: [AnyView] {
        AboutText.load(file).components(separatedBy: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if line.hasPrefix("# ") {
                return AnyView(Text(md(String(line.dropFirst(2)))).font(.title2.bold()).padding(.top, 4))
            }
            if line.hasPrefix("## ") {
                return AnyView(Text(md(String(line.dropFirst(3)))).font(.headline).padding(.top, 10))
            }
            if line.hasPrefix("- ") {
                return AnyView(HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•")
                    Text(md(String(line.dropFirst(2))))
                })
            }
            return AnyView(Text(md(line)).foregroundStyle(.primary.opacity(0.9)))
        }
    }

    private func md(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

struct AboutSection: View {
    var body: some View {
        Section("حول التطبيق") {
            HStack(spacing: 14) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(LinearGradient(colors: [Theme.accent, Theme.accent2],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "صوت لايت").font(.headline)
                    Text(AppVersion.label).font(.caption).foregroundStyle(.secondary)
                    Text("مساعد ذكي يعمل على جهازك").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            NavigationLink("عن صوت لايت والتراخيص") { MarkdownPage(title: L("حول التطبيق"), file: "about") }
            NavigationLink("سياسة الاستخدام") { MarkdownPage(title: L("سياسة الاستخدام"), file: "terms") }
            NavigationLink("سياسة الخصوصية") { MarkdownPage(title: L("سياسة الخصوصية"), file: "privacy") }
            Button("تحقق من التحديثات") { Task { await UpdateChecker.shared.check(force: true) } }
        }
    }
}
