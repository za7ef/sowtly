import Foundation
import MLXLLM
import MLXLMCommon

/// نموذج لغوي متاح للتنزيل (MLX بدقة 4 بت).
struct LLMOption: Identifiable, Hashable {
    let id: String          // معرّف المستودع في Hugging Face
    let title: String
    let sizeGB: Double      // حجم التنزيل
    let ramGB: Double       // الذاكرة المطلوبة تقريبًا
    let speed: String
    let arabic: String
    var tag: String? = nil
    var custom = false
    /// يقدر يشوف الصور (عن طريق MLXVLM)
    var vision = false

    var configuration: ModelConfiguration { LLMRegistry.shared.configuration(id: id) }
    var sizeText: String { sizeGB < 1 ? "\(Int(sizeGB * 1000)) MB" : String(format: "%.1f GB", sizeGB) }
}

/// نموذج تحويل الكلام إلى نص.
struct STTOption: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let approxSize: String
}

/// صوت مدمج داخل التطبيق.
struct VoiceOption: Identifiable, Hashable {
    enum Kind: Hashable { case piper(onnx: String), kokoro(model: String), apple, namaa, audar(voice: String), supertonic(sid: Int) }
    let id: String
    let title: String
    let subtitle: String
    let folder: String
    let kind: Kind
}

enum Catalog {
    /// نموذج واحد فقط في صوت لايت (MLX بدقة 4 بت على كرت الشاشة). الحجم متحقق منه من Hugging Face (نوفمبر 2026).
    /// يدعم الصور بنفس الملفات (MLXVLM)، فلا يوجد تنزيل ثانٍ.
    static let builtInLLMs: [LLMOption] = [
        LLMOption(id: "mlx-community/Qwen3.5-4B-4bit", title: "Qwen3.5 4B", sizeGB: 3.06, ramGB: 3.8,
                  speed: L("سريع على معالج الرسوميات"), arabic: L("عربي ممتاز"), tag: L("النموذج الوحيد"), vision: true),
    ]

    /// لا توجد نماذج مخصصة في صوت لايت (نموذج واحد فقط)
    static var customLLMs: [LLMOption] { [] }

    static var llms: [LLMOption] { builtInLLMs + customLLMs }

    static func addCustom(_ repo: String) {
        var list = UserDefaults.standard.stringArray(forKey: "customLLMs") ?? []
        let r = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.contains("/"), !list.contains(r), !builtInLLMs.contains(where: { $0.id == r }) else { return }
        list.append(r)
        UserDefaults.standard.set(list, forKey: "customLLMs")
    }

    static func removeCustom(_ repo: String) {
        var list = UserDefaults.standard.stringArray(forKey: "customLLMs") ?? []
        list.removeAll { $0 == repo }
        UserDefaults.standard.set(list, forKey: "customLLMs")
    }

    static let stts: [STTOption] = [
        STTOption(id: "apple", title: L("تعرّف Apple على الكلام"),
                  subtitle: L("موصى به للمكالمات: لا يستهلك الذاكرة، فيترك مساحة لنموذج أذكى"), approxSize: "0 MB"),
    ]

    /// الأصوات المدمجة. يُتجاهل أي صوت ملفاته غير موجودة في الحزمة.
    static let allVoices: [VoiceOption] = [
        VoiceOption(id: "nabra-saudi", title: L("نبرة: نورة (هادئة وودودة)"),
                    subtitle: L("نسائي"), folder: "nabra-saudi",
                    kind: .kokoro(model: "model.int8.onnx")),
        VoiceOption(id: "nabra-msa", title: L("نبرة: هند (رزينة وواضحة)"),
                    subtitle: L("نسائي"), folder: "nabra-msa",
                    kind: .kokoro(model: "model.int8.onnx")),
        VoiceOption(id: "piper-miro", title: L("ميرو"),
                    subtitle: L("صوت بلكنة سعودية، سريع جدًا"), folder: "piper-miro",
                    kind: .piper(onnx: "ar_JO-SA_miro_V2-high.onnx")),
        // Supertonic 3 (OpenRAIL-M): متعدد اللغات، عربي فصيح، يُحمَّل عند الطلب (~129 MB)
        VoiceOption(id: "supertonic", title: L("Supertonic (فصحى)"),
                    subtitle: L("عربي فصيح واضح، متعدد اللغات"), folder: "supertonic-3",
                    kind: .supertonic(sid: 0)),
        VoiceOption(id: "apple", title: L("صوت Apple"),
                    subtitle: L("أصوات النظام، تعمل دائمًا"), folder: "", kind: .apple),
        VoiceOption(id: "namaa", title: L("نماء سعودي (تجريبي)"),
                    subtitle: L("صوت رجالي سعودي، ثقيل ويستغرق وقتًا قبل كل جملة في المكالمة"), folder: "", kind: .namaa),
    ] + AudarRefs.all.map {
        VoiceOption(id: "audar-\($0.key)", title: $0.title, subtitle: $0.subtitle, folder: "", kind: .audar(voice: $0.key))
    }

