import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import CoreImage
import Tokenizers

/// النموذج اللغوي المحلي (MLX).
actor LLMService {
    static let shared = LLMService()

    private var container: ModelContainer?
    private var loadedID: String?
    /// اسم النموذج اللي ولّد آخر رد (يظهر فوق الرد)
    nonisolated(unsafe) var lastModelName = ""

    /// اسم مقروء لمعرّف نموذج سحابي: gemini-3.5-flash → Gemini 3.5 Flash
    static func prettyModel(_ id: String) -> String {
        let last = id.split(separator: "/").last.map(String.init) ?? id
        let base = last.split(separator: ":").first.map(String.init) ?? last
        return base.split(separator: "-").map { w -> String in
            let s = String(w)
            return s.first?.isLetter == true ? s.prefix(1).uppercased() + s.dropFirst() : s
        }.joined(separator: " ")
    }
    /// جلسة المكالمة: نحتفظ فيها بين الأدوار عشان ما نعيد معالجة التعليمات والمحادثة كل مرة (كاش KV).
    private var callSession: ChatSession?

    func resetCallSession() { callSession = nil; callTurns = 0 }
    private func keepCallSession(_ s: ChatSession?) { callSession = s; callTurns += 1 }
    /// عدد الأدوار في جلسة المكالمة الحالية؛ بعد حد معيّن نبدأ جلسة جديدة بسجل مختصر عشان الكاش ما يكبر بلا حد.
    private var callTurns = 0
    /// فيه جلسة مكالمة بتنعاد استخدامها في الدور الجاي
    var hasCallSession: Bool { callSession != nil && callTurns < 20 }

    var isReady: Bool { container != nil }
    /// النموذج محمّل بوضع النظر (يقبل صور)
    private(set) var visionLoaded = false

    /// يزيد مع كل تفريغ: تحميل بدأ قبله ما يركّب نموذجه بعده (سباق التحميل مع الخلفية)
    private var loadGen = 0

    func unload() {
        loadGen += 1
        container = nil
        loadedID = nil
        warmedID = nil
        callSession = nil
        callTurns = 0
        MLX.Memory.clearCache()
    }

    private var warmedID: String?

    /// تسخين: نولّد كلمة وحدة عشان أول رد في المكالمة يكون أسرع (تجهيز كرت الشاشة والكاش).
    /// مصنّف سريع: هل الرسالة تحتاج تفكير عميق؟ (رموز قليلة جدًا، بدون جلسة)
    func classifyNeedsThinking(_ text: String) async -> Bool {
        let sys = """
        صنّف رسالة المستخدم: إذا تحتاج تفكير أو استنتاج قبل الجواب (لغز، مسألة، منطق، حساب، تخطيط، مقارنة، شرح سبب، برمجة) اكتب THINK.         إذا سؤال بسيط أو معلومة سريعة أو سوالف اكتب NO. اكتب كلمة وحدة بس.
        """
        guard let s = try? stream(system: sys, history: [], user: String(text.prefix(500)), maxTokens: 3) else { return false }
        var out = ""
        do { for try await c in s { out += c } } catch { return false }
        return out.uppercased().contains("THINK")
    }

    /// مصنّف النية: IMAGE (رسم/توليد صورة) أو CHAT
    enum Intent: Sendable { case image, chat }
    func classifyIntent(_ text: String) async -> Intent {
        let sys = """
        صنّف رسالة المستخدم بكلمة وحدة: IMAGE إذا يطلب ترسم أو تولّد أو تصمم صورة جديدة. \
        CHAT إذا سؤال أو سوالف أو طلب معلومة أو كتابة نص في المحادثة. كلمة وحدة بس.
        """
        guard let s = try? stream(system: sys, history: [], user: String(text.prefix(400)), maxTokens: 3) else { return .chat }
        var out = ""
        do { for try await c in s { out += c } } catch { return .chat }
        return out.uppercased().contains("IMAGE") ? .image : .chat
    }

    /// مصنّف سريع: هل السؤال يحتاج بحث في الويب (معلومة حديثة أو متغيرة)؟
    func classifyNeedsSearch(_ text: String) async -> Bool {
        let sys = """
        هل يحتاج سؤال المستخدم معلومات حديثة أو متغيرة من الإنترنت (أخبار، أسعار، أحداث جارية، مواعيد، نتائج، منتجات جديدة، شيء بعد ٢٠٢٤)؟         إذا نعم اكتب SEARCH، وإذا يكفيه العلم العام اكتب NO. كلمة وحدة بس.
        """
        guard let s = try? stream(system: sys, history: [], user: String(text.prefix(500)), maxTokens: 3) else { return false }
        var out = ""
        do { for try await c in s { out += c } } catch { return false }
        return out.uppercased().contains("SEARCH")
    }

    func warmup(system: String) async {
        if CloudLLM.active != nil { return }
        guard let id = loadedID, warmedID != id else { return }
        warmedID = id
        let t0 = Date()
        do {
            let s = try stream(system: system, history: [], user: "هلا", maxTokens: 1)
            for try await _ in s {}
            slog("llm: warmup \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        } catch {
            slog("llm: warmup failed \(error)")
        }
    }

    private var lastWarm: (device: String, at: Date)?

    /// تسخين صامت: يحمّل الأوزان ويولّد رمز واحد على تعليمات المحادثة
    /// (يجمّع كيرنلات Metal ويعبّي الكاش)
    func warmUp(reason: String) async {
        if CloudLLM.active != nil { return }   // السحابي ما يحتاج تسخين
        let dev = "gpu"
        if let w = lastWarm, w.device == dev, Date().timeIntervalSince(w.at) < 120 { return }
        if !AppPhase.active { return }   // Metal ممنوع في الخلفية
        let sys = await MainActor.run { AppSettings.shared.systemPrompt(chat: true, query: "", memory: false) }
        let t0 = Date()
        guard container != nil else { slog("llm: warm-up skipped (not loaded) \(reason)"); return }
        do {
            let st = try stream(system: sys, history: [], user: ".", maxTokens: 1)
            for try await _ in st {}
        } catch { slog("llm: warm-up failed \(error)"); return }
        lastWarm = (dev, Date())
        slog("llm: warm-up \(dev) (\(reason)) \(Int(Date().timeIntervalSince(t0) * 1000))ms")
    }

    /// يتأكد إن نسخة MLX هذي محمّلة (نصي أو نظر، أيهما موجود) — للمكالمة لما تختار كرت الشاشة والتطبيق على المعالج
    func ensureLoaded(_ option: LLMOption) async throws {
        if loadedID == option.id, container != nil { return }
        try await load(option) { _ in }
    }

    /// يُستدعى لما النظام يحذّر من الذاكرة.
    func trim() { MLX.Memory.clearCache() }

    func load(_ option: LLMOption, vision: Bool = false, progress: @escaping @Sendable (Double) -> Void) async throws {
        if loadedID == option.id, container != nil, visionLoaded == vision { return }
        // كرت الشاشة ممنوع في الخلفية: ما نبدأ تحميل MLX والتطبيق مو قدّام
        guard AppPhase.active else { slog("llm: load refused (background)"); throw LoadInterrupted() }
        loadGen += 1
        let gen = loadGen
        container = nil
        visionLoaded = false
        MLX.Memory.clearCache()
        // كاش صغير لكرت الشاشة عشان ما تتكدس الذاكرة بين الردود
        MLX.Memory.cacheLimit = 32 * 1024 * 1024
        slog("llm: loading \(option.id)")
        var cfg = option.configuration
        // نازل كامل؟ نحمّله من المجلد مباشرة: ولا طلب واحد للإنترنت (حتى فحص النسخة)
        if let local = Storage.llmLocalSnapshot(option.id) {
            cfg.id = .directory(local)
            slog("llm: loading offline from local snapshot")
        }
        // نحدد المصنع بنفسنا: النصي أخف على الذاكرة، والنظر بس لما يحتاجه المستخدم
        let c: ModelContainer
        if vision {
            c = try await VLMModelFactory.shared.loadContainer(
                from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), configuration: cfg,
                progressHandler: { p in progress(p.fractionCompleted) })
        } else {
            c = try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), configuration: cfg,
                progressHandler: { p in progress(p.fractionCompleted) })
        }
        // انفك النموذج أو راح التطبيق للخلفية وقت التحميل: نرمي النتيجة بدل ما نركّبها
        guard gen == loadGen, AppPhase.active else {
            slog("llm: load discarded (unloaded or backgrounded meanwhile)")
            MLX.Memory.clearCache()
            throw LoadInterrupted()
        }
        container = c
        visionLoaded = vision
        slog("llm: loaded vision=\(vision) avail=\(RAM.availableMB)MB")
        loadedID = option.id
        progress(1)
        Task.detached(priority: .utility) { await LLMService.shared.warmUp(reason: "loaded") }
    }

    /// يرجع تدفق نص الرد. السجل يحتوي الرسائل السابقة بدون الرسالة الحالية.
    /// إذا رفض قالب المحادثة (بعض النماذج ما تقبل رسالة النظام)، نعيد المحاولة بدمج التعليمات في رسالة المستخدم.
    func stream(system: String, history: [Chat.Message], user: String, maxTokens: Int = 400, reuse: Bool = false,
                images: [URL] = [], think: Bool = false,
                onThink: (@Sendable (String) -> Void)? = nil) throws -> AsyncThrowingStream<String, Error> {
        // نموذج سحابي مفعّل من صفحة النماذج (اختياري)
        if let c = CloudLLM.forThisReply(forcedDevice: ComputeMode.forced) {
            lastModelName = Self.prettyModel(c.model)
            slog("llm: cloud → \(c.rawValue):\(c.model) images=\(images.count)")
            callSession = nil; callTurns = 0
            return CloudLLM.stream(c, system: system, history: history, user: user, maxTokens: maxTokens, images: images)
        }
        guard let container else { throw SawtError.notReady(L("النموذج اللغوي")) }
        let lid = loadedID ?? ""
        lastModelName = (Catalog.builtInLLMs + Catalog.customLLMs).first { $0.id == lid }?.title
            ?? (lid.split(separator: "/").last.map(String.init) ?? "")
        var params = GenerateParameters()
        params.maxTokens = ThermalWatch.isHot ? min(200, maxTokens) : maxTokens
        // كاش مضغوط 8 بت بعد أول 1024 رمز (يوفر تقريبًا نص ذاكرة الكاش). ما نستخدم maxKVSize لأن
        // الكاش الدوّار ما يقبل الضغط ويحذف التعليمات؛ طول السياق محدود من عندنا (ميزانية السجل وإعادة الجلسة).
        params.maxKVSize = nil
        params.kvBits = 8
        params.quantizedKVStart = 1024
        params.temperature = 0.7
        params.topP = 0.9
        // وضع التفكير موجود بس في عائلة Qwen3 (ومنها Qwen3.5)، مو Qwen2.5
        let isQwen3 = (loadedID ?? "").lowercased().contains("qwen3")
        // تفكير عميق: Qwen3 يفكر بنفسه؛ الباقي نطلب منه يفكر داخل <think>. بدونه نقفل تفكير Qwen عشان السرعة.
        let reasoning = "\n\nقبل الجواب فكّر خطوة بخطوة بينك وبين نفسك داخل <think> و</think>، بعدين اكتب الجواب النهائي بعدها مباشرة."
        let sys = isQwen3 ? (think ? system : system + "\n/no_think") : (think ? system + reasoning : system)
        let ctx: [String: any Sendable]? = isQwen3 ? ["enable_thinking": think] : nil

        // المحاولة الأولى: رسالة نظام عادية. الثانية: بدون رسالة نظام وبتناوب صارم.
        var attempts: [() -> (ChatSession, String)] = [
            {
                (ChatSession(container, instructions: sys, history: history, generateParameters: params,
                             additionalContext: ctx), user)
            },
            {
                let merged = Self.strictAlternation(history)
                let first = merged.isEmpty
                    ? "تعليمات: \(sys)\n\n\(user)"
                    : user
                var hist = merged
                if !hist.isEmpty, case .user = hist[0].role {
                    hist[0] = .user("تعليمات: \(sys)\n\n" + hist[0].content)
                }
                return (ChatSession(container, instructions: nil, history: hist, generateParameters: params,
                                    additionalContext: ctx), first)
            },
        ]

        if reuse, callTurns >= 20 {
            slog("llm: call session long (\(callTurns) turns) → fresh session with trimmed history")
            callSession = nil; callTurns = 0
        }
        if reuse, let existing = callSession {
            existing.generateParameters = params
            attempts.insert({ (existing, user) }, at: 0)
            slog("llm: reusing call session (kv cache)")
        }
        let hadSession = callSession != nil
        callSession = nil   // ترجع بس إذا خلص الدور بنجاح
        // جلسة جديدة (أو انفقدت بعد خطأ/مقاطعة) = العداد يبدأ من الصفر
        if !reuse || !hadSession { callTurns = 0 }

        return AsyncThrowingStream { cont in
            // أولوية userInitiated (مو background) عشان المعالج يشتغل بسرعة في الخلفية والمايك مفتوح
            let task = Task(priority: .userInitiated) {
                if !AppPhase.active {
                    // كرت الشاشة ممنوع في الخلفية: نوقف بدل ما يطيح التطبيق
                    slog("llm: paused (background, gpu-only)")
                    cont.finish(throwing: BackgroundPause())
                    return
                }
                var anyYielded = false
                var round = 0
                while true {
                    round += 1
                    var interrupted = false
                    var lastError: Error?
                    var finished = false
                    let t0 = Date()
                    var chunks = 0
                    // أخطاء MLX (مثل عملية ما لها نسخة على المعالج) ترجع خطأ بدل ما تطيّح التطبيق
                    let mlxErr = MLXErrBox()
                    await withErrorHandler({ m in mlxErr.set(m) }) {
                    await Device.withDefaultDevice(Device.gpu) {
                for (i, make) in attempts.enumerated() {
                    let (session, prompt) = make()
                    var yielded = false
                    // بعض قوالب Qwen تفتح <think> بنفسها في البرومبت: نعتبر البداية تفكير من أول حرف (بدون وميض)
                    var inThink = think && isQwen3
                    var pendingTag = ""
                    do {
                        let imgs: [UserInput.Image] = images.compactMap { u in CIImage(contentsOf: u).map { .ciImage($0) } }
                        for try await chunk in session.streamResponse(to: prompt, images: imgs) {
                            if Task.isCancelled { break }
                            // التطبيق راح للخلفية وإحنا على كرت الشاشة: نوقف قبل ما يرفض النظام الشغل
                            if !AppPhase.active { interrupted = true; break }
                            if mlxErr.message != nil { break }
                            chunks += 1
                            var text = pendingTag + chunk
                            pendingTag = ""
                            var visible = ""
                            while !text.isEmpty {
                                if inThink {
                                    if let r = text.range(of: "<think>") { text.removeSubrange(r) }
                                    if let r = text.range(of: "</think>") {
                                        onThink?(String(text[..<r.lowerBound]))
                                        text = String(text[r.upperBound...]); inThink = false
                                    } else if let lt = text.lastIndex(of: "<"), text[lt...].count < 9 {
                                        onThink?(String(text[..<lt])); pendingTag = String(text[lt...]); text = ""; break
                                    } else { onThink?(text); text = ""; break }
                                } else if let r = text.range(of: "<think>") {
                                    visible += text[..<r.lowerBound]
                                    text = String(text[r.upperBound...]); inThink = true
                                } else if let lt = text.lastIndex(of: "<"), text[lt...].count < 8 {
                                    visible += text[..<lt]; pendingTag = String(text[lt...]); text = ""
                                } else {
                                    visible += text; text = ""
                                }
                            }
                            if !visible.isEmpty { yielded = true; anyYielded = true; cont.yield(visible) }
                            else if inThink { cont.yield("") }   // نبّه الواجهة تحدّث التفكير
                        }
                        if interrupted { return }
                        if !pendingTag.isEmpty, !inThink { cont.yield(pendingTag) }
                        withExtendedLifetime(session) {}
                        // نحتفظ بالجلسة بس إذا الرد كمل (لو انقطع، كاشها مو مضمون)
                        if reuse, !Task.isCancelled { await self.keepCallSession(session) }
                        finished = true
                        return
                    } catch {
                        lastError = error
                        if yielded || Task.isCancelled || i == attempts.count - 1 { break }
                    }
                }
                    }
                    }
                    let dt = Date().timeIntervalSince(t0)
                    if let m = mlxErr.message {
                        slog("llm: mlx error: \(m)")
                        MLX.Memory.clearCache()
                        cont.finish(throwing: MLXRunError(message: m))
                        return
                    }
                    if chunks > 1 {
                        slog("llm: gpu \(chunks) tok in \(Int(dt * 1000))ms ≈ \(String(format: "%.1f", Double(chunks) / max(dt, 0.001))) tok/s")
                    }
                    MLX.Memory.clearCache()
                    if finished { cont.finish(); return }
                    if interrupted {
                        slog("llm: interrupted (background)")
                        cont.finish(throwing: BackgroundPause())
                        return
                    }
                    cont.finish(throwing: SawtError.friendly(lastError))
                    return
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// يدمج الرسائل المتتالية من نفس الطرف ويبدأ بالمستخدم.
    static func strictAlternation(_ msgs: [Chat.Message]) -> [Chat.Message] {
        var out: [Chat.Message] = []
        for m in msgs {
            switch m.role {
            case .user, .assistant:
                if let last = out.last, last.role == m.role {
                    out[out.count - 1] = last.role == .user ? .user(last.content + "\n" + m.content)
                                                           : .assistant(last.content + "\n" + m.content)
                } else {
                    out.append(m)
                }
            default: continue
            }
        }
        if let f = out.first, f.role == .assistant { out.removeFirst() }
        if let l = out.last, l.role == .user { out.removeLast() }
        return out
    }
}


/// التحميل انقطع لأن التطبيق راح للخلفية أو انفك النموذج وقتها (يعاد التحميل لما يرجع)
struct LoadInterrupted: Error {}

/// النموذج يشتغل على كرت الشاشة بس (MLX). Metal ممنوع في الخلفية، فالرد ينتظر رجوع التطبيق.
enum ComputeMode {
    /// باقي للتوافق مع السحابي (forcedDevice)؛ دايمًا nil أو "gpu"
    @TaskLocal static var forced: String?
    static let current = "gpu"
    /// ترحيل: نشيل إعداد المعالج القديم لو موجود
    static func migrate() {
        if UserDefaults.standard.object(forKey: "llmDevice") != nil {
            UserDefaults.standard.removeObject(forKey: "llmDevice")
            slog("migrate: llmDevice removed (gpu only)")
        }
    }
    /// nil = ممنوع الحين (التطبيق في الخلفية)
    static func device(for mode: String) -> String? { AppPhase.active ? "gpu" : nil }
}

/// حالة التطبيق (قدّام/خلفية) يقراها أي خيط
enum AppPhase {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _active = true
    static var active: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _active }
        set { lock.lock(); _active = newValue; lock.unlock() }
    }
}

struct BackgroundPause: LocalizedError {
    var errorDescription: String? { L("افتح التطبيق للمتابعة") }
}

final class MLXErrBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _m: String?
    var message: String? { lock.lock(); defer { lock.unlock() }; return _m }
    func set(_ m: String) { lock.lock(); if _m == nil { _m = m }; lock.unlock() }
}

struct MLXRunError: LocalizedError {
    var message: String
    var cpu: Bool = false
    var errorDescription: String? {
        cpu ? L("لم يعمل النموذج على المعالج: %@. أعد «تشغيل النموذج» إلى معالج الرسوميات.", String(message.prefix(160)))
            : L("حدث خطأ في النموذج: %@", String(message.prefix(160)))
    }
}
