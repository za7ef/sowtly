import PhotosUI
import SwiftUI
import ImagePlayground

struct ChatView: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var call: CallController
    var openDrawer: () -> Void

    @State private var draft = ""
    @State private var cloudTick = 0
    @State private var pendingCloud: CloudProvider?
    @State private var askCloudConsent = false
    /// يزيد مع كل إرسال: نتيجة إملاء صوتي متأخرة من قبل الإرسال ما ترجع تنكتب
    @State private var sendGen = 0
    @State private var voiceMode = false
    @State private var showModels = false
    @StateObject private var dictation = Dictation()
    @State private var focused = false
    @State private var pending: [Attachment] = []
    @State private var showCamera = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var attaching = false
    @ObservedObject private var net = NetworkGate.shared
    @ObservedObject private var playground = PlaygroundBridge.shared
    /// وضع البحث اللي ينتظر موافقة تنبيه الإنترنت
    @State private var webPending: NetworkGate.Mode?
    /// المستخدم قريب من آخر المحادثة؟ (لو طلع لفوق ما نسحبه لتحت مع كل رمز)
    @State private var nearBottom = true
    /// المستخدم يسحب القائمة بيده الحين (نحدّث «قريب من تحت» بس من حركته، مو من نمو الرد)
    @State private var userScrolling = false
    /// وصل شي جديد والمستخدم فوق (نقطة على زر النزول)
    @State private var hasNew = false
    @AppStorage("netWarned") private var netWarned = false
    /// «صورة» من زر +: الرسالة الجاية تنرسم صورة
    @State private var imageMode = false
    @AppStorage("imageEngine") private var imageEngineRaw = ""

    var body: some View {
        VStack(spacing: 0) {
            topBar
            messages
            composer
        }
        .background(Color.black.ignoresSafeArea())
        .fullScreenCover(isPresented: $voiceMode) {
            VoiceModeView(openDrawer: openDrawer)
                .environment(\.layoutDirection, AppLang.layout)
        }
        .sheet(isPresented: $showModels) { ModelsView() }
        // Image Playground: النافذة تنفتح بالبرومبت لما المحرك يطلبها
        .imagePlaygroundSheet(isPresented: Binding(get: { playground.prompt != nil },
                                                   set: { if !$0 { playground.dismissed() } }),
                              concept: playground.prompt ?? "",
                              onCompletion: { url in playground.finish(url) },
                              onCancellation: { playground.finish(nil) })
        .imagePlaygroundGenerationStyle(PlaygroundStyles.selected, in: PlaygroundStyles.allowed)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in addImage(img) }.ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 3, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            attaching = true
            Task {
                for it in items {
                    if let data = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        addImage(img)
                    }
                }
                photoItems = []
                attaching = false
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: Attachments.fileTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            attaching = true
            Task {
                for u in urls.prefix(3) {
                    do { pending.append(try await Attachments.addFile(u)) }
                    catch { store.error = error.localizedDescription }
                }
                attaching = false
            }
        }
        .onChange(of: showModels) { _, _ in cloudTick += 1 }
        .onChange(of: dictation.error) { _, e in if let e { store.error = e; dictation.error = nil } }
        .alert("تنبيه", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            if CloudLLM.active != nil {
                Button("العودة إلى النموذج المحلي") { CloudLLM.setActive(nil); cloudTick += 1; if models.llm == .idle { models.loadAll() } }
            }
            Button("حسنًا", role: .cancel) {}
        } message: { Text(store.error ?? "") }
    }

    // MARK: الشريط العلوي

    /// قائمة اختيار النموذج (من اسم النموذج الصغير في النص فوق)
    @ViewBuilder private var modelMenuItems: some View {
                let _ = cloudTick
                let cloud = CloudLLM.active
                Section("على الجهاز") {
                    ForEach(Catalog.llms.filter { models.downloaded.contains($0.id) || $0.id == settings.llmID }) { m in
                        Button { pickGPU(m) } label: {
                            if cloud == nil, m.id == settings.llmID { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                        }
                    }
                }
                let clouds = CloudProvider.allCases.filter { $0.hasKey }
                if !clouds.isEmpty {
                    Section("سحابي") {
                        ForEach(clouds) { c in
                            Button { pickCloud(c) } label: {
                                if cloud == c { Label("\(c.short) · \(c.model)", systemImage: "checkmark") } else { Text("\(c.short) · \(c.model)") }
                            }
                        }
                    }
                }
        Divider()
        Button { showModels = true } label: { Label("كل النماذج…", systemImage: "square.grid.2x2") }
    }

    /// رأس بسيط: زر القائمة يمين، اسم النموذج صغير بالنص، وكبسولة (محادثة جديدة + «…») يسار
    private var topBar: some View {
        HStack(spacing: 10) {
            // زر القائمة: دائرة زجاج 44 بخطين أبيض (السفلي أقصر)، بدون لون التطبيق الأزرق
            Button(action: openDrawer) {
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

            Spacer(minLength: 4)

            Menu { modelMenuItems } label: {
                HStack(spacing: 4) {
                    statusDot
                    Text(activeTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("النموذج: %@", activeTitle))
            .alert("النماذج السحابية", isPresented: $askCloudConsent) {
                Button("موافق") {
                    UserDefaults.standard.set(true, forKey: "cloudConsent")
                    if let c = pendingCloud { CloudLLM.setActive(c) }
                    pendingCloud = nil; cloudTick += 1
                }
                Button("إلغاء", role: .cancel) { pendingCloud = nil }
            } message: {
                Text("النموذج السحابي يرسل إلى خوادم الخدمة التي اخترتها: رسائلك والمحادثة السابقة والصور المرفقة، وفق سياسة خصوصيتها. قد تستخدم الباقات المجانية البيانات لتحسين خدماتها. يظهر هذا التنبيه مرة واحدة.")
            }


            Spacer(minLength: 4)

            // بالعربي أول عنصر يمين: الكتابة جوّا و«…» على الطرف الخارجي (يسار)
            HStack(spacing: 2) {
                Button { store.newConversation() } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 20, weight: .medium)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("محادثة جديدة")
                Menu {
                    Menu { modelMenuItems } label: { Label(L("النموذج: %@", activeTitle), systemImage: "cpu") }
                    Button { showModels = true } label: { Label("كل النماذج…", systemImage: "square.grid.2x2") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("المزيد")
            }
            .foregroundStyle(.primary)
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .frame(height: 44)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private var activeTitle: String {
        let _ = cloudTick
        if let c = CloudLLM.active { return c.short }
        return settings.llm.title
    }

    /// نموذج على الجهاز: نطفي السحابي ونشغّله
    private func pickGPU(_ m: LLMOption) {
        CloudLLM.setActive(nil)
        models.activate(m)
        cloudTick += 1
    }

    /// سحابي: تنبيه الخصوصية أول مرة
    private func pickCloud(_ c: CloudProvider) {
        if CloudLLM.consent { CloudLLM.setActive(c); cloudTick += 1 }
        else { pendingCloud = c; askCloudConsent = true }
    }

    @ViewBuilder private var statusDot: some View {
        let _ = cloudTick
        if CloudLLM.active != nil {
            Image(systemName: "cloud.fill").foregroundStyle(.blue).font(.caption)
        } else {
        switch models.llm {
        case .ready: EmptyView()
        case .loading(let p):
            ProgressView(value: p).progressViewStyle(.circular).controlSize(.mini)
        case .preparing: ProgressView().controlSize(.mini)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle: Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
        }
        }
    }

    // MARK: الرسائل

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach((store.current?.messages ?? []).filter { $0.id != store.pacingID }) { m in
                        MessageRow(message: m).equatable().id(m.id)
                    }
                    if store.isGenerating || store.pacingID != nil, !store.imageGenerating {
                        StreamingRow(live: store.live, onGrow: {
                            // ما نمرّر بالكود هنا: مرساة التمرير السفلية (sizeChanges) تلحق النمو بنفسها،
                            // والتمرير المزدوج كان يتعارك معها ويرجّف القائمة لما تمتلي الشاشة
                            if !nearBottom && !hasNew { hasNew = true }
                        }, onCaughtUp: { store.endPacing() })
                            .id("stream")
                    }
                    Color.clear.frame(height: 8).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            // لمسة على المحادثة تقفل الكيبورد (متزامنة، فأزرار الرسائل والروابط تشتغل عادي)
            .simultaneousGesture(TapGesture().onEnded { if focused { focused = false } })
            // المحادثة القصيرة تبدأ من فوق؛ الطويلة تفتح على آخر رسالة، ولما تتغيّر المساحة (الكيبورد) تبقى ملزّقة تحت
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .overlay {
                // الشاشة الفاضية في نص المساحة
                if (store.current?.messages ?? []).isEmpty && !store.isGenerating {
                    EmptyState(startVoice: startVoice, cloudTick: cloudTick)
                        .padding(.horizontal, 24)
                        .multilineTextAlignment(.center)
                }
            }
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentSize.height - (g.contentOffset.y + g.containerSize.height) < 120
            } action: { _, v in
                // نمو الرد يبعد آخر المحادثة مؤقتًا: ما نعتبره «طلع لفوق» إلا لو المستخدم هو اللي سحب
                if userScrolling || v { nearBottom = v }
            }
            .onScrollPhaseChange { _, phase in
                userScrolling = phase == .interacting || phase == .decelerating
            }
            .overlay(alignment: .bottom) {
                if !nearBottom {
                    Button {
                        hasNew = false
                        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
                        nearBottom = true
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.12)))
                            .overlay(alignment: .topTrailing) {
                                if hasNew { Circle().fill(Color.accentColor).frame(width: 10, height: 10).offset(x: 1, y: -1) }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("الانتقال إلى آخر المحادثة")
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .animation(.easeOut(duration: 0.2), value: nearBottom)
            .onChange(of: nearBottom) { _, v in if v { hasNew = false } }
            .onAppear { scrollToEnd(proxy, delayed: true) }
            .onChange(of: store.current?.messages.count) {
                // رسالة جديدة: ننزل لو المستخدم تحت، أو لو آخر رسالة منه (أرسل للتو)
                // لو أنت تحت، المرساة السفلية تلحق لحالها (تمرير ثاني فوقها = رجفة). ننزل بالكود بس لو كنت فوق وأرسلت
                let mine = store.current?.messages.last?.role == .user
                if !nearBottom && !mine { hasNew = true }
                if !nearBottom && mine {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    nearBottom = true
                }
            }
            .onChange(of: store.currentID) { scrollToEnd(proxy, delayed: true) }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                if nearBottom { scrollToEnd(proxy, delayed: true) }
            }
        }
    }

    /// ينزل لآخر المحادثة (مرة الحين ومرة بعد ما يخلص التخطيط/حركة الكيبورد، لأن LazyVStack يقيس متأخر)
    private func scrollToEnd(_ proxy: ScrollViewProxy, delayed: Bool) {
        proxy.scrollTo("bottom", anchor: .bottom)
        nearBottom = true
        guard delayed else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    // MARK: خانة الكتابة

    private func addImage(_ img: UIImage) {
        do {
            pending.append(try Attachments.addImage(img))
            ModelManager.shared.preloadVisionIfUseful()
        }
        catch { store.error = error.localizedDescription }
    }

    @ViewBuilder private var pendingBar: some View {
        if !pending.isEmpty || attaching {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pending) { a in
                            AttachmentChip(a: a, size: 56)
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        pending.removeAll { $0.id == a.id }
                                        a.deleteFiles()
                                    } label: {
                                        Image(systemName: "xmark.circle.fill").font(.callout)
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 6, y: -6)
                                }
                        }
                        if attaching { ProgressView().frame(width: 56, height: 56) }
                    }
                    .padding(.horizontal, 16).padding(.top, 6)
                }
                if pending.contains(where: { $0.kind == .image }) && settings.llm.vision {
                    Text("أول صورة تتطلب تحميل النموذج بوضع الرؤية، ويستغرق ذلك ثواني وذاكرة أكبر قليلًا.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
                }
                if pending.contains(where: { $0.kind == .image }) && !settings.llm.vision {
                    HStack(spacing: 6) {
                        Text(L("%@ لا يرى الصور، وسيقرأ النص الموجود فيها فقط.", settings.llm.title))
                        if let v = Catalog.llms.first(where: { $0.vision && models.downloaded.contains($0.id) })
                            ?? Catalog.llms.first(where: { $0.vision }) {
                            Button(L("التبديل إلى %@", v.title)) { models.activate(v) }.font(.caption.weight(.semibold))
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    /// «+»: المرفقات وبحث الويب والتفكير (حالتهم ظاهرة هنا وكشرائح فوق النص)
    private var attachMenu: some View {
        Menu {
            Section {
                Button { showCamera = true } label: { Label("الكاميرا", systemImage: "camera") }
                Button { showPhotos = true } label: { Label("الصور", systemImage: "photo.on.rectangle") }
                Button { showFiles = true } label: { Label("الملفات", systemImage: "folder") }
            }
            Section {
                Button { imageMode = true; focused = true } label: { Label("صورة", systemImage: "paintbrush") }
                Menu {
                    Picker("محرك الصور", selection: $imageEngineRaw) {
                        ForEach(ImageEngine.allCases) { e in
                            Text("\(e.title) · \(e.tag)").tag(e.rawValue)
                        }
                    }
                } label: {
                    Label(L("محرك الصور: %@", ImageEngine(rawValue: imageEngineRaw)?.title ?? L("لم يُختر")), systemImage: "photo.artframe")
                }
            }
            Section {
                Menu {
                    Picker("بحث في الويب", selection: Binding(get: { net.mode }, set: { setWeb($0) })) {
                        Text("متوقف").tag(NetworkGate.Mode.off)
                        Text("تلقائي").tag(NetworkGate.Mode.auto)
                        Text("دائمًا").tag(NetworkGate.Mode.on)
                    }
                } label: { Label(L("بحث في الويب: %@", net.modeLabel), systemImage: "globe") }
                Menu {
                    Picker("التفكير", selection: Binding(get: { store.thinkMode }, set: { store.setThinkMode($0) })) {
                        ForEach(ThinkMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } label: { Label(L("التفكير: %@", store.thinkMode.label), systemImage: "brain") }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 22, weight: .regular)).frame(width: 40, height: 44)
        }
        .buttonStyle(.plain)
        .padding(.leading, 6)
    }

    /// أول مرة يطلع من طافي: تنبيه الإنترنت مرة وحدة
    private func setWeb(_ m: NetworkGate.Mode) {
        if net.mode == .off, m != .off, !netWarned { webPending = m } else { applyWeb(m) }
    }
    private func applyWeb(_ m: NetworkGate.Mode) {
        switch m {
        case .off: net.on = false
        case .auto: net.auto = true; net.on = true
        case .on: net.auto = false; net.on = true
        }
    }

    /// شرائح الحالة: تبين وش مشغّل، والضغط يطفيه
    @ViewBuilder private var stateChips: some View {
        if net.mode != .off || store.thinkMode == .on || imageMode {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if imageMode {
                        chip("paintbrush", "صورة") { imageMode = false }
                    }
                    if net.mode != .off {
                        chip("globe", net.mode == .auto ? "بحث تلقائي" : "بحث دائم") { applyWeb(.off) }
                    }
                    if store.thinkMode == .on {
                        chip("brain", "تفكير عميق") { store.setThinkMode(.off) }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }
        }
    }

    private func chip(_ icon: String, _ title: String, off: @escaping () -> Void) -> some View {
        Button(action: off) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(L(title))
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.accent.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("%@، اضغط لإيقافه", L(title)))
    }

    private var micButton: some View {
        Button {
            if dictation.isRecording {
                let gen = sendGen
                dictation.stop { text in
                    guard gen == sendGen else { return }
                    draft += (draft.isEmpty ? "" : " ") + text
                }
            } else {
                dictation.start()
            }
        } label: {
            Image(systemName: dictation.isRecording ? "stop.circle.fill" : (dictation.isBusy ? "ellipsis" : "mic"))
                .font(.system(size: 20, weight: .regular))
                .symbolEffect(.pulse, isActive: dictation.isRecording)
                .foregroundStyle(dictation.isRecording ? .red : .primary)
                .frame(width: 40, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(dictation.isBusy || !models.stt.isReady)
    }

    /// خانة وحدة مثل ChatGPT: «+» ثم النص ثم المايك ثم الزر الأزرق (مكالمة ← إرسال ← إيقاف)
    private var composer: some View {
        VStack(spacing: 0) {
            pendingBar
            VStack(alignment: .leading, spacing: 0) {
                stateChips
                HStack(alignment: .bottom, spacing: 4) {
                    attachMenu
                    ComposerField(text: $draft, placeholder: dictation.isRecording ? L("جارٍ الاستماع…") : (imageMode ? L("صِف الصورة") : L("اسأل صوت لايت")),
                                  focused: $focused, clearToken: sendGen)
                    micButton
                    actionButton.padding(.trailing, 4)
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: actionKind)
                }
                // خانة 52: عناصر بارتفاع 44 + 4 فوق وتحت، والدائرة 36 تبعد 8 عن الحافة
                .padding(.vertical, 4)
            }
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
            .padding(.top, 8)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: draft.isEmpty)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: store.isGenerating)
            .animation(.easeOut(duration: 0.2), value: net.mode)
            .animation(.easeOut(duration: 0.2), value: store.thinkMode)
            .animation(.easeOut(duration: 0.2), value: imageMode)
        }
        .alert("سيتم الوصول إلى الإنترنت", isPresented: Binding(get: { webPending != nil }, set: { if !$0 { webPending = nil } })) {
            Button("متابعة") { netWarned = true; if let m = webPending { applyWeb(m) }; webPending = nil }
            Button("إلغاء", role: .cancel) { webPending = nil }
        } message: {
            Text("سيُرسل سؤالك إلى محرك بحث (DuckDuckGo، أو ويكيبيديا كبديل) لجلب الصفحات، ويبقى الباقي على جهازك. عند إيقاف البحث ينقطع التطبيق عن الإنترنت.")
        }
    }

    private var actionKind: Int {
        store.isGenerating ? 2 : (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pending.isEmpty) ? 1 : 0
    }

    /// الزر الأزرق داخل الخانة: إيقاف وقت التوليد، إرسال لو فيه نص، وإلا مكالمة صوتية
    @ViewBuilder private var actionButton: some View {
        if store.isGenerating {
            Button { store.stop() } label: { blueCircle("stop.fill", size: 13) }
                .buttonStyle(.plain)
                .accessibilityLabel("إيقاف")
                .transition(.scale.combined(with: .opacity))
        } else if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pending.isEmpty {
            Button(action: send) { blueCircle("arrow.up", size: 16) }
                .buttonStyle(.plain)
                .accessibilityLabel("إرسال")
                .transition(.scale.combined(with: .opacity))
        } else {
            Button(action: startVoice) {
                blueCircle("waveform", size: 15)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("مكالمة صوتية")
            .transition(.scale.combined(with: .opacity))
        }
    }

    /// الزر الأزرق داخل الخانة: دائرة 36 في مساحة لمس 44
    private func blueCircle(_ icon: String, size: CGFloat) -> some View {
        Image(systemName: icon)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color(red: 0.16, green: 0.42, blue: 1.0)))
            .frame(width: 44, height: 44)
            .contentShape(Circle())
    }

    private func send() {
        // الصورة ما تحتاج نموذج المحادثة لو الوصف يروح مباشرة (إنجليزي، أو عربي لـGemini) والتحسين طافي
        let raw = (ComposerField.currentText().flatMap { $0.isEmpty ? nil : $0 } ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        // تعديل صورة: وضع الصورة (أو «/صورة») مع صورة مرفقة وحدة بالضبط
        let editSource = pending.count == 1 && pending[0].kind == .image && (imageMode || ImageIntent.forced(raw)) ? pending[0] : nil
        let isImage = editSource != nil || (pending.isEmpty && (imageMode || ImageIntent.forced(raw) || ImageIntent.verdict(raw)))
        let needsLLM = !isImage || ImageIntent.needsModel(ImageIntent.strip(raw), engine: ImageEngine.selected)
        guard !needsLLM || models.llm.isReady || CloudLLM.active != nil else {
            store.error = models.llm.isBusy ? L("النموذج قيد التجهيز، لحظات.") : L("اختر نموذجًا وحمِّله من شاشة النماذج أولًا.")
            if !models.llm.isBusy { showModels = true }
            return
        }
        // النص الفعلي في الخانة (إملاء لوحة المفاتيح ممكن ما حدّث draft)
        let t = ComposerField.currentText().flatMap { $0.isEmpty ? nil : $0 } ?? draft
        let atts = pending
        sendGen += 1
        if dictation.isRecording { dictation.stop { _ in } }
        draft = ""
        pending = []
        // التفضية الفعلية (وإنهاء إملاء النظام) تصير داخل ComposerField لما يتغير sendGen
        if let editSource, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            imageMode = false
            store.generateImage(t.trimmingCharacters(in: .whitespacesAndNewlines), source: editSource)
            return
        }
        if imageMode, atts.isEmpty, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            imageMode = false
            store.generateImage(t.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        store.send(t, attachments: atts, web: net.mode == .on, webAuto: net.mode == .auto) { failed in draft = failed; pending = atts }
    }

    private func startVoice() {
        focused = false
        store.stop()
        voiceMode = true
    }
}

struct EmptyState: View {
    var startVoice: () -> Void
    var cloudTick: Int = 0
    @State private var appear = false

    var body: some View {
        VStack(spacing: 18) {
            OrbView(mic: 0, out: 0, state: .idle, animated: false)
                .frame(width: 110, height: 110)
                .scaleEffect(appear ? 1 : 0.6)
                .opacity(appear ? 1 : 0)
            Text("بماذا تفكر؟").font(.title2.weight(.semibold))
            let _ = cloudTick
            Text(CloudLLM.active.map { L("النموذج السحابي: %@ — تُرسل رسائلك إلى خوادمه", $0.short) }
                 ?? L("النموذج يعمل على جهازك، والإنترنت مغلق إلا إذا فعّلته"))
                .font(.subheadline).foregroundStyle(.secondary)
            Button(action: startVoice) {
                Label("ابدأ مكالمة صوتية", systemImage: "waveform")
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .buttonStyle(.glass)
        }
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.7)) { appear = true } }
    }
}

struct MessageRow: View, Equatable {
    let message: Message
    var streaming = false
    @State private var showMemory = false
    /// false لرسالة جديدة لسا ما دخلت: فقاعتك تنزلق، وفي الرد يظهر اسم النموذج وصف الأدوات بتلاشي
    @State private var entered: Bool

    init(message: Message, streaming: Bool = false) {
        self.message = message
        self.streaming = streaming
        _entered = State(initialValue: !ChatStore.shared.freshIDs.contains(message.id))
    }

    static func == (a: MessageRow, b: MessageRow) -> Bool { a.message == b.message && a.streaming == b.streaming }

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                // رسالتك فقاعة زرقاء غامقة صغيرة في نهاية السطر (يسار بالعربي)، والرد بدون فقاعة
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 4) {
                    if let atts = message.attachments, !atts.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) { ForEach(atts) { AttachmentChip(a: $0, size: 72) } }
                        }
                        .frame(maxWidth: 260)
                    }
                    Text(message.text)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        // حركة بصرية بس (ما تغيّر التخطيط، فما تتعارك مع التمرير)
                        .scaleEffect(entered ? 1 : 0.95, anchor: .bottomTrailing)
                        .offset(y: entered ? 0 : 16)
                        .opacity(entered ? 1 : 0)
                    if message.viaVoice {
                        Image(systemName: "waveform").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let m = message.model, !m.isEmpty {
                        Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .opacity(entered ? 1 : 0)
                    }
                    if message.memorySaved == true {
                        Button { showMemory = true } label: {
                            Text("تم حفظ الذاكرة").font(.caption2).foregroundStyle(.gray)
                        }
                        .buttonStyle(.plain)
                    }
                    if message.autoSearch == true {
                        Label("بحث في الويب", systemImage: "globe")
                            .font(.caption).foregroundStyle(.gray)
                    }
                    if let n = message.notice {
                        Label(n, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.gray)
                    }
                    if let th = message.thinking, !th.isEmpty {
                        ThinkingSection(text: th, seconds: message.thinkSeconds, live: false, auto: message.autoThink == true)
                    }
                    if message.genPending == true {
                        GenProgressView(message: message)
                            .transition(.opacity)
                    } else if let f = message.genImage {
                        GenImageView(file: f, prompt: message.genPrompt, negative: message.genNegative)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    } else if streaming && message.text.isEmpty {
                        TypingDots()
                    } else {
                        Text(SafeMarkdown.key(message.text))
                            .textSelection(.enabled)
                            .lineSpacing(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let src = message.sources, !src.isEmpty {
                        SourcesList(sources: src)
                    }
                    if !streaming, message.genImage == nil, message.genPending != true {
                        // صف أدوات خفيف: نسخ، قراءة، مشاركة، والباقي تحت «…»
                        HStack(spacing: 20) {
                            Button { UIPasteboard.general.string = message.text } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .accessibilityLabel("نسخ")
                            Button { Speaker.shared.speak(message.text) } label: {
                                Image(systemName: "speaker.wave.2")
                            }
                            .accessibilityLabel("اقرأ الرد")
                            ShareLink(item: message.text) { Image(systemName: "square.and.arrow.up") }
                                .accessibilityLabel("مشاركة")
                            Menu {
                                if NamaaVoice.isInstalled, let namaa = Catalog.namaaVoice {
                                    Button { Speaker.shared.speak(message.text, voice: namaa) } label: {
                                        Label("اقرأ بصوت نماء (تجريبي)", systemImage: "person.wave.2")
                                    }
                                }
                                if AudarVoice.isInstalled, let a = Catalog.allVoices.first(where: { $0.isAudar }) {
                                    Button { Speaker.shared.speak(message.text, voice: AppSettings.shared.voice.isAudar ? AppSettings.shared.voice : a) } label: {
                                        Label("اقرأ بصوت أودار", systemImage: "person.wave.2")
                                    }
                                }
                                Button { UIPasteboard.general.string = message.text } label: {
                                    Label("نسخ النص", systemImage: "doc.on.doc")
                                }
                            } label: {
                                Image(systemName: "ellipsis").frame(height: 20)
                            }
                            .accessibilityLabel("المزيد")
                            if message.viaVoice { Image(systemName: "waveform") }
                        }
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color.gray.opacity(0.75))
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                        .opacity(entered ? 1 : 0)
                    }
                }
            }
        }
        .onAppear {
            guard !entered else { return }
            ChatStore.shared.freshIDs.remove(message.id)
            if UIAccessibility.isReduceMotionEnabled { entered = true; return }
            withAnimation(message.role == .user ? .spring(response: 0.28, dampingFraction: 0.85) : .easeOut(duration: 0.25)) { entered = true }
        }
        .sheet(isPresented: $showMemory) { NavigationStack { MemoryView() } }
    }
}

