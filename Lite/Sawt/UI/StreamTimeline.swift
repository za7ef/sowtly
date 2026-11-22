import SwiftUI

// MARK: - نص الرد بإيقاع ثابت مع ظهور ناعم لكل كلمة

/// يعرض نص الرد كلمة كلمة بإيقاع ثابت (يسرّع لو تراكم النص)، وكل دفعة جديدة تظهر بتلاشي ناعم.
/// نقسم على المسافات بس، فما تنكسر الحروف العربية المتصلة؛ والتلاشي لون على مقطع من نفس النص المنسّق.
/// لما يخلص الرد أو ينوقف، الرسالة النهائية تطلع كاملة على طول (هالعرض للرد الجاري بس).
struct PacedText: View {
    let target: String
    /// الرد خلص: نطلق آخر كلمة على طول ونبلّغ لما نلحق
    var done = false
    var onGrow: () -> Void = {}
    var onCaughtUp: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Reveal { let at: Int; let time: Date }
    @State private var shown = 0
    @State private var reveals: [Reveal] = []
    @State private var lastLen = 0
    @State private var lastGrowth = Date()
    // نسخة حيّة من المدخلات: مهمة .task تحتفظ بنسخة الـView وقت بدايتها، فقراءة target منها تعطي أول دفعة بس
    @State private var latest = ""
    @State private var finished = false
    @State private var reported = false

    private static let fade = 0.12

    var body: some View {
        if reduceMotion {
            Text(Self.render(target))
                .onChange(of: target) { onGrow() }
                .onAppear { if done { onCaughtUp() } }
                .onChange(of: done) { if done { onCaughtUp() } }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reveals.isEmpty)) { tl in
                Text(styled(at: tl.date))
            }
            .onAppear { latest = target; finished = done }
            .onChange(of: target) { latest = target }
            .onChange(of: done) { finished = done }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 45_000_000)
                    step()
                }
            }
        }
    }

    /// ينسّق النص (روابط/عريض/مائل) بنفس قواعد الرسالة النهائية
    static func render(_ s: String) -> AttributedString {
        let clean = SafeMarkdown.clean(s)
        return (try? AttributedString(markdown: clean, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(clean)
    }

    private func styled(at now: Date) -> AttributedString {
        let chars = Array(target)
        let n = min(shown, chars.count)
        var out = Self.render(String(chars[0..<n]))
        let total = out.characters.count
        let live = reveals.filter { now.timeIntervalSince($0.time) < Self.fade && $0.at < n }
        for (k, r) in live.enumerated() {
            // بداية المقطع بعد التنسيق = طول تنسيق النص قبله
            let start = min(total, Self.render(String(chars[0..<r.at])).characters.count)
            let endRaw = k + 1 < live.count ? live[k + 1].at : n
            let end = min(total, k + 1 < live.count ? Self.render(String(chars[0..<endRaw])).characters.count : total)
            guard start < end else { continue }
            let a = out.characters.index(out.characters.startIndex, offsetBy: start)
            let b = out.characters.index(out.characters.startIndex, offsetBy: end)
            let x = max(0, min(1, now.timeIntervalSince(r.time) / Self.fade))
            out[a..<b].foregroundColor = Color.primary.opacity(x * (2 - x))   // ease-out
        }
        return out
    }

    /// يطلع كلمة أو أكثر حسب التراكم: يمشي بإيقاع ثابت وما يتأخر كثير عن النموذج
    private func step() {
        let chars = Array(latest)
        let now = Date()
        if chars.count != lastLen { lastLen = chars.count; lastGrowth = now }
        if shown > chars.count { shown = chars.count; reveals = [] }
        reveals.removeAll { now.timeIntervalSince($0.time) >= Self.fade }
        let backlog = chars.count - shown
        guard backlog > 0 else {
            if finished, !reported, reveals.isEmpty { reported = true; onCaughtUp() }
            return
        }
        let words = backlog > 600 ? 8 : backlog > 300 ? 4 : backlog > 120 ? 2 : 1
        var i = shown
        var released = 0
        while released < words, i < chars.count {
            var j = i
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            while j < chars.count, !chars[j].isWhitespace { j += 1 }
            // آخر كلمة للحين تنكتب: ننتظرها إلا لو النموذج وقف شوي
            if j == chars.count, !finished, now.timeIntervalSince(lastGrowth) < 0.35 { break }
            i = j
            released += 1
        }
        guard i > shown else { return }
        reveals.append(Reveal(at: shown, time: now))
        shown = i
        onGrow()
    }
}
