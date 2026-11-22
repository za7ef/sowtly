import Foundation
import SwiftUI

/// يتابع تنزيل وتحميل النماذج.
@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    enum Phase: Equatable {
        /// loading = ينزل (مع النسبة)، preparing = يجهّز النموذج في الذاكرة.
        case idle, loading(Double), preparing, ready, failed(String)
        var isReady: Bool { self == .ready }
        var isBusy: Bool { if case .loading = self { return true }; return self == .preparing }
        var progress: Double? { if case .loading(let p) = self { return p }; return nil }
    }

    @Published var llm: Phase = .idle
    @Published var stt: Phase = .idle
    @Published var voiceReady = false
    /// النماذج اللي نزلت كاملة.
    @Published var downloaded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "downloadedLLMs") ?? [])
    /// النموذج اللي ينزل الحين.
    @Published var downloadingID: String? { didSet { refreshDownloadFlag() } }

    /// فيه تنزيل شغال (نموذج لغوي أو سمع أو نماء): مسح الكاش ما يلمس الملفات المؤقتة.
    func refreshDownloadFlag() {
        let active = downloadingID != nil || NamaaVoice.shared.isBusy || AudarVoice.shared.isBusy
        if Storage.downloadActive && !active {
            // خلص تنزيل: نتأكد ملفاته برا النسخ الاحتياطي
            Task.detached(priority: .utility) { Storage.excludeModelsFromBackup() }
        }
        Storage.downloadActive = active
    }

    private var llmTask: Task<Void, Never>?
    private var sttTask: Task<Void, Never>?
    private var llmToken = 0
    private var sttToken = 0

    var allReady: Bool { callMissing == nil }

    /// نموذج المحادثة للمكالمة: محمّل على كرت الشاشة، أو سحابي مسموح بالمكالمات
    var callLLMReady: Bool {
        if CloudLLM.active != nil && CloudLLM.useInCalls { return true }
        return llm.isReady
    }

    /// وش ناقص عشان تبدأ المكالمة، باسمه والسبب (nil = جاهز)
    var callMissing: String? {
        if !callLLMReady {
            if llm.isBusy { return L("ما زال نموذج المحادثة قيد التحميل، لحظات.") }
            if case .failed(let m) = llm { return L("تعذّر تشغيل نموذج المحادثة: %@", m) }
            if !downloaded.contains(AppSettings.shared.llmID) {
                return L("نموذج المحادثة (%@) غير محمَّل. حمِّله من الإعدادات ← النماذج.", AppSettings.shared.llm.title)
            }
            return L("نموذج المحادثة غير جاهز. افتح الدردشة أو حاول مرة أخرى.")
        }
        if !stt.isReady {
            if stt.isBusy { return L("ما زال التعرّف على الكلام قيد التجهيز، لحظات.") }
            if case .failed(let m) = stt { return L("تعذّر تشغيل التعرّف على الكلام: %@", m) }
            return L("التعرّف على الكلام غير جاهز، حاول مرة أخرى.")
        }
        return nil
    }

    /// عند فتح التطبيق: نشغّل بس النماذج اللي نزلت قبل. ما ننزّل شي تلقائيًا.
    /// النماذج تتحمل وحدة وحدة عشان ما ترتفع الذاكرة مرة وحدة. الصوت يتحمل وقت الحاجة بس.
    func loadAll() {
        Task.detached(priority: .utility) { Storage.excludeModelsFromBackup() }
        Task {
            // ما نحمّل MLX عند التشغيل لو: التطبيق مو قدّام (كرت الشاشة ممنوع بالخلفية)، أو فيه نموذج سحابي مفعّل (ما نحمّل شي ثقيل).
            // كرت الشاشة يتحمّل لاحقًا لما تختاره أو ترجع للمحلي.
            let skip: String? = !AppPhase.active ? "app not active"
                : CloudLLM.active != nil ? "cloud active" : nil
            if let skip {
                slog("llm: launch preload skipped (\(skip))")
            } else if llm == .idle, downloaded.contains(AppSettings.shared.llmID) {
                await activate(AppSettings.shared.llm).value
            }
            if stt == .idle { await loadSTT().value }
        }
    }

    func loadLLM() { activate(AppSettings.shared.llm) }

    /// يفك النماذج من الذاكرة لما التطبيق يطول بالخلفية (يرجع يحملها لما ترجع).
    func unloadForBackground() async {
        // ما نفك شي وفيه مكالمة أو رد أو تنزيل شغال
        guard !AudioIO.shared.ownedByCall, !ChatStore.shared.isGenerating, downloadingID == nil,
              !NamaaVoice.shared.isBusy, !AudarVoice.shared.isBusy else { return }
        llmTask?.cancel()
        llmToken += 1
        await LLMService.shared.unload()
        SpeechSynth.shared.unload()
        NamaaEngine.shared.unload()
        llm = .idle
        voiceReady = false
        slog("background: models unloaded footprint=\(RAM.footprintMB)MB")
    }

    /// يفك النموذج اللغوي قبل رسم صورة محلية (Stable Diffusion يحتاج ~2GB). يرجع هل كان محمّل.
    func unloadForImage() async -> Bool {
        let loaded = await LLMService.shared.isReady
        let had = loaded || llm == .ready
        llmTask?.cancel()
        llmToken += 1
        await LLMService.shared.unload()
        llm = .idle
        slog("image: llm unloaded (had=\(had)) footprint=\(RAM.footprintMB)MB avail=\(RAM.availableMB)MB")
        return had
    }

    private func markDownloaded(_ id: String) {
        guard !downloaded.contains(id) else { return }
        downloaded.insert(id)
        UserDefaults.standard.set(Array(downloaded), forKey: "downloadedLLMs")
    }

    /// ينزّل النموذج (إذا ما نزل) ويشغّله.
    @discardableResult
    func activate(_ option: LLMOption) -> Task<Void, Never> {
        AppSettings.shared.llmID = option.id
        llmTask?.cancel()
        llmToken += 1
        let token = llmToken
        llm = downloaded.contains(option.id) ? .preparing : .loading(0)
        downloadingID = downloaded.contains(option.id) ? nil : option.id
        // يحتاج إنترنت إذا ما فيه نسخة كاملة على الجهاز (التحميل المحلي ما يتصل أبدًا)
        let needsNet = Storage.llmLocalSnapshot(option.id) == nil
        slog.stage("llm:load \(option.id.split(separator: "/").last ?? "")")
        slog("llm: activate \(option.id) local=\(!needsNet)")
        llmTask = Task {
            defer { if llmToken == token { slog.stage("idle") } }
            if needsNet, let why = Storage.spaceProblem(forGB: option.sizeGB) {
                guard llmToken == token else { return }
                downloadingID = nil
                llm = .failed(why)
                return
            }
            if needsNet {
                let ok = await NetworkGate.shared.permit(L("تحميل النموذج"))
                // انضغط إيقاف أو تغيّر النموذج وقت التنبيه؟ نوقف
                guard llmToken == token, !Task.isCancelled else { return }
                guard ok else {
                    downloadingID = nil
                    llm = .failed(L("الإنترنت مغلق، لذلك لم يُحمَّل النموذج."))
                    return
                }
            }
            do {
                try await withTimeout(seconds: 1_800, what: L("تحميل النموذج")) {
                    try await LLMService.shared.load(option) { p in
                        Task { @MainActor in
                            let mm = ModelManager.shared
                            guard mm.llmToken == token else { return }
                            if p >= 0.999 {
                                mm.markDownloaded(option.id)
                                mm.downloadingID = nil
                                mm.llm = .preparing
                            } else if mm.llm != .preparing {
                                mm.llm = .loading(p)
                            }
                        }
                    }
                }
                guard llmToken == token else { return }
                markDownloaded(option.id)
                downloadingID = nil
                llm = .ready
            } catch {
                guard llmToken == token else { return }
                downloadingID = nil
                llm = (Task.isCancelled || error is LoadInterrupted) ? .idle : .failed(SawtError.friendly(error).localizedDescription)
                slog("llm load failed: \(error)")
            }
        }
        return llmTask!
    }

    /// قبل المكالمة: نرجع للوضع النصي الأخف إذا كان محمّل بوضع النظر.
    func ensureTextMode() async {
        guard await LLMService.shared.visionLoaded else { return }
        // إذا الذاكرة تكفي نخليه بوضع النظر: يرد على النص عادي، ونتجنب إعادة تحميل ~3ث كل مرة تشغّل الكاميرا
        if RAM.availableMB > 3000 { slog("call: keeping vision model (avail=\(RAM.availableMB)MB)"); return }
        llmToken += 1
        let token = llmToken
        llm = .preparing
        slog("call: switching vision → text model")
        try? await LLMService.shared.load(AppSettings.shared.llm) { _ in }
        if llmToken == token { llm = .ready }
    }

    /// يعيد تحميل النموذج الحالي بوضع النظر (مرة وحدة) إذا يدعم الصور.
    /// يُستدعى أول ما تنضاف صورة (قبل الإرسال) عشان التحميل يبدأ بدري؛ الطلبات المتزامنة تشترك بنفس المهمة.
    private var visionTask: Task<Bool, Never>?
    func ensureVision(cloudOK: Bool = true) async -> Bool {
        // النموذج السحابي يشوف الصور بنفسه: ما نحمّل نموذج النظر المحلي
        if cloudOK, CloudLLM.active != nil { return true }
        if let t = visionTask { return await t.value }
        let t = Task { await self.loadVision() }
        visionTask = t
        let ok = await t.value
        visionTask = nil
        return ok
    }

    func preloadVisionIfUseful() {
        guard AppSettings.shared.llm.vision, !ChatStore.shared.isGenerating, llm.isReady else { return }
        Task { _ = await ensureVision() }
    }

    private func loadVision() async -> Bool {
        let option = AppSettings.shared.llm
        guard option.vision else { return false }
        if await LLMService.shared.visionLoaded { return true }
        llmToken += 1
        let token = llmToken
        llm = .preparing
        do {
            try await LLMService.shared.load(option, vision: true) { _ in }
            if llmToken == token { llm = .ready }
            return true
        } catch {
            slog("vision load failed: \(error)")
            // نرجع للوضع النصي
            try? await LLMService.shared.load(option) { _ in }
            if llmToken == token { llm = .ready }
            return false
        }
    }

    /// يوقف التنزيل مؤقتًا. الملفات اللي نزلت تبقى، والباقي يكمل لما تضغط تنزيل مرة ثانية.
    func pauseDownload() {
        llmTask?.cancel()
        llmTask = nil
        llmToken += 1
        downloadingID = nil
        llm = .idle
    }

    /// يحذف ملفات النموذج من الجهاز.
    func delete(_ option: LLMOption) {
        if AppSettings.shared.llmID == option.id {
            llmTask?.cancel()
            llmToken += 1
            llm = .idle
            Task { await LLMService.shared.unload() }
        }
        Storage.deleteLLM(option.id)
        downloaded.remove(option.id)
        UserDefaults.standard.set(Array(downloaded), forKey: "downloadedLLMs")
    }

    /// يحذف مجلد معيّن من شاشة الملفات.
    func deleteFolder(_ f: Storage.ModelFolder) {
        switch f.kind {
        case .llm(let repo):
            if let opt = Catalog.llms.first(where: { $0.id == repo }) { delete(opt) } else { Storage.remove(f) }
        }
        Storage.remove(f)
    }

    /// المجلدات الناقصة أو المهجورة (لتنبيه التنظيف عند الفتح).
    func orphanFolders() async -> [Storage.ModelFolder] {
        let d = downloaded
        let busy = downloadingID
        return await Task.detached(priority: .utility) {
            Storage.modelFolders(downloaded: d).filter { f in
                if case .llm(let r) = f.kind, r == busy { return false }
                return f.isOrphan && f.bytes > 1_000_000 && !Storage.isDismissed(f)
            }
        }.value
    }

    func deleteAllModels() {
        llmTask?.cancel(); llmToken += 1; llm = .idle; downloadingID = nil
        Task { await LLMService.shared.unload() }
        Storage.deleteAllModels()
        downloaded.removeAll()
        UserDefaults.standard.set([String](), forKey: "downloadedLLMs")
    }

    @discardableResult
    func loadSTT() -> Task<Void, Never> {
        sttTask?.cancel()
        sttToken += 1
        let token = sttToken
        stt = .preparing
        sttTask = Task {
            do {
                try await SpeechRecognizer.shared.load()
                guard sttToken == token else { return }
                stt = .ready
            } catch {
                guard sttToken == token else { return }
                stt = .failed(SawtError.friendly(error).localizedDescription)
                slog("stt load failed: \(error)")
            }
        }
        return sttTask!
    }

    /// يجهّز الصوت المختار (وقت المكالمة أو التجربة). يرجع بعد ما يجهز.
    func prepareVoice() async {
        let v = AppSettings.shared.voice
        await Task.detached(priority: .userInitiated) {
            SpeechSynth.shared.prepare(v)
        }.value
        voiceReady = true
    }

    /// يغيّر الصوت: نفك الصوت القديم من الذاكرة، والجديد يتحمل وقت الحاجة.
    func voiceIdle() { voiceReady = false }

    func voiceChanged() {
        voiceReady = false
        SpeechSynth.shared.unload()
    }
}

