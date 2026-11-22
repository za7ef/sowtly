import SwiftUI

/// وضع المكالمة بملء الشاشة: شاشة سودا، الكرة بالنص، وتحت: إنهاء + كتم + خانة كتابة.
struct VoiceModeView: View {
    /// يفتح القائمة الجانبية بعد ما تسكّر المكالمة (اختياري)
    var openDrawer: (() -> Void)? = nil
    @EnvironmentObject var call: CallController
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @AppStorage("showCallDebug") private var showDebug = false
    @AppStorage("callCameraWarned") private var cameraWarned = false
    @State private var cameraWarn = false
    @State private var showSettings = false
    @State private var typed = ""
    @FocusState private var typing: Bool
    @ObservedObject private var camera = CallCamera.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if showDebug { DebugOverlay(debug: call.debug).padding(.horizontal, 16).padding(.top, 8) }
                if call.cameraOn && camera.running { cameraPreview.padding(.top, 10) }
                Spacer()
                OrbView(mic: call.micLevel, out: call.outLevel, state: call.state)
                    .frame(width: 280, height: 280)
                    .contentShape(Circle())
                    .onTapGesture { call.interrupt() }
                    .accessibilityLabel("الكرة: اضغط لمقاطعته")
                // الحالة: نص رمادي صغير يتبدّل بتلاشي ناعم
                ZStack {
                    Text(statusText ?? " ")
                        .id(statusText ?? "")
                        .font(.footnote)
                        .foregroundStyle(.gray)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }
                .frame(height: 20)
                .padding(.top, 24)
                .padding(.horizontal, 32)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: statusText)
                .accessibilityElement(children: .combine)
                CallReplyText(text: replyText, reduceMotion: reduceMotion)
                    .frame(maxWidth: 320)
                    .frame(height: 96)
                    .padding(.top, 18)
                    .padding(.horizontal, 32)
                    .allowsHitTesting(false)
                Spacer()
                controls
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) {
            if let n = call.notice {
                Text(n)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 64).padding(.horizontal, 24)
                    .onTapGesture { call.notice = nil }
            }
        }
        .onAppear {
            call.onTurnsChanged = { turns in Task { @MainActor in ChatStore.shared.syncFromCall(turns) } }
            call.start(seed: store.seedForCall())
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("sawt.endCall"))) { _ in
            slog("activity: end tapped")
            dismiss()
        }
        .onDisappear {
            call.end()
            call.onTurnsChanged = nil
        }
        .alert("تنبيه", isPresented: Binding(get: { call.error != nil }, set: { if !$0 { call.error = nil } })) {
            Button("حسنًا", role: .cancel) { if call.state == .idle { dismiss() } }
        } message: { Text(call.error ?? "") }
        .alert("الكاميرا في المكالمة", isPresented: $cameraWarn) {
            Button("تشغيل") { cameraWarned = true; Task { await call.toggleCamera() } }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("مع كل ما تقوله تُلتقط صورة واحدة من الكاميرا ويراها النموذج على جهازك. هذا ينقل النموذج إلى وضع الرؤية (يستغرق ثواني)، ويتأخر الرد قليلًا، وترتفع حرارة الجهاز أكثر.")
        }
        .sheet(isPresented: $showSettings) {
            CallVoiceSheet()
            .environment(\.layoutDirection, AppLang.layout)
            .presentationDetents([.medium, .large])
        }
        .statusBarHidden(false)
    }

    private func toggleCamera() {
        if call.cameraOn || cameraWarned { Task { await call.toggleCamera() } } else { cameraWarn = true }
    }

    private var cameraPreview: some View {
        CameraPreview(session: camera.session)
            .frame(width: 120, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Button { camera.flip() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.footnote).padding(7)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(6)
                .accessibilityLabel("بدّل الكاميرا")
            }
    }

    /// فوق: القائمة (يمين بالعربي) والإعدادات (يسار)، دواير زجاج ٤٤
    private var header: some View {
        HStack {
            Menu {
                Button { dismiss() } label: { Label("أنهِ المكالمة وارجع للمحادثة", systemImage: "bubble.left") }
                if let openDrawer {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { openDrawer() }
                    } label: { Label("أنهِ المكالمة وافتح القائمة", systemImage: "sidebar.right") }
                }
            } label: {
                VStack(alignment: .trailing, spacing: 6) {
                    Capsule().frame(width: 20, height: 2.2)
                    Capsule().frame(width: 13, height: 2.2)
                }
                .environment(\.layoutDirection, .leftToRight)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("القائمة")

            Spacer()

            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("إعدادات المكالمة")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// حالة المكالمة تحت الكرة
    private var statusText: String? {
        switch call.state {
        case .idle:
            if let m = models.callMissing { return models.stt.isBusy || models.llm.isBusy ? L("جارٍ التجهيز…") : m }
            return nil
        case .starting: return L("جارٍ تجهيز الصوت…")
        case .listening: return call.muted ? L("الميكروفون مكتوم") : L("يستمع…")
        case .hearing: return L("يسمعك…")
        case .thinking: return L("يفكر…")
        case .speaking: return L("يتكلم…")
        }
    }

    /// نص الرد: اللي يتكتب الحين، وبعد ما يخلص الكتابة يبقى آخر رد ظاهر
    private var replyText: String {
        if !call.liveAI.isEmpty { return call.liveAI }
        if call.state == .hearing || call.state == .thinking { return "" }
        if let t = call.turns.last, t.role == .assistant { return t.text }
        return ""
    }

    private func sendTyped() {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        call.sendTyped(t)
        typed = ""
    }

    /// تحت: خانة الكتابة + كتم + إنهاء (بالعربي الإنهاء على الطرف اليسار)
    private var controls: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    TextField("اكتب…", text: $typed)
                        .focused($typing)
                        .submitLabel(.send)
                        .onSubmit(sendTyped)
                    if !typed.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button(action: sendTyped) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 32, height: 32)
                                .background(Color.white, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("أرسل")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 56)
                .glassEffect(.regular.interactive(), in: .capsule)
                .disabled(call.state == .idle || call.state == .starting)

                Button { call.toggleMute() } label: {
                    Image(systemName: call.muted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(call.muted ? Color.red : Color.primary)
                        .frame(width: 56, height: 56)
                        .contentShape(Circle())
                        .contentTransition(.symbolEffect(.replace))
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(call.muted ? L("شغّل الميكروفون") : L("اكتم الميكروفون"))

                // الكاميرا: زر دائري بين المايك والإنهاء
                Button { toggleCamera() } label: {
                    Image(systemName: call.cameraOn ? "video.fill" : "video")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .frame(width: 56, height: 56)
                        .contentShape(Circle())
                        .contentTransition(.symbolEffect(.replace))
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(call.cameraBusy || call.state == .idle || call.state == .starting)
                .accessibilityLabel(call.cameraOn ? L("أطفئ الكاميرا") : L("شغّل الكاميرا"))

                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 56, height: 56)
                        .background(Color.white, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("أنهِ المكالمة")
            }
        }
    }
}

