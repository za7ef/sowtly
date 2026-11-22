import SwiftUI
import Foundation
import Security

/// مفاتيح الخدمات السحابية: في سلسلة المفاتيح (Keychain) بس — ما تنحفظ في الإعدادات ولا تنكتب في السجل
enum KeyStore {
    private static let service = "com.za7ef.sawt.cloudkeys"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        let s = String(data: d, encoding: .utf8)
        return (s?.isEmpty ?? true) ? nil : s
    }

    @discardableResult
    static func set(_ account: String, _ value: String) -> Bool {
        delete(account)
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return true }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                // الجهاز هذا بس، وما ينسخ احتياطيًا لجهاز ثاني
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                kSecValueData as String: Data(v.utf8)]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

/// مزوّدو النماذج السحابية (اختياري، بمفتاح المستخدم نفسه)
enum CloudProvider: String, CaseIterable, Identifiable {
    // مجاني
    case gemini, openrouter
    // مدفوع
    case openai, anthropic, geminiPaid
    var id: String { rawValue }

    static let free: [CloudProvider] = [.gemini, .openrouter]
    static let paid: [CloudProvider] = [.openai, .anthropic, .geminiPaid]
    var isFree: Bool { Self.free.contains(self) }
    /// Gemini الصيغة نفسها (مجاني أو مدفوع)؛ OpenRouter بصيغة OpenAI
    var isGemini: Bool { self == .gemini || self == .geminiPaid }

    var title: String {
        switch self {
        case .gemini: L("Gemini (مفتاح AI Studio المجاني)")
        case .openrouter: L("OpenRouter (نماذج :free)")
        case .openai: "ChatGPT (OpenAI)"
        case .anthropic: "Claude (Anthropic)"
        case .geminiPaid: L("Gemini (مدفوع / Pro)")
        }
    }
    var short: String {
        switch self {
        case .gemini: "Gemini"; case .openrouter: "OpenRouter"; case .openai: "ChatGPT"
        case .anthropic: "Claude"; case .geminiPaid: "Gemini"
        }
    }
    /// النماذج الافتراضية (من صفحات النماذج الرسمية وقائمة OpenRouter، نوفمبر ٢٠٢٦) — تقدر تغيّرها
    var defaultModel: String {
        switch self {
        case .gemini: "gemini-3.5-flash"
        case .openrouter: "google/gemma-4-31b-it:free"
        case .openai: "gpt-6.1-terra"
        case .anthropic: "claude-haiku-5-5"
        case .geminiPaid: "gemini-4-carbon"
        }
    }
    var keyURL: String {
        switch self {
        case .gemini, .geminiPaid: "https://aistudio.google.com/apikey"
        case .openrouter: "https://openrouter.ai/keys"
        case .openai: "https://platform.openai.com/api-keys"
        case .anthropic: "https://console.anthropic.com"
        }
    }
    /// ملاحظة الحدود
    var note: String {
        switch self {
        case .gemini: L("مجاني بحدٍّ في الدقيقة وفي اليوم؛ إذا نفد يتوقف حتى يتجدد. قد تستخدم Google بيانات الطبقة المجانية لتحسين خدماتها.")
        case .openrouter: L("نماذج :free مجانية بحدٍّ في الدقيقة وفي اليوم (أقل إذا لم يكن لديك رصيد)، وقد تكون مزدحمة أو تتوقف. بدائل: nvidia/nemotron-3.5-super-vl:free، google/gemma-4-26b-a4b-it:free")
        case .openai: L("مدفوع حسب الاستخدام من رصيد حسابك.")
        case .anthropic: L("مدفوع حسب الاستخدام من رصيد حسابك.")
        case .geminiPaid: L("مدفوع (حساب مفعّل فيه الفوترة)؛ نماذج Pro/Carbon ليس لها طبقة مجانية.")
        }
    }
    var key: String? { KeyStore.get("key." + rawValue) }
    var hasKey: Bool { key != nil }
    var model: String {
        let m = UserDefaults.standard.string(forKey: "cloudModel." + rawValue)?.trimmingCharacters(in: .whitespaces) ?? ""
        // الافتراضي القديم (3.8 عليه ضغط كثير ويرجع 503) → الافتراضي الجديد
        if self == .gemini, m == "gemini-3.8-flash" { UserDefaults.standard.removeObject(forKey: "cloudModel.gemini"); return defaultModel }
        return m.isEmpty ? defaultModel : m
    }
}