struct TypingDots: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    Circle().fill(.secondary)
                        .frame(width: 8, height: 8)
                        .scaleEffect(0.6 + 0.4 * abs(sin(t * 3 + Double(i) * 0.6)))
                }
            }
            .padding(.vertical, 8)
        }
    }
}

/// موجة صوت صغيرة (هوية صوت) لين يوصل أول كلام من الرد: أعمدة تتحرك مثل المعادل
struct ThinkingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let bars = 4
    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<Self.bars, id: \.self) { i in
                    // كل عمود بسرعة وطور مختلف عشان ما تتحرك مع بعض
                    let speed = [5.2, 6.7, 4.6, 6.0][i]
                    let p = reduceMotion ? [0.45, 0.8, 0.6, 0.35][i]
                        : 0.5 + 0.5 * sin(t * speed + Double(i) * 1.3)
                    Capsule().fill(Theme.accent)
                        .frame(width: 3, height: 5 + 11 * p)
                }
            }
            .frame(height: 16)
            .padding(.vertical, 6)
        }
        .accessibilityLabel("يكتب الرد")
    }
}

/// الرد اللي ينكتب الحين: يراقب StreamBuffer بس، فالقائمة ما تنعاد كل كلمة.
struct StreamingRow: View {
    @ObservedObject var live: StreamBuffer
    var onGrow: () -> Void
    var onCaughtUp: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let st = live.status {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(st) }
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !live.thinking.isEmpty {
                ThinkingSection(text: live.thinking, seconds: nil, live: live.text.isEmpty)
            }
            if live.text.isEmpty {
                if live.status == nil && live.thinking.isEmpty {
                    ThinkingDot().transition(.opacity.combined(with: .scale(scale: 0.5)))
                }
            } else {
                PacedText(target: live.text, done: live.done, onGrow: onGrow, onCaughtUp: onCaughtUp)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.15), value: live.text.isEmpty)
        .onChange(of: live.thinking) { onGrow() }
        .onChange(of: live.status) { onGrow() }
    }
}