/// إعدادات المكالمة: الصوت واللغة والتشخيص والكاميرا — تتطبق على الكلام الجاي بدون إعادة المكالمة
struct CallSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CallSettingsForm()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
        }
    }
}

/// إعدادات المكالمة (تنفتح من زر السهم في «اختيار الصوت»)
struct CallSettingsForm: View {
    @EnvironmentObject var call: CallController
    @EnvironmentObject var settings: AppSettings
    @AppStorage("showCallDebug") private var showDebug = false
    @AppStorage("callChime") private var callChime = true

    var body: some View {
            Form {
                Section {
                    NavigationLink {
                        CallVoiceList()
                    } label: {
                        LabeledContent("الصوت", value: settings.voice.title)
                    }
                    Picker("اللغة", selection: $settings.language) {
                        Text("تلقائي").tag("auto")
                        Text("العربية").tag("ar")
                        Text("English").tag("en")
                    }
                } footer: {
                    Text("يُطبَّق من الكلام التالي.")
                }
                Section {
                    Toggle("نغمة بداية المكالمة", isOn: $callChime)
                    Toggle("عرض التشخيص", isOn: $showDebug)
                }
            }
            .navigationTitle("الإعدادات")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// «اختيار الصوت» في المكالمة (زي ChatGPT): قائمة الأسماء وعلامة على المختار.
/// الضغط على صوت يختاره ويقول جملة تعريف بصوته (أصوات أودار). السهم يفتح باقي إعدادات المكالمة.
struct CallVoiceSheet: View {
    @EnvironmentObject var call: CallController
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var models: ModelManager

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Catalog.voices) { v in
                        Button { pick(v) } label: {
                            HStack {
                                let parts = Self.split(v.title)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(parts.0).foregroundStyle(.primary)
                                    if let trait = parts.1 { Text(trait).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if settings.voiceID == v.id {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                    }
                } footer: {
                    Text("يُسمع تعريف قصير عند اختيار صوت من أصوات أودار أو نبرة. يمكنك تحميل أصوات أخرى من الإعدادات ← الصوت.")
                }
            }
            .navigationTitle("اختيار الصوت")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    NavigationLink {
                        CallSettingsForm()
                    } label: {
                        Image(systemName: "chevron.forward")
                    }
                    .accessibilityLabel("إعدادات المكالمة")
                }
            }
        }
    }

    private func pick(_ v: VoiceOption) {
        let changed = settings.voiceID != v.id
        if changed {
            // نوقف الرد أو التعريف الحالي قبل ما نغيّر الصوت
            if call.state == .speaking || call.state == .thinking { call.interrupt() }
            let bothAudar = settings.voice.isAudar && v.isAudar
            settings.voiceID = v.id
            // أصوات أودار كلها من نموذج واحد: ما نفكّه، بس نغيّر الصوت المرجعي
            if !bothAudar { models.voiceChanged() }
            call.voiceSwitched()
            slog("call: voice → \(v.id)")
        }
        // جملة التعريف للأصوات اللي لها جملة (أودار ونبرة)
        if changed || call.state == .listening, let line = VoicePreview.line(for: v) {
            call.previewVoice(line)
        }
    }

    /// «أودار: سلطان (دافئ وواثق)» → («سلطان»، «دافئ وواثق»)
    static func split(_ title: String) -> (String, String?) {
        var name = title
        if let r = name.range(of: ": ") { name = String(name[r.upperBound...]) }
        if let open = name.range(of: " ("), name.hasSuffix(")") {
            let trait = String(name[open.upperBound..<name.index(before: name.endIndex)])
            return (String(name[..<open.lowerBound]), trait)
        }
        return (name, nil)
    }
}