/// أدوات مشتركة للخدمات السحابية: نوع الخطأ ونصوص الأخطاء
enum CloudAPI {
    struct Failure: LocalizedError, CustomStringConvertible {
        let message: String
        var code: Int = 0
        var description: String { message }
        var errorDescription: String? { message }
    }

    /// موديل احتياطي لـGemini المجاني لو الأساسي عليه ضغط (503)
    static let geminiFallback = "gemini-3.5-flash"

    /// رسالة واضحة بالعربي حسب الخطأ (بدون المفتاح طبعًا)
    static func errorText(_ p: CloudProvider, code: Int, json: [String: Any]?) -> String {
        let err = json?["error"] as? [String: Any]
        var msgFull = err?["message"] as? String ?? ""
        if msgFull.hasPrefix("{") || msgFull.hasPrefix("[") { msgFull = "" }   // رسالة فيها JSON خام: ما نعرضها
        let msg = msgFull.replacingOccurrences(of: "\n", with: " ").prefix(160)
        let status = err?["status"] as? String ?? err?["type"] as? String ?? ""
        // OpenRouter: ما فيه مزوّد يدعم خصائص الطلب (failed_routing_step / No endpoints found)
        let rawAll = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if p == .openrouter, rawAll.contains("failed_routing") || rawAll.contains("Request Feature Support") || rawAll.contains("No endpoints found") {
            return L("هذا النموذج لا يدعم الطلب — جرّب نموذجًا آخر")
        }
        switch code {
        case 401, 403:
            if p.isGemini, msg.lowercased().contains("location") { return L("Gemini غير متاح في منطقتك بهذا المفتاح") }
            return L("مفتاح %@ غير صحيح أو ليست له صلاحية — راجعه في «مفاتيح الخدمات»", p.short)
        case 404:
            return L("اسم النموذج «%1$@» غير موجود لدى %2$@ — صحّحه في «مفاتيح الخدمات»", p.model, p.short)
        case 429:
            switch p {
            case .gemini:
                return L("نفد حد Gemini المجاني (أو أُرسلت طلبات كثيرة متتالية) — انتظر دقيقة، أو حتى الغد إذا نفد الحد اليومي")
            case .geminiPaid:
                return L("Gemini: بلغتَ حد الطلبات — انتظر قليلًا ثم حاول")
            case .openrouter:
                return L("نفد حد OpenRouter المجاني أو النموذج مزدحم — انتظر دقيقة، أو جرّب نموذج :free آخر")
            case .openai:
                if status.contains("insufficient_quota") || msg.contains("quota") { return L("نفد رصيد OpenAI — اشحن الحساب") }
                return L("OpenAI: طلبات كثيرة متتالية — انتظر قليلًا ثم حاول")
            case .anthropic:
                return L("Claude: بلغتَ حد الطلبات — انتظر قليلًا ثم حاول")
            }
        case 400:
            if p == .anthropic, msg.contains("credit") { return L("نفد رصيد Anthropic — اشحن الحساب") }
            return L("رفض %1$@ الطلب: %2$@", p.short, String(msg))
        case 402:
            if p == .openrouter { return L("OpenRouter: النموذج ليس مجانيًا أو نفد الرصيد — استخدم نموذجًا ينتهي بـ:free") }
            return L("نفد رصيد %@", p.short)
        case 503:
            if p.isGemini { return L("Gemini عليه ضغط الآن — حاول بعد قليل أو غيّر النموذج") }
            return L("%@ عليه ضغط الآن — حاول بعد قليل", p.short)
        case 500...599:
            return L("لدى %1$@ مشكلة الآن (%2$@) — حاول بعد قليل", p.short, String(code))
        default:
            return L("%1$@: خطأ %2$@ %3$@", p.short, String(code), String(msg))
        }
    }
}

/// أقسام المزوّدين السحابيين (مجاني / مدفوع): مفتاح، اسم نموذج، رابط المفتاح، ملاحظة الحدود، وتشغيل للدردشة
struct CloudSections: View {
    var showActivate: Bool
    var onChange: () -> Void = {}
    @State private var drafts: [String: String] = [:]
    @State private var version = 0
    @State private var askConsent = false
    @State private var pending: CloudProvider?
    @AppStorage("cloudCalls") private var useInCalls = false