/// يدوّر على ملفات نموذج Hugging Face في مجلدات التطبيق.
enum ModelFiles {
    static var roots: [URL] {
        let fm = FileManager.default
        var r: [URL] = []
        for d in [FileManager.SearchPathDirectory.cachesDirectory, .documentDirectory, .applicationSupportDirectory] {
            r += fm.urls(for: d, in: .userDomainMask)
        }
        r.append(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache"))
        return r
    }

    static func matches(repo: String) -> [URL] {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return [] }
        let hubName = "models--\(parts[0])--\(parts[1])"
        var found: [URL] = []
        let fm = FileManager.default
        for root in roots {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en {
                if en.level > 6 { en.skipDescendants(); continue }
                let name = url.lastPathComponent
                if name == hubName || (name == parts[1] && url.deletingLastPathComponent().lastPathComponent == parts[0]) {
                    found.append(url)
                    en.skipDescendants()
                }
            }
        }
        return found
    }

    static func remove(repo: String) {
        for u in matches(repo: repo) { try? FileManager.default.removeItem(at: u) }
    }
}

/// يوقف العملية إذا طوّلت أكثر من اللازم.
func withTimeout<T: Sendable>(seconds: Double, what: String, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw SawtError.timeout(what)
        }
        guard let first = try await group.next() else { throw SawtError.timeout(what) }
        group.cancelAll()
        return first
    }
}
