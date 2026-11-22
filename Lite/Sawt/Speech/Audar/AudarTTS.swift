import Foundation
import MLX
import MLXNN
import Tokenizers

/// أصوات «أودار» (Audar-TTS-V1-Flash من AudarAI، رخصة AudarAI Open License v1.0).
/// صوت لايت: نموذج لغوي صغير (Qwen2، ‏553M) يكتب رموز صوت NeuCodec (50 رمز/ث) يعمل على MLX (كرت الشاشة، والمعالج في الخلفية)،
/// ومفكك NeuCodec (Apache-2.0) على MLX يحوّلها لصوت 24kHz. لا يوجد llama.cpp في هذه النسخة.
/// الأوزان الأصلية (bf16 بصيغة safetensors من مجلد transformers في المستودع الرسمي) تُحوَّل على الجهاز مرة واحدة إلى 6 بت.
/// الأصوات الستة: مراجع جاهزة (نص + رموز) رمّزناها مسبقًا من عينات النموذج الرسمية، فما نحتاج مرمّز الصوت الثقيل على الجوال.
@MainActor
final class AudarVoice: ObservableObject {
    static let shared = AudarVoice()

    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)
    }

    @Published var state: State = .notDownloaded {
        didSet { ModelManager.shared.refreshDownloadFlag() }
    }
    var isBusy: Bool { if case .downloading = state { return true }; return false }
    @Published var testing = false
    @Published var lastTest: String?

    /// النموذج من مستودعه الرسمي، مثبّت على نسخة محددة
    static let revision = "addf2d80538edab4de2103843678825bc11ddce1"
    static let releaseBase = "https://github.com/za7ef/sawt-releases/releases/download/voices/"
    static let hfBase = "https://huggingface.co/audarai/Audar-TTS-V1-Flash/resolve/\(revision)/transformers/"
    /// كل ملف: روابط أجزائه بالترتيب (تنضم في ملف واحد) + اسمه + حجمه
    static let files: [(urls: [String], name: String, bytes: Int64)] = [
        // أوزان النموذج الأصلية bf16 (تُحذف بعد التحويل إلى 6 بت)
        ([hfBase + "model.safetensors"], "lm-bf16.safetensors", 1_105_889_664),
        ([hfBase + "tokenizer.json"], "tokenizer.json", 24_143_303),
        ([hfBase + "tokenizer_config.json"], "tokenizer_config.json", 12_066_161),
        ([hfBase + "config.json"], "config.json", 1_227),
        // مفكك NeuCodec فقط (من neuphonic/neucodec نسخة a940021، Apache-2.0)، محوّل لـfloat16 وتخطيط MLX.
        // المستودع الأصلي يطلب تسجيل دخول، فننشر المفكك (مع الرخصة والإشعار) في إصدار الأصوات العام، مقسوم 40 جزء.
        ((0 ..< 40).map { releaseBase + String(format: "neucodec-decoder-f16.safetensors.part%02d", $0) },
         "neucodec-decoder-f16.safetensors", 375_295_836),
    ]

    nonisolated static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Audar", isDirectory: true)
    }
    /// النموذج بعد التحويل (6 بت، مجموعات 64)
    nonisolated static var lmURL: URL { dir.appendingPathComponent("audar-lm-q6.safetensors") }
    /// مجلد المُرمّز المخفّف (بدون 66 ألف رمز صوتي مضاف، فالترميز سريع)
    nonisolated static var tokDir: URL { dir.appendingPathComponent("tokenizer", isDirectory: true) }
    nonisolated static var decoderURL: URL { dir.appendingPathComponent("neucodec-decoder-f16.safetensors") }
    nonisolated static var isPrepared: Bool {
        FileManager.default.fileExists(atPath: lmURL.path)
            && FileManager.default.fileExists(atPath: tokDir.appendingPathComponent("tokenizer.json").path)
    }
    nonisolated static var isInstalled: Bool {
        isPrepared && ((try? FileManager.default.attributesOfItem(atPath: decoderURL.path)[.size] as? Int64) ?? 0) == files[4].bytes
    }

    static let testSentence = "أهلًا وسهلًا، كيف حالك اليوم؟ أتمنى أن تكون أمورك بخير وأن يسير عملك على ما يرام."

    private var task: Task<Void, Never>?

    private init() {
        _state = Published(initialValue: AudarVoice.isInstalled ? .ready : .notDownloaded)
    }

    var sizeOnDisk: Int64 { Storage.size(AudarVoice.dir) }

    func download() {
        guard task == nil else { return }
        task = Task {
            if let why = Storage.spaceProblem(forGB: 2.0) { state = .failed(why); task = nil; return }
            guard await NetworkGate.shared.permit(L("تحميل أصوات أودار")) else { task = nil; return }
            do {
                try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
                var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
                var d = Self.dir; try? d.setResourceValues(excluded)
                let total = Self.files.reduce(Int64(0)) { $0 + $1.bytes }
                var done: Int64 = 0
                state = .downloading(0)
                for f in Self.files {
                    // بعد التحويل ما نحتاج الملفات الأصلية مرة ثانية
                    if Self.isPrepared, f.name != "neucodec-decoder-f16.safetensors" { done += f.bytes; continue }
                    let dest = Self.dir.appendingPathComponent(f.name)
                    let have = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
                    if have != f.bytes {
                        try? FileManager.default.removeItem(at: dest)
                        let base = done
                        if f.urls.count == 1 {
                            try await Downloader.fetch(URL(string: f.urls[0])!, to: dest) { got in
                                Task { @MainActor in self.state = .downloading(Double(base + got) / Double(total)) }
                            }
                        } else {
                            // الأجزاء: كل جزء لملف مؤقت ثم يُلصق في آخر الملف
                            FileManager.default.createFile(atPath: dest.path, contents: nil)
                            let out = try FileHandle(forWritingTo: dest)
                            defer { try? out.close() }
                            var partBase = base
                            for u in f.urls {
                                try Task.checkCancellation()
                                let tmp = Self.dir.appendingPathComponent("part.tmp")
                                try? FileManager.default.removeItem(at: tmp)
                                let pb = partBase
                                try await Downloader.fetch(URL(string: u)!, to: tmp) { got in
                                    Task { @MainActor in self.state = .downloading(Double(pb + got) / Double(total)) }
                                }
                                let data = try Data(contentsOf: tmp, options: .alwaysMapped)
                                try out.write(contentsOf: data)
                                partBase += Int64(data.count)
                                try? FileManager.default.removeItem(at: tmp)
                            }
                        }
                        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
                        guard size == f.bytes else {
                            try? FileManager.default.removeItem(at: dest)
                            throw SawtError.failed(L("حجم %1$@ غير متوقع (%2$@)", f.name, String(size)))
                        }
                    }
                    done += f.bytes
                }
                if !Self.isPrepared {
                    state = .downloading(0.99)
                    try await Task.detached(priority: .userInitiated) { try AudarPrep.run() }.value
                }
                state = .ready
                slog("audar: installed \(Storage.format(sizeOnDisk))")
            } catch is CancellationError {
                state = .notDownloaded
            } catch {
                slog("audar: install failed \(error)")
                state = .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = AudarVoice.isInstalled ? .ready : .notDownloaded
    }

    func delete() {
        cancel()
        Task { await AudarEngine.shared.unload() }
        try? FileManager.default.removeItem(at: Self.dir)
        state = .notDownloaded
        lastTest = nil
        if case .audar = AppSettings.shared.voice.kind {
            AppSettings.shared.voiceID = Catalog.voices.first?.id ?? "apple"
        }
    }

    /// يولّد الجملة التجريبية بالصوت المختار (أو أول صوت أودار) ويشغلها، مع الوقت ونسبة الوقت الحقيقي.
    func test() {
        guard !testing else { return }
        testing = true
        lastTest = nil
        let voiceKey: String
        if case .audar(let k) = AppSettings.shared.voice.kind { voiceKey = k } else { voiceKey = AudarRefs.all[0].key }
        Task {
            let r = await AudarEngine.shared.synthesizeTimed(Self.testSentence, voice: voiceKey)
            testing = false
            switch r {
            case .failure(let e):
                lastTest = L("لم ينجح: %@", e.localizedDescription)
            case .success(let out):
                let rtf = out.genSeconds / max(out.audioSeconds, 0.01)
                lastTest = L("التوليد: %1$@ ث (%2$@ رمز/ث) • طول الصوت: %3$@ ث • النسبة: %4$@× (أقل من 1 يعني أسرع من الكلام)",
                             String(format: "%.1f", out.genSeconds), String(format: "%.0f", out.tokensPerSecond),
                             String(format: "%.1f", out.audioSeconds), String(format: "%.2f", rtf))
                if out.loadSeconds > 0.05 {
                    lastTest! += "\n" + L("التحميل إلى الذاكرة أول مرة: %@ ث", String(format: "%.1f", out.loadSeconds))
                }
                Speaker.shared.play(samples: out.samples, sampleRate: 24_000)
            }
        }
    }
}

// MARK: - التحويل على الجهاز (مرة وحدة بعد التنزيل)

/// يحوّل أوزان bf16 إلى 6 بت (مجموعات 64) ويخفّف المُرمّز، ثم يحذف الأصل.
/// لا يُعاد توزيع أي نسخة معدّلة: التحويل يتم على جهاز المستخدم فقط.
enum AudarPrep {
    static let bits = 6, group = 64
    /// الرموز المضافة من هذا الرقم وفوق (رموز الصوت والعلامات) ما يحتاجها ترميز النص
    static let firstExtraToken = 151_665

    static func run() throws {
        let dir = AudarVoice.dir
        try trimTokenizer(dir)
        let raw = dir.appendingPathComponent("lm-bf16.safetensors")
        if !FileManager.default.fileExists(atPath: AudarVoice.lmURL.path) {
            guard FileManager.default.fileExists(atPath: raw.path) else { throw SawtError.failed(L("ملف نموذج أودار ناقص")) }
            slog("audar: quantizing to \(bits)-bit")
            let src = try loadArrays(url: raw)
            guard src["model.embed_tokens.weight"] != nil, src["model.layers.23.mlp.down_proj.weight"] != nil else {
                throw SawtError.failed(L("ملف نموذج أودار ناقص"))
            }
            var dst: [String: MLXArray] = [:]
            for (k, v) in src {
                if v.ndim == 2, v.dim(1) % group == 0, k.hasSuffix(".weight") {
                    let q = quantized(v, groupSize: group, bits: bits)
                    let base = String(k.dropLast(".weight".count))
                    dst[base + ".weight"] = q.wq
                    dst[base + ".scales"] = q.scales
                    if let b = q.biases { dst[base + ".biases"] = b }
                    eval(q.wq, q.scales)
                } else {
                    dst[k] = v
                    eval(v)
                }
            }
            let tmp = dir.appendingPathComponent("audar-lm.partial.safetensors")
            try? FileManager.default.removeItem(at: tmp)
            try save(arrays: dst, url: tmp)
            dst.removeAll()
            try FileManager.default.moveItem(at: tmp, to: AudarVoice.lmURL)
            MLX.Memory.clearCache()
        }
        try? FileManager.default.removeItem(at: raw)
        for n in ["tokenizer.json", "tokenizer_config.json", "config.json"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
        }
        slog("audar: prepared")
    }

    /// ينسخ المُرمّز لمجلد خاص بدون الرموز المضافة الكثيرة (66 ألف)، فيبقى ترميز النص سريعًا.
    /// رموز الصوت والعلامات تُضاف بأرقامها مباشرة (متحقق منها من added_tokens.json في نسخة addf2d8).
    private static func trimTokenizer(_ dir: URL) throws {
        let out = AudarVoice.tokDir
        if FileManager.default.fileExists(atPath: out.appendingPathComponent("tokenizer.json").path) { return }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let tj = dir.appendingPathComponent("tokenizer.json")
        guard var t = try JSONSerialization.jsonObject(with: Data(contentsOf: tj)) as? [String: Any] else {
            throw SawtError.failed(L("مُرمّز أودار غير صالح"))
        }
        if let a = t["added_tokens"] as? [[String: Any]] {
            t["added_tokens"] = a.filter { (($0["id"] as? Int) ?? Int.max) < firstExtraToken }
        }
        let tc = dir.appendingPathComponent("tokenizer_config.json")
        guard var c = try JSONSerialization.jsonObject(with: Data(contentsOf: tc)) as? [String: Any] else {
            throw SawtError.failed(L("مُرمّز أودار غير صالح"))
        }
        if let d = c["added_tokens_decoder"] as? [String: Any] {
            c["added_tokens_decoder"] = d.filter { (Int($0.key) ?? Int.max) < firstExtraToken }
        }
        c["additional_special_tokens"] = nil
        c["extra_special_tokens"] = nil
        try FileManager.default.copyItem(at: dir.appendingPathComponent("config.json"), to: out.appendingPathComponent("config.json"))
        try JSONSerialization.data(withJSONObject: c).write(to: out.appendingPathComponent("tokenizer_config.json"))
        // آخر ملف يُكتب: وجوده يعني أن المجلد مكتمل
        try JSONSerialization.data(withJSONObject: t).write(to: out.appendingPathComponent("tokenizer.json"))
    }
}

// MARK: - النموذج اللغوي (Qwen2 بـ6 بت على MLX)

/// منفذ خاص لـQwen2 (24 طبقة، 896، 14 رأس، 2 رأس مفتاح/قيمة) مع ذاكرة مفاتيح/قيم يعاد استخدام بدايتها.
/// رأس الإخراج مربوط بالتضمين؛ نحسب فقط صفوف رموز الصوت (من speech_0 لين TARGET_CODES_END) فيصير أسرع بربع تقريبًا.
final class AudarLM {
    static let layers = 24, heads = 14, kvHeads = 2, headDim = 64, dim = 896
    private let w: KleinWeights
    private let headW: MLXArray, headS: MLXArray, headB: MLXArray?
    private var keys: [MLXArray?] = Array(repeating: nil, count: 24)
    private var values: [MLXArray?] = Array(repeating: nil, count: 24)
    private(set) var offset = 0

    init(file: URL, rows: Range<Int>) throws {
        let d = try loadArrays(url: file)
        guard d["model.embed_tokens.scales"] != nil, d["model.layers.23.mlp.down_proj.scales"] != nil,
              d["model.norm.weight"] != nil else { throw SawtError.failed(L("ملف نموذج أودار ناقص")) }
        w = KleinWeights(d: d, bits: AudarPrep.bits, group: AudarPrep.group)
        let idx = MLXArray(rows.map { Int32($0) })
        headW = w["model.embed_tokens.weight"].take(idx, axis: 0)
        headS = w["model.embed_tokens.scales"].take(idx, axis: 0)
        headB = d["model.embed_tokens.biases"]?.take(idx, axis: 0)
        eval(headW, headS)
        if let headB { eval(headB) }
    }

    /// يقص الذاكرة لأول n رمز
    func trim(to n: Int) {
        guard n < offset else { return }
        if n == 0 { reset(); return }
        let idx = MLXArray((0 ..< n).map { Int32($0) })
        for i in 0 ..< Self.layers {
            keys[i] = keys[i]?.take(idx, axis: 2)
            values[i] = values[i]?.take(idx, axis: 2)
        }
        offset = n
    }

    func reset() {
        keys = Array(repeating: nil, count: Self.layers)
        values = Array(repeating: nil, count: Self.layers)
        offset = 0
    }

    /// يمرّر الرموز ويرجع لوجِتات آخر رمز على صفوف الصوت فقط (float32)
    func forward(_ ids: [Int32]) -> MLXArray {
        let L = ids.count
        let input = MLXArray(ids)
        let emb = dequantized(w["model.embed_tokens.weight"].take(input, axis: 0),
                              scales: w["model.embed_tokens.scales"].take(input, axis: 0),
                              biases: w.has("model.embed_tokens.biases") ? w["model.embed_tokens.biases"].take(input, axis: 0) : nil,
                              groupSize: AudarPrep.group, bits: AudarPrep.bits)
        var h = emb.reshaped([1, L, Self.dim])
        var mask: MLXArray? = nil
        if L > 1 {
            let qi = MLXArray((offset ..< offset + L).map { Int32($0) }).reshaped([L, 1])
            let kj = MLXArray((0 ..< offset + L).map { Int32($0) }).reshaped([1, offset + L])
            mask = which(kj .<= qi, MLXArray(Float(0)), MLXArray(-Float.infinity)).asType(h.dtype)
        }
        for i in 0 ..< Self.layers { h = layer(h, i, L: L, mask: mask) }
        offset += L
        let last = h.reshaped([L, Self.dim])[L - 1].reshaped([1, 1, Self.dim])
        let n = MLXFast.rmsNorm(last, weight: w["model.norm.weight"], eps: 1e-6)
        let logits = quantizedMatmul(n.asType(headS.dtype), headW, scales: headS, biases: headB,
                                     transpose: true, groupSize: AudarPrep.group, bits: AudarPrep.bits)
        return logits.reshaped([-1]).asType(.float32)
    }

    private func layer(_ x: MLXArray, _ i: Int, L: Int, mask: MLXArray?) -> MLXArray {
        let p = "model.layers.\(i)."
        let hd = Self.headDim
        let r = MLXFast.rmsNorm(x, weight: w[p + "input_layernorm.weight"], eps: 1e-6)
        var q = w.lin(r, p + "self_attn.q_proj").reshaped([1, L, Self.heads, hd]).transposed(0, 2, 1, 3)
        var k = w.lin(r, p + "self_attn.k_proj").reshaped([1, L, Self.kvHeads, hd]).transposed(0, 2, 1, 3)
        var v = w.lin(r, p + "self_attn.v_proj").reshaped([1, L, Self.kvHeads, hd]).transposed(0, 2, 1, 3)
        q = MLXFast.RoPE(q, dimensions: hd, traditional: false, base: 1_000_000, scale: 1, offset: offset)
        k = MLXFast.RoPE(k, dimensions: hd, traditional: false, base: 1_000_000, scale: 1, offset: offset)
        if let pk = keys[i], let pv = values[i] {
            k = concatenated([pk, k], axis: 2)
            v = concatenated([pv, v], axis: 2)
        }
        keys[i] = k
        values[i] = v
        let o = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v,
                                                  scale: 1 / Float(hd).squareRoot(), mask: mask)
        var h = x + w.lin(o.transposed(0, 2, 1, 3).reshaped([1, L, Self.heads * hd]), p + "self_attn.o_proj")
        let r2 = MLXFast.rmsNorm(h, weight: w[p + "post_attention_layernorm.weight"], eps: 1e-6)
        let mlp = silu(w.lin(r2, p + "mlp.gate_proj")) * w.lin(r2, p + "mlp.up_proj")
        h = h + w.lin(mlp, p + "mlp.down_proj")
        return h
    }
}

