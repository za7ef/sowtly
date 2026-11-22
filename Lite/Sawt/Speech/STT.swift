import Foundation

/// تحويل الكلام إلى نص عن طريق سمع آبل (التعرّف على الكلام في iOS). ما فيه نماذج تنزل.
actor SpeechRecognizer {
    static let shared = SpeechRecognizer()

    private var ready = false

    var isReady: Bool { ready }

    func unload() { ready = false }

    func load() async throws {
        if ready { return }
        guard await AppleSTT.authorize() else {
            throw SawtError.failed(L("اسمح لتطبيق صوت لايت بالتعرّف على الكلام من الإعدادات."))
        }
        ready = true
        slog("stt apple ready, onDevice=\(AppleSTT.supportsOnDevice)")
    }

    /// يرجع النص واللغة المكتشفة.
    func transcribe(_ audio: [Float], language: String?) async throws -> (text: String, language: String) {
        guard ready else { throw SawtError.notReady(L("تعرّف Apple على الكلام")) }
        return try await AppleSTT.transcribe(audio, language: language)
    }
}

enum SawtError: LocalizedError {
    case notReady(String)
    case failed(String)
    case timeout(String)
    var errorDescription: String? {
        switch self {
        case .notReady(let w): return L("%@ غير جاهز. حمِّله من شاشة النماذج.", w)
        case .failed(let m): return m
        case .timeout(let w): return L("استغرق %@ وقتًا طويلًا ولم يعمل. حاول مرة أخرى أو اختر نموذجًا أصغر.", w)
        }
    }

    /// يحوّل أخطاء المكتبات لرسالة مفهومة.
    static func friendly(_ error: Error?) -> SawtError {
        guard let error else { return .failed(L("حدث خطأ غير معروف.")) }
        if let e = error as? SawtError { return e }
        if let c = error as? CloudAPI.Failure { return .failed(c.message) }
        let d = String(describing: error)
        if d.contains("Template") || d.contains("Jinja") {
            return .failed(L("هذا النموذج لا يتوافق مع طريقة المحادثة في التطبيق. جرّب Qwen3 4B."))
        }
        if d.lowercased().contains("memory") {
            return .failed(L("الذاكرة لا تكفي لهذا النموذج. اختر نموذجًا أصغر."))
        }
        return .failed(L("تعذّر على النموذج الرد. (%@)", error.localizedDescription))
    }
}