    var body: some View {
        Group {
            if showActivate {
                Section {
                    Toggle("استخدمه في المكالمات أيضًا", isOn: $useInCalls)
                } footer: {
                    Text("يرد النموذج السحابي المفعّل في الدردشة (ويرى الصور). ويبقى النموذج المحلي احتياطيًا: إذا حدث خطأ أو انقطع الإنترنت يمكنك العودة إليه بضغطة.")
                }
            }
            Section {
                ForEach(CloudProvider.free) { row($0) }
            } header: { Text("مجاني") } footer: { Text("للطبقات المجانية حدٌّ في الدقيقة وفي اليوم، وقد تتوقف حتى يتجدد الحد.") }
            Section {
                ForEach(CloudProvider.paid) { row($0) }
            } header: { Text("مدفوع") } footer: {
                Text("تُدفع حسب الاستخدام من رصيد حسابك لدى الخدمة. تُحفظ المفاتيح في سلسلة المفاتيح على هذا الجهاز فقط، وتُستخدم في الدردشة والمكالمة.")
            }
        }
        .id(version)
        .alert("النماذج السحابية", isPresented: $askConsent) {
            Button("أوافق") {
                UserDefaults.standard.set(true, forKey: "cloudConsent")
                if let p = pending { CloudLLM.setActive(p) }
                pending = nil; version += 1; onChange()
            }
            Button("إلغاء", role: .cancel) { pending = nil }
        } message: {
            Text("يرسل النموذج السحابي إلى خوادم الخدمة التي اخترتها: رسائلك والمحادثة السابقة والصور المرفقة، وفق سياسة خصوصيتها. قد تستخدم الطبقات المجانية البيانات لتحسين خدماتها. يظهر هذا التنبيه مرة واحدة.")
        }
    }

    @ViewBuilder private func row(_ p: CloudProvider) -> some View {
        let isActive = CloudLLM.active == p
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(p.title).font(.headline)
                Spacer()
                if isActive { Text("مفعّل").font(.caption.bold()).foregroundStyle(.green) }
                else if p.hasKey { Image(systemName: "key.fill").foregroundStyle(.secondary) }
            }
            SecureField(p.hasKey ? L("المفتاح محفوظ — الصق مفتاحًا جديدًا لتغييره") : L("الصق المفتاح هنا"),
                        text: Binding(get: { drafts[p.rawValue] ?? "" }, set: { drafts[p.rawValue] = $0 }))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .environment(\.layoutDirection, .leftToRight)
            TextField(p.defaultModel, text: Binding(
                get: { UserDefaults.standard.string(forKey: "cloudModel." + p.rawValue) ?? "" },
                set: { UserDefaults.standard.set($0, forKey: "cloudModel." + p.rawValue) }))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.footnote.monospaced())
                .environment(\.layoutDirection, .leftToRight)
            Text(p.note).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if !(drafts[p.rawValue] ?? "").isEmpty {
                    Button("حفظ المفتاح") {
                        KeyStore.set("key." + p.rawValue, drafts[p.rawValue] ?? "")
                        drafts[p.rawValue] = ""; version += 1; onChange()
                    }
                }
                if showActivate, p.hasKey {
                    if isActive {
                        Button("العودة إلى المحلي") { CloudLLM.setActive(nil); version += 1; onChange() }
                    } else {
                        Button("تشغيل") {
                            if CloudLLM.consent { CloudLLM.setActive(p); version += 1; onChange() }
                            else { pending = p; askConsent = true }
                        }
                        .bold()
                    }
                }
                if p.hasKey {
                    Button("حذف المفتاح", role: .destructive) {
                        KeyStore.delete("key." + p.rawValue)
                        if UserDefaults.standard.string(forKey: "cloudActive") == p.rawValue { CloudLLM.setActive(nil) }
                        version += 1; onChange()
                    }
                }
                Spacer()
                if let u = URL(string: p.keyURL) { Link("احصل على مفتاح", destination: u) }
            }
            .buttonStyle(.borderless)
            .font(.footnote)
        }
        .padding(.vertical, 4)
    }
}