    static var namaaVoice: VoiceOption? { allVoices.first { $0.kind == .namaa } }

    static var voicesRoot: URL? { Bundle.main.url(forResource: "Voices", withExtension: nil) }

    static var voices: [VoiceOption] {
        allVoices.filter { v in
            switch v.kind {
            case .apple: return true
            case .namaa: return NamaaVoice.isInstalled
            case .audar: return AudarVoice.isInstalled
            case .piper(let onnx): return exists("\(v.folder)/\(onnx)")
            case .kokoro(let model): return exists("\(v.folder)/\(model)")
            case .supertonic: return exists("\(v.folder)/vector_estimator.int8.onnx")
            }
        }
    }

    /// مجلد الصوت: داخل التطبيق إذا مدمج، وإلا اللي نزل على الجوال.
    static func voiceDir(_ folder: String) -> URL {
        if let root = voicesRoot {
            let d = root.appendingPathComponent(folder)
            if FileManager.default.fileExists(atPath: d.path) { return d }
        }
        return VoiceDownloads.root.appendingPathComponent(folder)
    }

    static func exists(_ rel: String) -> Bool {
        if let root = voicesRoot, FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path) { return true }
        return FileManager.default.fileExists(atPath: VoiceDownloads.root.appendingPathComponent(rel).path)
    }
}

