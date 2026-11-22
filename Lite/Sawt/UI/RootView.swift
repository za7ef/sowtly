import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var models: ModelManager
    @State private var orphans: [Storage.ModelFolder] = []
    @State private var crashNotice = false
    /// انقفل المرة اللي فاتت؟ نعرض شاشة الاسترداد بدل المحادثة (عشان السجل يوصل حتى لو المحادثة نفسها تكرش)
    @State private var recovering = Log.shared.previousRunCrashed
    @State private var shareURL: URL?
    @State private var drawerOpen = false
    @State private var drag: CGFloat = 0
    private let drawerWidth: CGFloat = 300

    var body: some View {
        if recovering {
            CrashRecoveryView { loadModels in
                recovering = false
                SafeStart.holding = false
                slog("recovery: continue loadModels=\(loadModels)")
                if loadModels {
                    ModelManager.shared.loadAll()
                    Task { await UpdateChecker.shared.check() }
                }
            }
        } else {
            main
                .onAppear {
                    slog.stage("ui:chat")
                    Task {
                        try? await Task.sleep(for: .seconds(4))
                        if !ModelManager.shared.llm.isBusy { slog.stage("idle") }
                    }
                }
        }
    }

    private var main: some View {
        GeometryReader { geo in
            let open = drawerOpen ? drawerWidth : 0
            let offset = max(0, min(drawerWidth, open + drag))
            ZStack(alignment: .leading) {
                DrawerView(close: { setDrawer(false) })
                    .frame(width: drawerWidth)
                    .offset(x: offset - drawerWidth)
                    .opacity(Double(offset / drawerWidth))

                ChatView(openDrawer: { setDrawer(true) })
                    .frame(width: geo.size.width)
                    .clipShape(RoundedRectangle(cornerRadius: offset > 0 ? 28 : 0, style: .continuous))
                    .scaleEffect(1 - 0.06 * (offset / drawerWidth))
                    .offset(x: offset)
                    .overlay {
                        if offset > 0 {
                            Color.black.opacity(0.25 * Double(offset / drawerWidth))
                                .offset(x: offset)
                                .onTapGesture { setDrawer(false) }
                        }
                    }
            }
            .background(Color.black.ignoresSafeArea())
            .alert("أُغلق التطبيق في المرة السابقة", isPresented: $crashNotice) {
                Button("صدِّر السجل") { shareURL = Log.shared.export() }
                Button("حسنًا", role: .cancel) {}
            } message: {
                Text(L("كان حينها في: %@. السجل محفوظ؛ صدِّره وأرسله لمعرفة السبب.", Log.shared.previousStage))
            }
            .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
                if let u = shareURL { ActivityView(items: [u]) }
            }
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { v in
                        // في الواجهة العربية الاتجاه مقلوب تلقائيًا
                        if drawerOpen || v.startLocation.x < 40 || abs(v.translation.width) > abs(v.translation.height) * 2 {
                            drag = v.translation.width
                        }
                    }
                    .onEnded { v in
                        let target = (drawerOpen ? drawerWidth : 0) + v.predictedEndTranslation.width
                        setDrawer(target > drawerWidth / 2)
                        drag = 0
                    }
            )
        }
    }

    private var orphanBytes: Int64 { orphans.reduce(0) { $0 + $1.bytes } }

    private func setDrawer(_ open: Bool) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            drawerOpen = open
            drag = 0
        }
    }
}

struct DrawerView: View {
    @EnvironmentObject var store: ChatStore
    var close: () -> Void
    @State private var search = ""
    @State private var searching = false
    @State private var showAll = false
    @State private var showSettings = false
    @State private var showModels = false
    @State private var showVoice = false
    @State private var renaming: UUID?
    @State private var newTitle = ""
    @FocusState private var searchFocused: Bool

    private let recentLimit = 7

    var filtered: [Conversation] {
        search.isEmpty ? store.conversations
            : store.conversations.filter { c in
                c.title.localizedCaseInsensitiveContains(search)
                    || c.messages.contains { $0.text.localizedCaseInsensitiveContains(search) }
            }
    }

    /// غير فاضية بس (المحادثة الجديدة الفاضية ما تطلع بالقائمة إلا لو هي الحالية)
    private var shown: [Conversation] {
        let all = filtered.filter { !$0.messages.isEmpty || $0.id == store.currentID }
        return (showAll || searching) ? all : Array(all.prefix(recentLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !searching {
                        nav
                        Divider().overlay(Color.white.opacity(0.12)).padding(.vertical, 18)
                    }
                    recents
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            footer
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color.black)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showModels) { ModelsView() }
        .fullScreenCover(isPresented: $showVoice) {
            VoiceModeView().environment(\.layoutDirection, AppLang.layout)
        }
        .alert("إعادة تسمية", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("اسم المحادثة", text: $newTitle)
            Button("حفظ") { if let id = renaming { store.rename(id, to: newTitle) }; renaming = nil }
            Button("إلغاء", role: .cancel) { renaming = nil }
        }
    }

