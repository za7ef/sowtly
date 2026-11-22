import SwiftUI

struct ModelsView: View {
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    /// داخل الإعدادات (بدون NavigationStack وزر «تم»)
    var embedded = false
    @AppStorage("cloudActive") private var cloudRaw = ""
    @State private var customRepo = ""
    @State private var refresh = 0
    @State private var confirmDelete: LLMOption?
    @State private var confirmAll = false
    @State private var files: [Storage.ModelFolder] = []
    /// تبويب النماذج اللغوية: على الجهاز (MLX على كرت الشاشة) أو سحابي
    @State private var tab = CloudLLM.active != nil ? "cloud" : "gpu"

    private let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
        }
    }

    private var content: some View {
            List {
                Section {
                    Picker("اعرض", selection: $tab) {
                        Text("على الجهاز").tag("gpu")
                        Text("النماذج السحابية").tag("cloud")
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if tab == "cloud" {
                    CloudSections(showActivate: true)
                } else {
                Section {
                    ForEach(Catalog.builtInLLMs) { row($0) }
                } header: {
                    Text("النماذج على الجهاز")
                } footer: {
                    Text(L("ذاكرة جهازك نحو %@ GB. تُحمَّل النماذج مرة واحدة وتعمل دون إنترنت.", String(format: "%.0f", ramGB)))
                }
                }

                Section {
                    if files.isEmpty {
                        Text("لا توجد ملفات نماذج على الجهاز").foregroundStyle(.secondary)
                    }
                    ForEach(files) { f in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(f.name).font(.subheadline).lineLimit(1)
                                    .environment(\.layoutDirection, .leftToRight)
                                Text(f.statusText).font(.caption).foregroundStyle(f.isOrphan ? .orange : .secondary)
                            }
                            Spacer()
                            Text(Storage.format(f.bytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            Button(role: .destructive) {
                                models.deleteFolder(f)
                                reloadFiles()
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("حذف كل النماذج", role: .destructive) { confirmAll = true }
                } header: {
                    Text("الملفات على الجهاز")
                } footer: {
                    Text("كل مجلدات النماذج، بما فيها التحميلات غير المكتملة.")
                }
            }
            .task { reloadFiles() }
            .id(refresh)
            .confirmationDialog("حذف كل النماذج من الجهاز؟", isPresented: $confirmAll, titleVisibility: .visible) {
                Button("حذف الكل", role: .destructive) { models.deleteAllModels(); reloadFiles() }
            }
            .navigationTitle("النماذج")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } }
                }
            }
            .confirmationDialog("حذف النموذج؟", isPresented: Binding(get: { confirmDelete != nil },
                                                                    set: { if !$0 { confirmDelete = nil } }),
                                titleVisibility: .visible) {
                Button("حذف من الجهاز", role: .destructive) {
                    if let m = confirmDelete {
                        models.delete(m)
                        reloadFiles()
                        if m.custom { Catalog.removeCustom(m.id); refresh += 1 }
                    }
                }
            }
    }

    @ViewBuilder private func row(_ m: LLMOption) -> some View {
        let active = settings.llmID == m.id && cloudRaw.isEmpty
        let isDown = models.downloaded.contains(m.id)
        let downloading = models.downloadingID == m.id
        let tooBig = m.ramGB > 0 && m.ramGB > ramGB * 0.55
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(m.title).font(.headline)
                if m.vision {
                    Image(systemName: "eye").font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("يفهم الصور")
                }
                if let tag = m.tag {
                    Text(tag).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .glassEffect(.regular.tint(Theme.accent.opacity(0.5)), in: .capsule)
                }
                Spacer()
                if active && models.llm.isReady {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            HStack(spacing: 12) {
                if m.sizeGB > 0 { Label(m.sizeText, systemImage: "arrow.down.circle") }
                if m.ramGB > 0 { Label(String(format: "%.1f GB", m.ramGB), systemImage: "memorychip") }
                Label(m.speed, systemImage: "bolt")
            }
            .font(.caption).foregroundStyle(.secondary)
            .environment(\.layoutDirection, AppLang.layout)
            if m.ramGB > 0 { fitChips(m) }
            Text(L("العربية: %@", m.arabic) + (tooBig ? L(" • قد يكون ثقيلًا على جهازك") : ""))
                .font(.caption).foregroundStyle(tooBig ? .orange : .secondary)

            if downloading, let p = models.llm.progress {
                ProgressView(value: p) {
                    Text(L("جارٍ التحميل… %@٪", String(Int(p * 100)))).font(.caption)
                }
            } else if active && models.llm == .preparing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("جارٍ تجهيز النموذج في الذاكرة…").font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                if downloading {
                    Button("إيقاف مؤقت") { models.pauseDownload() }.buttonStyle(.glass)
                } else if !(active && (models.llm.isReady || models.llm == .preparing)) {
                    Button(isDown ? L("تشغيل") : L("تحميل وتشغيل")) {
                        CloudLLM.setActive(nil)
                        models.activate(m)
                    }
                        .buttonStyle(.glassProminent)
                }
                if isDown || m.custom {
                    Button(role: .destructive) { confirmDelete = m } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.glass)
                }
                if case .failed(let e) = models.llm, active {
                    Text(e).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func phaseView(_ p: ModelManager.Phase) -> some View {
        switch p {
        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .loading(let v): ProgressView(value: v).frame(width: 60)
        case .preparing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("جارٍ التجهيز…").font(.caption) }
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle: EmptyView()
        }
    }

    private func reloadFiles() {
        Task {
            let down = models.downloaded
            let list = await Task.detached(priority: .utility) { Storage.modelFolders(downloaded: down) }.value
            files = list
        }
    }

    /// أي آيفونات تشغّله: للكتابة وللمكالمة، وهل يناسب هالجوال.
    @ViewBuilder private func fitChips(_ m: LLMOption) -> some View {
        let text = DeviceFit.minTier(needGB: DeviceFit.textNeed(m))
        let call = DeviceFit.minTier(needGB: DeviceFit.callNeed(m))
        let fit = DeviceFit.fitHere(m)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                chip(L("الكتابة: %@", text?.label ?? L("ثقيل على iPhone")), icon: "text.bubble")
                chip(L("المكالمة: %@", call?.label ?? L("ثقيل على iPhone")), icon: "phone")
            }
            switch fit {
            case .both:
                Label("يناسب جهازك", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            case .textOnly:
                Label("يناسب جهازك للكتابة، وقد تتوقف المكالمة", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .none:
                Label("ثقيل على جهازك", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            case .unknown:
                EmptyView()
            }
        }
        .font(.caption2.weight(.semibold))
    }

    private func chip(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(.secondary)
            .glassEffect(.regular, in: .capsule)
    }
}