/// إعدادات المستخدم المحفوظة.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var llmID: String { didSet { d.set(llmID, forKey: "llmID") } }
    @Published var sttID: String { didSet { d.set(sttID, forKey: "sttID") } }
    @Published var voiceID: String { didSet { d.set(voiceID, forKey: "voiceID") } }
    @Published var speechRate: Double { didSet { d.set(speechRate, forKey: "speechRate") } }
    @Published var language: String { didSet { d.set(language, forKey: "language") } }
    @Published var persona: String { didSet { d.set(persona, forKey: "persona") } }
    @Published var patience: Double { didSet { d.set(patience, forKey: "patience") } }
    /// اختياري ومحفوظ على الجهاز بس.
    @Published var userName: String { didSet { d.set(userName, forKey: "userName") } }
    /// "m" مذكر، "f" مؤنث، "" بدون تحديد
    @Published var addressForm: String { didSet { d.set(addressForm, forKey: "addressForm") } }

    private let d = UserDefaults.standard

    static let defaultPersona = """
    أنت «صوت»، مساعد ذكي يشتغل على جوال المستخدم.
    تكلّم بالعربي بلهجة سعودية بيضاء عامية إذا كلمك بالعربي، وبالإنجليزي إذا كلمك بالإنجليزي. مثال: بدل «أنا بخير، شكراً لسؤالك» قل «الحمدلله تمام، وأنت كيفك؟».
    كن طبيعي كأنك صاحبه، وجاوب على اللي قاله مباشرة بدون مقدمات.
    نوّع كلامك ولا تكرر نفس العبارات أو نفس بداية الرد، ولا تعيد سؤاله عليه.
    إذا ما فهمت كلامه اسأله يعيد باختصار.
    """

    /// الشخصية الافتراضية القديمة (للترقية التلقائية)
    static let legacyPersona = """
    أنت «صوت»، مساعد ذكي يشتغل على جوال المستخدم بدون إنترنت. تتكلم معه في مكالمة صوتية مباشرة.
    تكلّم بالعربي بلهجة بيضاء طبيعية إذا كلمك بالعربي، وبالإنجليزي إذا كلمك بالإنجليزي.
    ردودك قصيرة وطبيعية كأنك صاحبه تتكلم مو تكتب: جملة إلى ثلاث جمل غالبًا.
    نوّع كلامك ولا تكرر نفس العبارات أو نفس بداية الرد، ولا تعيد سؤاله عليه.
    جاوب على اللي قاله مباشرة. إذا ما فهمت كلامه (ممكن التمييز غلط) اسأله يعيد باختصار.
    لا تستخدم قوائم ولا رموز ولا إيموجي ولا تنسيق، لأن كلامك يتحول لصوت.
    اكتب الأرقام بالحروف إذا كانت قليلة.
    """

    /// التعليمات الكاملة وقت التشغيل: الشخصية + الاسم وصيغة المخاطبة (إذا محددة) + الذاكرة.
    func systemPrompt(chat: Bool, query: String, memory: Bool = true) -> String {
        // الوصف القديم "بدون إنترنت" مو دقيق مع البحث في الويب
        var s = persona.replacingOccurrences(of: "يشتغل على جوال المستخدم بدون إنترنت", with: "يشتغل على جوال المستخدم")
        if UserDefaults.standard.bool(forKey: "netOn") {
            s = s.replacingOccurrences(of: "بدون إنترنت", with: "").replacingOccurrences(of: "بدون انترنت", with: "")
        }
        // شخصية أساسية وحدة للدردشة والمكالمة (نفس المحتوى والدقة)، والمكالمة تضيف بس أسلوب الكلام
        s = s.replacingOccurrences(of: "تتكلم معه في مكالمة صوتية مباشرة.", with: chat ? "تكلمه في دردشة كتابية." : "تكلمه الحين في مكالمة صوتية مباشرة.")
        s = s.replacingOccurrences(of: "ردودك قصيرة وطبيعية كأنك صاحبه تتكلم مو تكتب: جملة إلى ثلاث جمل غالبًا.",
                                   with: "ردودك واضحة ومباشرة، قصيرة إذا السؤال بسيط.")
        if chat {
            s = s.replacingOccurrences(of: "لا تستخدم قوائم ولا رموز ولا إيموجي ولا تنسيق، لأن كلامك يتحول لصوت.",
                                       with: "في الدردشة تقدر تستخدم قوائم وتنسيق Markdown وكود إذا يفيد، وطوّل إذا السؤال يحتاج.")
        } else {
            s = s.replacingOccurrences(of: "لا تستخدم قوائم ولا رموز ولا إيموجي ولا تنسيق، لأن كلامك يتحول لصوت.", with: "")
            s = s.replacingOccurrences(of: "اكتب الأرقام بالحروف إذا كانت قليلة.", with: "")
            s += "\nتكلمه الحين في مكالمة صوتية مباشرة. اكتب الأرقام القليلة بالحروف لأنها تنقرا بصوت."
            s += """

            أسلوب المكالمة: فكّر في نفس الجواب اللي كنت بتكتبه في الدردشة بنفس الدقة والمعلومات، وقله ملخّص للكلام:             جملتين إلى أربع جمل تغطي النقاط الأساسية بدون ما تغيّر المضمون. إذا طلب تفصيل أو قال كمّل، طوّل.             بدون قوائم ولا رموز ولا إيموجي ولا تنسيق، لأن كلامك يتحول لصوت.
            """
        }
        if chat {
            s = s.replacingOccurrences(of: "اكتب الأرقام بالحروف إذا كانت قليلة.", with: "اكتب الأرقام والتواريخ بالأرقام (مثل 3 يناير 2026).")
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "ar@numbers=latn")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "EEEE d MMMM yyyy"
        let today = df.string(from: Date())
        var extra: [String] = ["إذا تعارض شي في الوصف اللي فوق مع التعليمات هذي، التعليمات هذي هي اللي تمشي.",
                               "تاريخ اليوم: \(today) (ميلادي). أي تاريخ قبله صار ماضي؛ لا تتكلم عنه كأنه جاي.",
                               "لهجتك عامية سعودية بيضاء مو فصحى (إلا إذا كلمك بالإنجليزي أو طلب الفصحى). مثال: بدل «أنا بخير، شكراً لسؤالك» قل «الحمدلله تمام، وأنت كيفك؟».",
                               "حاول تجاوب أول دايمًا. لا ترد بأسئلة كثيرة: سؤال توضيحي واحد بالكثير، وبس إذا ما تقدر تجاوب بدونه. إذا كان لغز أو مسألة، فكّر وحلّها وقل الجواب."]
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { extra.append("اسم المستخدم: \(name).") }
        switch addressForm {
        case "m": extra.append("خاطب المستخدم بصيغة المذكر.")
        case "f": extra.append("خاطب المستخدم بصيغة المؤنث.")
        default: break
        }
        if !extra.isEmpty { s += "\n" + extra.joined(separator: "\n") }
        if memory {
            let mem = MemoryStore.promptBlock(for: query)
            if !mem.isEmpty { s += "\n\n" + mem }
        }
        return s
    }

    private init() {
        llmID = d.string(forKey: "llmID") ?? Catalog.llms[0].id
        if !d.bool(forKey: "migratedAppleSTT") {
            // من بناء 34: سمع آبل افتراضي (ما ياخذ ذاكرة) عشان النماذج الأذكى تكفي بالمكالمة
            d.set(true, forKey: "migratedAppleSTT")
            d.set(true, forKey: "migratedLightDefaults")
            d.removeObject(forKey: "sttID")
        }
        if !d.bool(forKey: "migratedLightDefaults") {
            // من بناء 13: الافتراضي أخف عشان الذاكرة والحرارة
            d.set(true, forKey: "migratedLightDefaults")
            d.removeObject(forKey: "sttID")
        }
        // Whisper انشال: سمع آبل هو السمع الوحيد، وملفات Whisper القديمة تنحذف مرة وحدة
        d.set("apple", forKey: "sttID")
        d.removeObject(forKey: "downloadedSTT")
        if !d.bool(forKey: "whisperFilesCleaned") {
            Task.detached(priority: .utility) {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let hf = docs.appendingPathComponent("huggingface", isDirectory: true)
                if FileManager.default.fileExists(atPath: hf.path) {
                    try? FileManager.default.removeItem(at: hf)
                    slog("stt: removed retired Whisper files")
                }
                UserDefaults.standard.set(true, forKey: "whisperFilesCleaned")
            }
        }
        sttID = "apple"
        voiceID = d.string(forKey: "voiceID") ?? (Catalog.voices.first?.id ?? "apple")
        speechRate = d.object(forKey: "speechRate") as? Double ?? 1.0
        language = d.string(forKey: "language") ?? "auto"
        let isOldDefault: (String) -> Bool = { p in
            let n = p.trimmingCharacters(in: .whitespacesAndNewlines)
            return n == AppSettings.legacyPersona.trimmingCharacters(in: .whitespacesAndNewlines)
                || (p.contains("بدون إنترنت") && p.contains("مكالمة صوتية مباشرة"))
        }
        if let p = d.string(forKey: "persona"), !isOldDefault(p) {
            persona = p
        } else {
            // ترقية أي شخصية افتراضية قديمة (كانت فيها معلومات شخصية) للعامة الجديدة
            persona = AppSettings.defaultPersona
            d.set(AppSettings.defaultPersona, forKey: "persona")
        }
        userName = d.string(forKey: "userName") ?? ""
        addressForm = d.string(forKey: "addressForm") ?? ""
        patience = d.object(forKey: "patience") as? Double ?? 0.7
    }

    var llm: LLMOption { Catalog.llms.first { $0.id == llmID } ?? Catalog.llms[0] }
    var stt: STTOption { Catalog.stts.first { $0.id == sttID } ?? Catalog.stts[0] }
    var voice: VoiceOption { Catalog.voices.first { $0.id == voiceID } ?? Catalog.voices.first { $0.kind == .apple }! }
}

extension VoiceOption {
    var isAudar: Bool { if case .audar = kind { return true }; return false }
    var isSupertonic: Bool { if case .supertonic = kind { return true }; return false }
}