    // MARK: الرأس: «صوت» كبير + زر بحث دائري

    private var header: some View {
        HStack(spacing: 12) {
            if searching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("ابحث في المحادثات", text: $search).focused($searchFocused)
                }
                .padding(.horizontal, 14).frame(height: 44)
                .glassEffect(.regular, in: .capsule)
                Button("إلغاء") { search = ""; searching = false; searchFocused = false }
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: "صوت لايت").font(.largeTitle.weight(.bold))
                Spacer()
                Button {
                    searching = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { searchFocused = true }
                } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("بحث في المحادثات")
            }
        }
        .padding(.bottom, 18)
        .animation(.easeOut(duration: 0.2), value: searching)
    }

    // MARK: الوصول السريع

    private var nav: some View {
        VStack(alignment: .leading, spacing: 4) {
            navRow("waveform", L("مكالمة صوتية")) { store.stop(); showVoice = true }
            navRow("cpu", L("النماذج")) { showModels = true }
        }
    }

    private func navRow(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.title3).frame(width: 28)
                Text(title).font(.title3)
                Spacer()
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: المحادثات الأخيرة

    private var recents: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(shown) { c in
                let isCurrent = c.id == store.currentID
                HStack(spacing: 8) {
                    Button {
                        store.select(c.id); close()
                    } label: {
                        Text(c.title == "محادثة جديدة" ? L(c.title) : c.title).font(.body).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if isCurrent {
                        Button { newTitle = c.title; renaming = c.id } label: {
                            Image(systemName: "pencil").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("إعادة تسمية")
                    }
                }
                .padding(.vertical, 12).padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isCurrent ? Color.white.opacity(0.1) : .clear))
                .contextMenu {
                    Button { newTitle = c.title; renaming = c.id } label: { Label("إعادة تسمية", systemImage: "pencil") }
                    Button(role: .destructive) { store.delete(c.id) } label: { Label("حذف", systemImage: "trash") }
                }
            }
            if shown.isEmpty {
                Text(searching ? L("لا توجد نتائج") : L("لا توجد محادثات بعد")).foregroundStyle(.secondary).padding(14)
            }
            let total = filtered.filter { !$0.messages.isEmpty || $0.id == store.currentID }.count
            if !searching, !showAll, total > recentLimit {
                Button { withAnimation { showAll = true } } label: {
                    Text("عرض الكل…").foregroundStyle(.secondary).padding(.vertical, 12).padding(.horizontal, 14)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: الأسفل: محادثة جديدة + الإعدادات

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                store.newConversation(); close()
            } label: {
                Label("محادثة جديدة", systemImage: "square.and.pencil")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).frame(height: 44)
                    .background(Color(red: 0.16, green: 0.42, blue: 1.0), in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("الإعدادات")
        }
        .padding(.top, 8)
    }
}

/// يمنع التحميل التلقائي لين يقرر المستخدم في شاشة الاسترداد.
enum SafeStart {
    @MainActor static var holding = Log.shared.previousRunCrashed
}

/// تطلع إذا التطبيق انقفل فجأة المرة اللي فاتت: تصدير السجل بدون ما نفتح المحادثة أو نحمّل النموذج.
struct CrashRecoveryView: View {
    let onContinue: (Bool) -> Void
    @State private var shareURL: URL?

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44)).foregroundStyle(.orange)
            Text("أُغلق التطبيق فجأة في المرة السابقة").font(.title3.weight(.semibold))
            Text(L("كان حينها في: %@", Log.shared.previousStage.isEmpty ? L("غير معروف") : Log.shared.previousStage))
                .font(.footnote).foregroundStyle(.secondary)
            Text("صدِّر السجل وأرسله لمعرفة السبب. بعدها يمكنك المتابعة كالمعتاد، أو الفتح دون تحميل النموذج إذا تكرر الإغلاق.")
                .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .padding(.horizontal, 24)
            Button {
                shareURL = Log.shared.export()
            } label: {
                Label("صدِّر السجل", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            Button { onContinue(true) } label: { Text("تابع كالمعتاد").frame(maxWidth: .infinity).padding(.vertical, 6) }
                .buttonStyle(.bordered)
            Button { onContinue(false) } label: { Text("افتح دون تحميل النموذج").frame(maxWidth: .infinity).padding(.vertical, 6) }
                .buttonStyle(.bordered)
            Spacer()
        }
        .padding(24)
        .background(Theme.bg.ignoresSafeArea())
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let u = shareURL { ActivityView(items: [u]) }
        }
    }
}