/// اختيار الصوت أثناء المكالمة (نفس الأصوات النازلة، ونماء لو نازل)
struct CallVoiceList: View {
    @EnvironmentObject var call: CallController
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var models: ModelManager

    var body: some View {
        Form {
            Section {
                ForEach(Catalog.voices) { v in
                    Button {
                        guard settings.voiceID != v.id else { return }
                        // نوقف الرد الحالي قبل ما نفك الصوت القديم، والرد الجاي يطلع بالصوت الجديد
                        if call.state == .speaking || call.state == .thinking { call.interrupt() }
                        let bothAudar = settings.voice.isAudar && v.isAudar
                        settings.voiceID = v.id
                        if !bothAudar { models.voiceChanged() }
                        call.voiceSwitched()
                        slog("call: voice → \(v.id)")
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(v.title).foregroundStyle(.primary)
                                Text(v.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if settings.voiceID == v.id {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
            } footer: {
                Text(isNamaa
                     ? L("نماء أبطأ: يتأخر الرد قليلًا لأنه يولّد كل جملة كاملة.")
                     : L("سيأتي الرد التالي بالصوت الجديد. يمكنك تحميل أصوات أخرى من الإعدادات ← الصوت."))
            }
        }
        .navigationTitle("الصوت")
        .navigationBarTitleDisplayMode(.inline)
    }
    private var isNamaa: Bool {
        if case .namaa = settings.voice.kind { return true }
        return false
    }
}

/// لوحة تشخيص صغيرة: توضح وين يعلق.
struct DebugOverlay: View {
    let debug: CallController.Debug
    @State private var shareURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("الحالة: %@", "\(debug.stage)")).bold()
                Spacer()
                Circle().fill(debug.vadSpeech ? .green : .gray).frame(width: 9, height: 9)
                Text(String(format: "%.0f dB", debug.micDB)).monospacedDigit()
            }
            Text(L("آخر كلام: %@", debug.lastTranscript.isEmpty ? "—" : debug.lastTranscript)).lineLimit(2)
            Text(L("التعرّف %1$@ms • أول كلمة %2$@ms • أول صوت %3$@ms", "\(debug.sttMs)", "\(debug.firstTokenMs)", "\(debug.firstAudioMs)"))
                .monospacedDigit()
            if !debug.devices.isEmpty { Text(debug.devices).monospacedDigit() }
            HStack {
                Text(L("الذاكرة %1$@MB • المتبقي %2$@MB • الحرارة %3$@", "\(debug.ramMB)", "\(debug.availMB)", debug.thermal)).monospacedDigit()
                Spacer()
                Button { shareURL = Log.shared.export() } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let u = shareURL { ActivityView(items: [u]) }
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// نص رد المساعد في المكالمة: رمادي على الأسود مباشرة (بدون خلفية ولا إطار)، ينزل تلقائيًا مع الكتابة،
/// وأطرافه فوق وتحت تتلاشى. ما يستقبل لمس.
/// النزول حركة خطية مستمرة (إزاحة النص كله بدل القفز سطر سطر): كل ما طال النص تتحرك الإزاحة بسلاسة للهدف الجديد.
struct CallReplyText: View {
    let text: String
    let reduceMotion: Bool
    @State private var textHeight: CGFloat = 0
    /// هامش فوق وتحت داخل منطقة التلاشي
    private let pad: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let shift = max(0, textHeight + pad * 2 - geo.size.height)
            Text(text)
                .font(.callout)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
                .frame(width: geo.size.width)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { t in
                    Color.clear
                        .onAppear { textHeight = t.size.height }
                        .onChange(of: t.size.height) { _, h in textHeight = h }
                })
                .padding(.top, pad)
                .offset(y: -shift)
                .animation(reduceMotion ? nil : .linear(duration: 0.9), value: shift)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .clipped()
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.3),
                .init(color: .black, location: 0.75),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: text.isEmpty)
        .accessibilityLabel(text)
    }
}


