import SwiftUI
import BackgroundTasks
import UIKit

@main
struct SawtApp: App {
    @StateObject private var models = ModelManager.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var store = ChatStore.shared
    @StateObject private var call = CallController()
    @StateObject private var updater = UpdateChecker.shared
    @Environment(\.scenePhase) private var phase
    @State private var bgTask: Task<Void, Never>?

    init() {
        CrashCollector.shared.start()
        PickerFix.install()
        // نعرف إذا التطبيق قدّام (كرت الشاشة مسموح) أو راح للخلفية
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { _ in AppPhase.active = false }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in AppPhase.active = false }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in AppPhase.active = true }
        // نشاط المكالمة: ننهي اليتيم عند التشغيل/الرجوع، وننهيه عند إغلاق التطبيق
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CallActivity.cleanupOrphans() }
        }
        nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CallActivity.endSync() }
        }
        Task { @MainActor in CallActivity.cleanupOrphans() }
        // تسخين صامت عند الرجوع للتطبيق (أول سؤال بعدها يطلع أسرع)
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await LLMService.shared.warmUp(reason: "active")
            }
        }
        if #available(iOS 26.0, *) {
            slog("bg: continued-processing gpu=\(BGTaskScheduler.supportedResources.contains(.gpu))")
        }
        ComputeMode.migrate()
        ImageEngine.migrate()
        let l = Log.shared
        slog("launch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") prevCrashed=\(l.previousRunCrashed) at=\(l.previousStage)")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(models)
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(call)
                .environment(\.layoutDirection, AppLang.layout)
                .environment(\.locale, AppLang.locale)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task {
                    // نخلي أول إطار يطلع قبل تحميل النموذج الثقيل
                    try? await Task.sleep(for: .milliseconds(400))
                    // بعد انقفال مفاجئ: ننتظر قرار المستخدم في شاشة الاسترداد
                    guard !SafeStart.holding else { slog("launch: holding (recovery)"); return }
                    models.loadAll()
                    await updater.check()
                }
                .sheet(item: $updater.available) { UpdateSheet(info: $0).environment(\.layoutDirection, AppLang.layout) }
                .alert("التحديثات", isPresented: Binding(get: { updater.lastMessage != nil },
                                                        set: { if !$0 { updater.lastMessage = nil } })) {
                    Button("حسنًا", role: .cancel) {}
                } message: { Text(updater.lastMessage ?? "") }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    slog("⚠️ memory warning: footprint=\(RAM.footprintMB)MB avail=\(RAM.availableMB)MB llm=\(AppSettings.shared.llmID) stt=\(AppSettings.shared.sttID) voice=\(AppSettings.shared.voiceID)")
                    Task { await LLMService.shared.trim() }
                    // الصوت يرجع يتحمل وقت الحاجة؛ نفكه إذا ما فيه مكالمة
                    // ما نفك شي إلا إذا الذاكرة فعلًا قليلة (iOS أحيانًا يحذّر والمتبقي كثير)
                    if !AudioIO.shared.ownedByCall, RAM.availableMB < 1000 { SpeechSynth.shared.unload() }
                    URLCache.shared.removeAllCachedResponses()
                }
                .onChange(of: phase) { _, p in
                    // الخلفية مو كراش: النظام يقفل التطبيقات اللي بالخلفية عادي
                    if p == .background {
                        slog("background"); if !AudioIO.shared.ownedByCall { slog.stage("") }
                        store.flush()
                        Task { await LLMService.shared.trim() }
                        bgTask?.cancel()
                        // نطلب وقت خلفية قصير عشان التفريغ يكمل قبل ما يوقف iOS التطبيق
                        let bg = BackgroundTask()
                        bg.begin()
                        bgTask = Task {
                            defer { bg.end() }
                            try? await Task.sleep(for: .seconds(8))
                            if Task.isCancelled { return }
                            await models.unloadForBackground()
                        }
                    }
                    if p == .active {
                        bgTask?.cancel(); bgTask = nil
                        slog.stage(call.state == .idle ? "idle" : "call")
                        if models.llm == .idle, !SafeStart.holding { models.loadAll() }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                    slog("thermal: \(ThermalWatch.label)")
                }
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.42, green: 0.62, blue: 1.0)
    static let accent2 = Color(red: 0.68, green: 0.45, blue: 1.0)
    static let bg = Color(red: 0.04, green: 0.04, blue: 0.06)
    /// فقاعة رسائل المستخدم: أزرق غامق
    static let userBubble = Color(red: 0.03, green: 0.07, blue: 0.42)
}

/// غلاف بسيط لوقت الخلفية من iOS.
@MainActor
final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid
    func begin() {
        id = UIApplication.shared.beginBackgroundTask(withName: "sawt.unload") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
