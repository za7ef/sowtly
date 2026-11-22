import Foundation

/// حالة تشغيل النماذج أثناء المكالمة (للوحة التشخيص).
/// نموذج الدردشة على كرت الشاشة دايمًا (MLX).
enum Placement {
    static let voiceKey = "callVoiceDevice"   // auto | gpu | cpu

    static var voiceChoice: String {
        get { UserDefaults.standard.string(forKey: voiceKey) ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: voiceKey); slog("placement: voice → \(newValue)") }
    }

    /// أودار على كرت الشاشة؟ (في الخلفية دايمًا المعالج)
    static var voiceGPU: Bool {
        guard AppPhase.active else { return false }
        switch voiceChoice {
        case "cpu": return false
        case "gpu": return true
        default: return !lowPower   // تلقائي: كرت الشاشة أسرع بكثير؛ المعالج بس لو الجهاز حار جدًا
        }
    }
    private static var lowPower: Bool { ProcessInfo.processInfo.thermalState == .critical }

    // MARK: الحالة الحية (للوحة التشخيص)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _chat = "—"
    nonisolated(unsafe) private static var _voice = "—"
    static var chatNow: String {
        get { lock.lock(); defer { lock.unlock() }; return _chat }
        set { lock.lock(); _chat = newValue; lock.unlock() }
    }
    static var voiceNow: String {
        get { lock.lock(); defer { lock.unlock() }; return _voice }
        set { lock.lock(); _voice = newValue; lock.unlock() }
    }
    /// «الدردشة: GPU · الصوت: CPU»
    static var liveLabel: String { L("الدردشة: %1$@ · الصوت: %2$@", chatNow, voiceNow) }
}