/// المحرّك: النموذج اللغوي ومفكك NeuCodec كلاهما على MLX.
/// التطبيق قدّام: كرت الشاشة. بالخلفية (Metal ممنوع): نفس الأوزان ونفس الذاكرة على المعالج، بدون إعادة تحميل.
/// الصوت يطلع على دفعات وهو يتولّد (أول دفعة بعد ~0.6 ث صوت)، بدل ما ننتظر الجملة كاملة.
actor AudarEngine {
    static let shared = AudarEngine()

    struct Output {
        let samples: [Float]
        let genSeconds: Double
        let audioSeconds: Double
        let loadSeconds: Double
        let tokensPerSecond: Double
    }

    /// أول رمز صوت في المفردات (<|speech_0|>): 151671 … 217206 متتالية (متحقق منها من added_tokens.json)
    static let speechBase: Int32 = 151_671
    static let speechCount: Int32 = 65_536
    /// <|TARGET_CODES_END|>
    static let codesEnd: Int32 = 217_659
    /// علامات الطلب (من added_tokens.json نسخة addf2d8)
    static let refTextStart: Int32 = 217_652, refTextEnd: Int32 = 217_653
    static let refSpeechStart: Int32 = 217_654, refSpeechEnd: Int32 = 217_655
    static let targetTextStart: Int32 = 217_656, targetTextEnd: Int32 = 217_657
    static let targetCodesStart: Int32 = 217_658
    /// حد أعلى للجملة الوحدة: 30 ثانية صوت
    static let maxCodes = 1_500
    private static let nCtx = 2_560

    private var lm: AudarLM?
    private var tok: (any Tokenizer)?
    private var decoder: NeuCodecDecoder?
    /// الرموز اللي في الذاكرة (بداية الطلب مع المرجع تتكرر لكل جملة، فنعيد استخدامها)
    private var cached: [Int32] = []
    /// ترميز نصوص المراجع محفوظ (ثابت لكل صوت)
    private var refCache: [String: [Int32]] = [:]

    var isLoaded: Bool { lm != nil && decoder != nil && tok != nil }

    func unload() {
        let was = lm != nil || decoder != nil
        lm = nil; decoder = nil; tok = nil; cached = []; refCache = [:]
        if was { MLX.Memory.clearCache(); slog("audar: unloaded") }
    }

    /// يحمّل بالخلفية ويسخّن بصوت المستخدم المختار (يعالج المرجع مسبقًا عشان أول جملة تطلع أسرع)
    func preload(voice: String) async {
        do {
            try await load()
            if let ref = AudarRefs.find(voice) {
                let t0 = Date()
                _ = try onDevice { try self.prefill(self.prompt(ref: ref, text: ".")) }
                slog("audar: prewarm \(voice) \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            }
        } catch { slog("audar: preload failed \(error)") }
    }

    private func load() async throws {
        if isLoaded { return }
        guard AudarVoice.isInstalled else { throw SawtError.notReady(L("أصوات أودار (حمِّلها أولًا)")) }
        let t0 = Date()
        if tok == nil {
            let t = try await AutoTokenizer.from(modelFolder: AudarVoice.tokDir)
            // تحقق سريع: نص عادي يترمّز لرموز نصية بس
            guard let probe = t.encode(text: "مرحبا", addSpecialTokens: false).first, probe < 151_643 else {
                throw SawtError.failed(L("مُرمّز أودار غير صالح"))
            }
            tok = t
        }
        if lm == nil {
            lm = try AudarLM(file: AudarVoice.lmURL, rows: Int(Self.speechBase) ..< Int(Self.codesEnd) + 1)
            cached = []
        }
        if decoder == nil { decoder = try NeuCodecDecoder(file: AudarVoice.decoderURL) }
        slog("audar: mlx loaded in \(Int(Date().timeIntervalSince(t0) * 1000))ms ram=\(RAM.footprintMB)MB avail=\(RAM.availableMB)MB")
    }

    /// كرت الشاشة قدّام، والمعالج بالخلفية أو حسب اختيار المكالمة. أخطاء MLX ترجع كخطأ بدل إيقاف التطبيق.
    private func onDevice<T>(_ body: () throws -> T) throws -> T {
        let gpu = Placement.voiceGPU
        Placement.voiceNow = gpu ? "GPU" : "CPU"
        let box = MLXErrBox()
        let r = try withErrorHandler({ m in box.set(m) }) {
            try Device.withDefaultDevice(gpu ? Device.gpu : Device.cpu) { try body() }
        }
        if let m = box.message { throw MLXRunError(message: m) }
        return r
    }

    private func enc(_ s: String) -> [Int32] {
        (tok?.encode(text: s, addSpecialTokens: false) ?? []).map { Int32($0) }
    }

    /// نفس صيغة الطلب في بطاقة النموذج الرسمية، مبنية رمزًا رمزًا:
    /// النص يترمّز عاديًا، والعلامات ورموز الصوت تُضاف بأرقامها (نفس ما يسويه llama.cpp حين يقسم على الرموز المضافة)
    private func prompt(ref: AudarRefs.Ref, text: String) -> [Int32] {
        let refPart: [Int32]
        if let c = refCache[ref.key] { refPart = c } else {
            refPart = enc("user: Convert the text to speech:")
                + [Self.refTextStart] + enc(ref.text) + [Self.refTextEnd]
                + [Self.refSpeechStart] + ref.codes.map { Self.speechBase + Int32($0) } + [Self.refSpeechEnd]
            refCache[ref.key] = refPart
        }
        return refPart + [Self.targetTextStart] + enc(text) + [Self.targetTextEnd]
            + enc("\nassistant:") + [Self.targetCodesStart]
    }

    /// يعالج الطلب ويعيد استخدام البداية المشتركة مع الطلب السابق (المرجع). يرجع لوجِتات آخر رمز وعدد الرموز الجديدة.
    private func prefill(_ toks: [Int32]) throws -> (logits: MLXArray, fresh: Int) {
        guard let lm else { throw SawtError.notReady(L("أودار")) }
        guard toks.count + Self.maxCodes + 8 < Self.nCtx else {
            throw SawtError.failed(L("الجملة أطول من سياق أودار (%@)", String(toks.count)))
        }
        var common = 0
        while common < min(cached.count, toks.count - 1), cached[common] == toks[common] { common += 1 }
        lm.trim(to: common)
        cached = Array(cached.prefix(common))
        var i = common
        var logits = MLXArray(Float(0))
        while i < toks.count {
            let chunk = Array(toks[i ..< min(i + 512, toks.count)])
            logits = lm.forward(chunk)
            eval(logits)
            i += chunk.count
        }
        cached = toks
        return (logits, toks.count - common)
    }

    /// أخذ عينة: نفس إعدادات البطاقة (تكرار 1.1، top_k 40، top_p 0.9) مع حرارة 0.7.
    /// على كرت الشاشة نختار أعلى 64 فقط، ثم العقوبة والاختيار على المعالج.
    private func sample(_ logits: MLXArray, recent: Set<Int>) -> Int {
        let k = 64
        let idx = argPartition(-logits, kth: k - 1).take(MLXArray((0 ..< k).map { Int32($0) }))
        let vals = logits.take(idx)
        eval(idx, vals)
        let I = idx.asType(.int32).asArray(Int32.self), V = vals.asArray(Float.self)
        var c: [(Int, Float)] = zip(I, V).map { (i, v) in
            let n = Int(i)
            guard recent.contains(n) else { return (n, v) }
            return (n, v > 0 ? v / 1.1 : v * 1.1)
        }
        c.sort { $0.1 > $1.1 }
        c = Array(c.prefix(40))
        let mx = c[0].1
        var p = c.map { Foundation.exp(Double(($0.1 - mx) / 0.7)) }
        let sum = p.reduce(0, +)
        p = p.map { $0 / sum }
        var keep = 0, acc = 0.0
        while keep < p.count { acc += p[keep]; keep += 1; if acc >= 0.9 { break } }
        let total = p.prefix(keep).reduce(0, +)
        var r = Double.random(in: 0 ..< total)
        for j in 0 ..< keep { r -= p[j]; if r < 0 { return c[j].0 } }
        return c[keep - 1].0
    }

    /// يكتب رموز الصوت لين رمز النهاية. أي رمز غير صوتي نعتبره نهاية.
    private func generateCodes(first: MLXArray, maxCodes: Int, onCodes: ([Int], Bool) throws -> Void) throws -> [Int] {
        guard let lm else { throw SawtError.notReady(L("أودار")) }
        let endIdx = Int(Self.codesEnd - Self.speechBase)
        var codes: [Int] = []
        var logits = first
        while codes.count < maxCodes {
            if Task.isCancelled { break }
            let t = sample(logits, recent: Set(codes.suffix(64)))
            if t == endIdx { break }
            guard t < Int(Self.speechCount) else { slog("audar: non-speech token \(t) → stop"); break }
            codes.append(t)
            let tokID = Self.speechBase + Int32(t)
            // كل خطوة تختار جهازها: لو راح التطبيق للخلفية نكمل على المعالج بنفس الذاكرة
            logits = try onDevice { let l = lm.forward([tokID]); eval(l); return l }
            cached.append(tokID)
            try onCodes(codes, false)
        }
        try onCodes(codes, true)
        return codes
    }

    /// للتجربة: يرجع العينات كاملة (فاضي لو فشل)
    func synthesize(_ text: String, voice: String) async -> [Float] {
        switch await synthesizeTimed(text, voice: voice) {
        case .success(let o): return o.samples
        case .failure(let e): slog("audar: synth failed \(e)"); return []
        }
    }

    /// تقسيم المفكك: أول دفعة بعد firstChunk رمز (0.6 ث صوت) عشان الصوت يبدأ بسرعة، وبعدها كل step.
    /// كل نافذة تاخذ left رمز قبلها كسياق، ونمسك آخر hold رموز لين يجي اللي بعدها (حدود أنظف)،
    /// ونليّن الوصلة بـxfade عينة.
    static let firstChunk = 30, step = 75, left = 50, hold = 15
    static let spc = 480          // عينات لكل رمز (24k / 50)
    static let xfade = 240        // 10 ملي ثانية

    func synthesizeTimed(_ text: String, voice: String) async -> Result<Output, Error> {
        var all: [Float] = []
        let r = await synthesizeStream(text, voice: voice) { all += $0 }
        return r.map { o in Output(samples: all, genSeconds: o.genSeconds, audioSeconds: o.audioSeconds,
                                   loadSeconds: o.loadSeconds, tokensPerSecond: o.tokensPerSecond) }
    }

    /// يولّد ويرسل الصوت على دفعات وهو يتولّد. onAudio يُستدعى بالترتيب (على خيط المحرك).
    func synthesizeStream(_ text: String, voice: String, onAudio: @escaping ([Float]) -> Void) async -> Result<Output, Error> {
        do {
            guard let ref = AudarRefs.find(voice) ?? AudarRefs.all.first else { throw SawtError.failed(L("صوت أودار غير معروف")) }
            let tl = Date()
            let wasLoaded = isLoaded
            try await load()
            let loadS = wasLoaded ? 0 : Date().timeIntervalSince(tl)
            let t0 = Date()
            let toks = prompt(ref: ref, text: text)
            let pre = try onDevice { try self.prefill(toks) }
            let tp = Date()
            // تقدير سخي لطول الجملة: ~15 رمز لكل حرف كحد أعلى، عشان لو النموذج ما وقف ما يطوّل
            let cap = min(Self.maxCodes, max(150, text.count * 15))

            var emitted = 0          // كم رمز طلع صوته
            var tail: [Float] = []   // ذيل الدفعة السابقة للتليين
            var total = 0
            var firstAt: Date?
            var decodeMs = 0.0
            var chunks = 0
            func flush(_ codes: [Int], last: Bool) throws {
                guard let decoder else { return }
                let need = emitted == 0 ? Self.firstChunk : Self.step + Self.hold
                guard last ? codes.count > emitted : codes.count - emitted >= need else { return }
                let end = last ? codes.count : codes.count - Self.hold
                guard end > emitted else { return }
                let s = max(0, emitted - Self.left)
                let td = Date()
                let y: [Float] = try onDevice { decoder.decode(Array(codes[s ..< codes.count])) }
                decodeMs += Date().timeIntervalSince(td) * 1000
                let a = (emitted - s) * Self.spc
                let b = min(y.count, (end - s) * Self.spc + (last ? 0 : Self.xfade))
                guard b > a else { return }
                var seg = Array(y[a ..< b])
                // الوصلة: نخلط ذيل الدفعة السابقة مع بداية هذي
                let n = min(tail.count, seg.count)
                for i in 0 ..< n {
                    let w = Float(i + 1) / Float(n + 1)
                    seg[i] = tail[i] * (1 - w) + seg[i] * w
                }
                if last { tail = [] } else {
                    tail = Array(seg.suffix(Self.xfade))
                    seg.removeLast(min(Self.xfade, seg.count))
                }
                emitted = end
                total += seg.count
                chunks += 1
                if firstAt == nil { firstAt = Date() }
                onAudio(seg)
            }

            let codes = try generateCodes(first: pre.logits, maxCodes: cap) { c, last in try flush(c, last: last) }
            MLX.Memory.clearCache()
            guard !codes.isEmpty, total > 0 else { throw SawtError.failed(L("لم يُخرج أودار أي صوت")) }
            let genS = Date().timeIntervalSince(t0)
            let audioS = Double(total) / 24_000
            let tps = Double(codes.count) / max(Date().timeIntervalSince(tp) - decodeMs / 1000, 0.001)
            let first = Int((firstAt ?? Date()).timeIntervalSince(t0) * 1000)
            slog("audar: \(voice) mlx \(Placement.voiceNow) prefill \(pre.fresh) tok \(Int(tp.timeIntervalSince(t0) * 1000))ms, first audio \(first)ms, \(codes.count) codes \(String(format: "%.1f", tps)) tok/s, \(chunks) chunks decode \(Int(decodeMs))ms, audio \(String(format: "%.2f", audioS))s RTF=\(String(format: "%.2f", genS / max(audioS, 0.01))) ram=\(RAM.footprintMB)MB")
            return .success(Output(samples: [], genSeconds: genS, audioSeconds: audioS, loadSeconds: loadS, tokensPerSecond: tps))
        } catch {
            return .failure(error)
        }
    }
}