/// قسم التفكير: رمادي ومطوي افتراضيًا.
struct ThinkingSection: View {
    let text: String
    let seconds: Double?
    let live: Bool
    var auto = false
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain").font(.caption2)
                    Text(title).font(.caption)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2)
                }
                .foregroundStyle(.gray)
            }
            .buttonStyle(.plain)
            if open {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.gray)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.gray.opacity(0.35)).frame(width: 2) }
                    .textSelection(.enabled)
            }
        }
    }

    private var title: String {
        if live { return L("يفكر…") }
        if let s = seconds { return L(auto ? "فكّر تلقائيًا %@ث" : "فكّر لمدة %@ث", String(max(1, Int(s.rounded())))) }
        return L("التفكير")
    }
}

/// روابط المصادر تحت الرد.
struct SourcesList: View {
    let sources: [WebSource]
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("المصادر").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(sources.enumerated()), id: \.offset) { i, s in
                Button {
                    if let u = URL(string: s.url), u.scheme == "https" || u.scheme == "http" { openURL(u) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("[\(i + 1)]").font(.caption.monospacedDigit())
                        VStack(alignment: .leading, spacing: 0) {
                            Text(s.title).font(.caption).lineLimit(1)
                            Text(URL(string: s.url)?.host ?? s.url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// تنسيق Markdown بدون روابط قابلة للضغط في نص النموذج (حماية من روابط مدسوسة من صفحات الويب).
/// الروابط الوحيدة القابلة للضغط هي قائمة المصادر.
enum SafeMarkdown {
    private static let linkRE = try! NSRegularExpression(pattern: #"!?\[([^\]]*)\]\(([^)\s]+)[^)]*\)"#)
    private static let autoRE = try! NSRegularExpression(pattern: #"<((?:https?|mailto|tel|sms):[^>\s]+)>"#, options: [.caseInsensitive])

    static func clean(_ s: String) -> String {
        var t = s
        // [نص](رابط) → نص (الدومين)
        let ns = t as NSString
        var out = ""
        var last = 0
        for m in linkRE.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let label = ns.substring(with: m.range(at: 1))
            let host = URL(string: ns.substring(with: m.range(at: 2)))?.host
            out += label + (host.map { " (\($0))" } ?? "")
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        t = out
        t = autoRE.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "`$1`")
        return t
    }

    static func key(_ s: String) -> LocalizedStringKey {
        LocalizedStringKey(clean(s))
    }
}
