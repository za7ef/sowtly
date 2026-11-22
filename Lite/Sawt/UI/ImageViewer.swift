import SwiftUI
import PencilKit
import Photos

// MARK: - عارض الصور المرسومة (ملء الشاشة) مع أدوات التعديل

/// عارض بملء الشاشة للصورة المرسومة: إغلاق، قائمة «…»، حفظ، «مشاركة»، وتحت أربع أدوات:
/// «تعديل» (تعليمة عامة + ملاحظات على نقاط)، «تغيير الحجم» (تكملة الأطراف)، «إضافة علامات توضيحية»، «إزالة».
struct ImageViewer: View {
    let ui: UIImage
    let prompt: String?
    @Environment(\.dismiss) private var dismiss
    @State private var tool: Tool?
    @State private var toast: String?
    @State private var alert: String?
    @State private var showPrompt = false
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    enum Tool: String, Identifiable { case notes, markup, remove; var id: String { rawValue } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: ui).resizable().scaledToFit()
                .scaleEffect(zoom).offset(offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .gesture(MagnifyGesture()
                    .onChanged { v in zoom = max(1, min(5, lastZoom * v.magnification)) }
                    .onEnded { _ in lastZoom = zoom; if zoom == 1 { withAnimation { offset = .zero }; lastOffset = .zero } })
                .simultaneousGesture(DragGesture()
                    .onChanged { v in
                        guard zoom > 1 else { return }
                        offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height)
                    }
                    .onEnded { _ in lastOffset = offset })
                .onTapGesture(count: 2) { withAnimation { zoom = 1; lastZoom = 1; offset = .zero; lastOffset = .zero } }
                .accessibilityLabel("الصورة المرسومة")
            VStack {
                topBar
                Spacer()
                if showPrompt, let p = prompt, !p.isEmpty {
                    Text(p).font(.caption).foregroundStyle(.white.opacity(0.85)).textSelection(.enabled)
                        .environment(\.layoutDirection, .leftToRight)
                        .padding(12).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                }
                if let t = toast {
                    Text(t).font(.footnote).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.white.opacity(0.15), in: Capsule())
                }
                bottomBar
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $tool) { t in
            switch t {
            case .notes: NotesEditView(ui: ui) { text, plan in send(text, plan) }
            case .markup: MarkupView(ui: ui) { text, plan in send(text, plan) }
            case .remove: RemoveView(ui: ui) { text, plan in send(text, plan) }
            }
        }
        .alert(alert ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("حسنًا", role: .cancel) {}
        }
    }

    // MARK: الأشرطة

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: { circle("xmark") }.accessibilityLabel("إغلاق")
            Spacer()
            Menu {
                Button { UIPasteboard.general.image = ui; flash(L("نُسخت")) } label: { Label("نسخ الصورة", systemImage: "doc.on.doc") }
                if let p = prompt, !p.isEmpty {
                    Button { UIPasteboard.general.string = p; flash(L("نُسخ الوصف")) } label: { Label("نسخ الوصف", systemImage: "text.quote") }
                    Button { withAnimation { showPrompt.toggle() } } label: {
                        Label(showPrompt ? L("إخفاء الوصف") : L("عرض الوصف"), systemImage: "text.alignleft")
                    }
                }
            } label: { circle("ellipsis") }
            .accessibilityLabel("خيارات")
            Button { save() } label: { circle("arrow.down.to.line") }.accessibilityLabel("حفظ في الصور")
            ShareLink(item: Image(uiImage: ui), preview: SharePreview("صورة من صوت لايت", image: Image(uiImage: ui))) {
                Text("مشاركة").font(.system(size: 16, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 18).frame(height: 44)
                    .background(.white, in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var bottomBar: some View {
        HStack(alignment: .top, spacing: 8) {
            toolButton("تعديل", "paintbrush.pointed") { open(.notes) }
            Menu {
                ForEach(Self.aspects, id: \.title) { a in
                    Button { resize(a) } label: { Label(L(a.title) + " (\(a.w):\(a.h))", systemImage: a.icon) }
                }
            } label: { toolLabel("تغيير الحجم", "aspectratio") }
            .accessibilityLabel("تغيير الحجم")
            toolButton("إضافة علامات توضيحية", "pencil.tip.crop.circle") { open(.markup) }
            toolButton("إزالة", "eraser") { open(.remove) }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 12)
    }

    static let aspects: [(title: String, w: Int, h: Int, icon: String)] = [
        ("شاشة عريضة", 16, 9, "rectangle.ratio.16.to.9"),
        ("أفقي", 4, 3, "rectangle.ratio.4.to.3"),
        ("قصة", 9, 16, "rectangle.ratio.9.to.16"),
        ("عمودي", 3, 4, "rectangle.ratio.3.to.4"),
        ("مربع", 1, 1, "square"),
    ]

    private func circle(_ icon: String) -> some View {
        Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.white.opacity(0.14), in: Circle())
    }

    private func toolLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(.white.opacity(0.14), in: Circle())
            Text(L(title)).font(.caption2).foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func toolButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { toolLabel(title, icon) }.buttonStyle(.plain).accessibilityLabel(L(title))
    }

    // MARK: الأفعال

    /// المحرك المختار لو يقدر يعدّل ومنزّل، وإلا رسالة توضح
    static func editEngine() -> (ImageEngine?, String?) {
        guard let e = ImageEngine.selected, e.canEdit else {
            return (nil, L("أدوات التعديل تعمل مع «دقيق» أو «واقعي+». اختر أحدهما من زر + ← محرك الصور."))
        }
        guard SDModels.installed(e) else { return (nil, L("نموذج %@ غير محمَّل. حمِّله من الإعدادات ← الصور.", e.title)) }
        if ChatStore.shared.isGenerating { return (nil, L("يوجد رد أو صورة قيد التنفيذ الآن. انتظر حتى تنتهي.")) }
        return (e, nil)
    }

    private func open(_ t: Tool) {
        let (e, why) = Self.editEngine()
        guard e != nil else { alert = why; return }
        tool = t
    }

    private func resize(_ a: (title: String, w: Int, h: Int, icon: String)) {
        var plan = EditPlan(kind: .resize)
        plan.aspectW = a.w; plan.aspectH = a.h
        plan.basePrompt = prompt
        send("غيّر حجم الصورة: \(a.title) (\(a.w):\(a.h))", plan)
    }

    private func send(_ text: String, _ plan: EditPlan) {
        let (e, why) = Self.editEngine()
        guard e != nil else { alert = why; return }
        guard let a = try? Attachments.addImage(ui, name: "صورة") else { alert = L("تعذّر تجهيز الصورة."); return }
        tool = nil
        dismiss()
        ChatStore.shared.generateImage(text, source: a, plan: plan)
    }

    private func flash(_ s: String) {
        withAnimation { toast = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { if toast == s { toast = nil } } }
    }

    private func save() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else {
                Task { @MainActor in flash(L("اسمح بالحفظ من الإعدادات")) }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAsset(from: ui)
            } completionHandler: { ok, _ in
                Task { @MainActor in flash(ok ? L("حُفظت ✓") : L("لم تُحفظ")) }
            }
        }
    }
}

// MARK: - أدوات مشتركة

enum EditFiles {
    /// يحفظ PNG مؤقت للقناع أو الصورة المعلّمة
    static func write(_ img: UIImage, _ tag: String) -> URL? {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("edit-\(UUID().uuidString)-\(tag).png")
        guard let d = img.pngData(), (try? d.write(to: u, options: .atomic)) != nil else { return nil }
        return u
    }

    /// حجم الصورة داخل مساحة (احتواء)
    static func fitted(_ img: CGSize, in box: CGSize) -> CGSize {
        let s = min(box.width / max(1, img.width), box.height / max(1, img.height))
        return CGSize(width: img.width * s, height: img.height * s)
    }

    /// صورة بحجم ui (scale 1)
    static func render(_ size: CGSize, _ draw: (CGContext) -> Void) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { draw($0.cgContext) }
    }
}

/// رأس الأدوات: رجوع، عنوان، وزر على اليسار
private struct ToolHeader<Trailing: View>: View {
    let title: String
    let back: () -> Void
    @ViewBuilder let trailing: Trailing
    var body: some View {
        HStack {
            Button(action: back) {
                Image(systemName: "chevron.forward").font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44).background(.white.opacity(0.14), in: Circle())
            }
            .accessibilityLabel("رجوع")
            Spacer()
            Text(L(title)).font(.headline)
            Spacer()
            trailing
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

// MARK: - «تعديل»: تعليمة عامة + ملاحظات على نقاط

struct NotesEditView: View {
    let ui: UIImage
    let onSend: (String, EditPlan) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var notes: [(p: CGPoint, text: String)] = []
    @State private var pending: CGPoint?
    @State private var noteText = ""
    @State private var general = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                ToolHeader(title: "تحرير الصورة", back: { dismiss() }) { Color.clear.frame(width: 44, height: 44) }
                GeometryReader { geo in
                    let size = EditFiles.fitted(ui.size, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: ui).resizable().frame(width: size.width, height: size.height)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        ForEach(Array(notes.enumerated()), id: \.offset) { i, n in
                            Text("\(i + 1)").font(.caption.bold()).foregroundStyle(.black)
                                .frame(width: 26, height: 26).background(.white, in: Circle())
                                .shadow(radius: 3)
                                .position(x: n.p.x * size.width, y: n.p.y * size.height)
                                .onTapGesture { notes.remove(at: i) }
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { loc in
                        pending = CGPoint(x: min(1, max(0, loc.x / size.width)), y: min(1, max(0, loc.y / size.height)))
                        noteText = ""
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal)
                Text(notes.isEmpty ? L("اضغط على الصورة لإضافة ملاحظات دقيقة حول التعديل")
                                   : L("الملاحظات تعدّل ما حول النقاط فقط. اضغط على رقم لإزالته."))
                    .font(.footnote).foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center).padding(.horizontal)
                ForEach(Array(notes.enumerated()), id: \.offset) { i, n in
                    Text("\(i + 1). \(n.text)").font(.footnote).foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24)
                }
                HStack(spacing: 10) {
                    TextField("صِف التعديلات العامة", text: $general, axis: .vertical)
                        .lineLimit(1 ... 4).focused($focused)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    Button { send() } label: {
                        Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 40, height: 40).background(.white, in: Circle())
                    }
                    .disabled(general.trimmed.isEmpty && notes.isEmpty)
                    .opacity(general.trimmed.isEmpty && notes.isEmpty ? 0.4 : 1)
                    .accessibilityLabel("إرسال")
                }
                .padding(.horizontal).padding(.bottom, 10)
            }
        }
        .preferredColorScheme(.dark)
        .alert("ماذا تريد أن يتغيّر هنا؟", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            TextField("مثلًا: اجعلها حمراء", text: $noteText)
            Button("إضافة") {
                if let p = pending, !noteText.trimmed.isEmpty { notes.append((p, noteText.trimmed)) }
                pending = nil
            }
            Button("إلغاء", role: .cancel) { pending = nil }
        }
    }

    /// مكان النقطة بالكلام (للتعليمة)
    static func region(_ p: CGPoint) -> String {
        let v = p.y < 0.34 ? "فوق" : (p.y > 0.66 ? "تحت" : "بالوسط")
        let h = p.x < 0.34 ? "يسار" : (p.x > 0.66 ? "يمين" : "")
        return h.isEmpty ? v : (v == "بالوسط" ? "بالوسط \(h)" : "\(v) \(h)")
    }

    private func send() {
        var lines: [String] = []
        if !general.trimmed.isEmpty { lines.append(general.trimmed) }
        for (i, n) in notes.enumerated() {
            lines.append("\(i + 1). عند النقطة \(Self.region(n.p)) (x≈\(Int(n.p.x * 100))٪، y≈\(Int(n.p.y * 100))٪): \(n.text)")
        }
        var plan = EditPlan(kind: .instruct)
        // ملاحظات بدون تعليمة عامة: التعديل يصير حول النقاط بس (قناع دوائر)، والباقي يبقى بالبكسل
        if general.trimmed.isEmpty, !notes.isEmpty {
            let s = ui.size
            let r = min(s.width, s.height) * 0.16
            let mask = EditFiles.render(s) { c in
                c.setFillColor(UIColor.black.cgColor); c.fill(CGRect(origin: .zero, size: s))
                c.setFillColor(UIColor.white.cgColor)
                for n in notes {
                    c.fillEllipse(in: CGRect(x: n.p.x * s.width - r, y: n.p.y * s.height - r, width: 2 * r, height: 2 * r))
                }
            }
            plan.mask = EditFiles.write(mask, "mask")
        }
        onSend(lines.joined(separator: "\n"), plan)
    }
}

// MARK: - «إضافة علامات توضيحية»: رسم بـPencilKit ثم تعليمة

struct MarkupView: View {
    let ui: UIImage
    let onSend: (String, EditPlan) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var drawing = PKDrawing()
    @State private var canvasSize: CGSize = .zero
    @State private var asking = false
    @State private var instruction = ""
    @State private var undoTick = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                ToolHeader(title: "علامات توضيحية", back: { dismiss() }) {
                    HStack(spacing: 8) {
                        Button { undoTick += 1 } label: {
                            Image(systemName: "arrow.uturn.backward").frame(width: 40, height: 40)
                                .background(.white.opacity(0.14), in: Circle())
                        }
                        .disabled(drawing.strokes.isEmpty)
                        .accessibilityLabel("تراجع")
                        Button { asking = true } label: {
                            Image(systemName: "arrow.left").font(.system(size: 16, weight: .bold)).foregroundStyle(.black)
                                .frame(width: 40, height: 40).background(.white, in: Circle())
                        }
                        .disabled(drawing.strokes.isEmpty)
                        .opacity(drawing.strokes.isEmpty ? 0.4 : 1)
                        .accessibilityLabel("التالي")
                    }
                }
                GeometryReader { geo in
                    let size = EditFiles.fitted(ui.size, in: geo.size)
                    ZStack {
                        Image(uiImage: ui).resizable().frame(width: size.width, height: size.height)
                        PencilCanvas(drawing: $drawing, undoTick: undoTick)
                            .frame(width: size.width, height: size.height)
                    }
                    .frame(width: size.width, height: size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { canvasSize = size }
                    .onChange(of: geo.size) { _, g in canvasSize = EditFiles.fitted(ui.size, in: g) }
                }
                .padding(.horizontal)
                Text("ارسم على المكان الذي تريد تعديله، ثم اضغط السهم").font(.footnote).foregroundStyle(.white.opacity(0.7))
                    .padding(.bottom, 90)   // مكان شريط أدوات القلم
            }
        }
        .preferredColorScheme(.dark)
        .alert("ماذا تريد أن يحدث في المكان المحدد؟", isPresented: $asking) {
            TextField("مثلًا: ضع هنا شجرة", text: $instruction)
            Button("إرسال") { send() }
            Button("إلغاء", role: .cancel) {}
        }
    }

    private func send() {
        guard !instruction.trimmed.isEmpty, canvasSize.width > 0 else { return }
        let s = ui.size
        let k = s.width / canvasSize.width
        let rect = CGRect(origin: .zero, size: canvasSize)
        // ١) الصورة مع العلامات (المرجع الثاني)
        let marks = drawing.image(from: rect, scale: k)
        let annotated = EditFiles.render(s) { _ in
            ui.draw(in: CGRect(origin: .zero, size: s))
            marks.draw(in: CGRect(origin: .zero, size: s))
        }
        // ٢) القناع: نفس الخطوط بالأبيض على أسود، أعرض شوي عشان تغطي المكان المقصود
        var white = PKDrawing()
        for st in drawing.strokes {
            white.strokes.append(PKStroke(ink: PKInk(st.ink.inkType, color: .white), path: st.path,
                                          transform: st.transform, mask: st.mask))
        }
        let whiteImg = white.image(from: rect, scale: k)
        let mask = EditFiles.render(s) { c in
            c.setFillColor(UIColor.black.cgColor); c.fill(CGRect(origin: .zero, size: s))
            whiteImg.draw(in: CGRect(origin: .zero, size: s))
        }
        var plan = EditPlan(kind: .markup)
        plan.annotated = EditFiles.write(annotated, "marked")
        plan.mask = EditFiles.write(mask, "mask")
        onSend(instruction.trimmed, plan)
    }
}

/// PKCanvasView بخلفية شفافة وشريط أدوات النظام (قلم، ممحاة، أشكال، ألوان، حجم)
struct PencilCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var undoTick: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let v = PKCanvasView()
        v.backgroundColor = .clear
        v.isOpaque = false
        v.drawingPolicy = .anyInput
        v.tool = PKInkingTool(.pen, color: .systemRed, width: 8)
        v.delegate = context.coordinator
        v.drawing = drawing
        let picker = PKToolPicker()
        picker.setVisible(true, forFirstResponder: v)
        picker.addObserver(v)
        context.coordinator.picker = picker
        DispatchQueue.main.async { v.becomeFirstResponder() }
        return v
    }

    func updateUIView(_ v: PKCanvasView, context: Context) {
        if undoTick != context.coordinator.lastUndo {
            context.coordinator.lastUndo = undoTick
            if !v.drawing.strokes.isEmpty {
                var d = v.drawing
                d.strokes.removeLast()
                v.drawing = d
            }
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let parent: PencilCanvas
        var picker: PKToolPicker?
        var lastUndo = 0
        init(_ p: PencilCanvas) { parent = p }
        func canvasViewDrawingDidChange(_ v: PKCanvasView) { parent.drawing = v.drawing }
    }
}

// MARK: - «إزالة»: فرشاة على المنطقة

struct RemoveView: View {
    let ui: UIImage
    let onSend: (String, EditPlan) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var models = SDModels.shared
    /// خطوط الفرشاة بنسب الصورة (0…1) وعرض كل خط بالنسبة لعرض الصورة
    @State private var strokes: [(pts: [CGPoint], width: CGFloat)] = []
    @State private var brush: CGFloat = 0.06
    @State private var painting = false

    private var needsLaMa: Bool { ImageEngine.selected == .klein && !LaMa.installed }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                ToolHeader(title: "إزالة منطقة", back: { dismiss() }) {
                    Button { send() } label: {
                        Text("إرسال").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(strokes.isEmpty || needsLaMa ? .white.opacity(0.4) : .black)
                            .padding(.horizontal, 16).frame(height: 40)
                            .background(strokes.isEmpty || needsLaMa ? .white.opacity(0.14) : .white, in: Capsule())
                    }
                    .disabled(strokes.isEmpty || needsLaMa)
                }
                if needsLaMa { lamaBanner }
                HStack(spacing: 0) {
                    GeometryReader { geo in
                        let size = EditFiles.fitted(ui.size, in: geo.size)
                        ZStack {
                            Image(uiImage: ui).resizable().frame(width: size.width, height: size.height)
                            Canvas { ctx, _ in
                                for s in strokes {
                                    var p = Path()
                                    p.addLines(s.pts.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
                                    if s.pts.count == 1, let q = s.pts.first {
                                        let r = s.width * size.width / 2
                                        p = Path(ellipseIn: CGRect(x: q.x * size.width - r, y: q.y * size.height - r, width: 2 * r, height: 2 * r))
                                        ctx.fill(p, with: .color(.blue.opacity(0.5)))
                                    } else {
                                        ctx.stroke(p, with: .color(.blue.opacity(0.5)),
                                                   style: StrokeStyle(lineWidth: s.width * size.width, lineCap: .round, lineJoin: .round))
                                    }
                                }
                            }
                            .frame(width: size.width, height: size.height)
                        }
                        .frame(width: size.width, height: size.height)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { v in
                                let p = CGPoint(x: min(1, max(0, v.location.x / size.width)), y: min(1, max(0, v.location.y / size.height)))
                                if !painting || strokes.isEmpty {
                                    painting = true
                                    strokes.append(([p], brush))
                                } else {
                                    strokes[strokes.count - 1].pts.append(p)
                                }
                            }
                            .onEnded { _ in painting = false })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    // حجم الفرشاة (عمودي)
                    VStack(spacing: 10) {
                        Circle().fill(.white).frame(width: 18, height: 18)
                        Slider(value: $brush, in: 0.02 ... 0.14)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 180, height: 30)
                            .frame(width: 30, height: 180)
                        Circle().fill(.white).frame(width: 6, height: 6)
                    }
                    .padding(.trailing, 6)
                    .accessibilityLabel("حجم الفرشاة")
                }
                .padding(.horizontal, 8)
                HStack {
                    Button { if !strokes.isEmpty { strokes.removeLast() } } label: {
                        Label("تراجع", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(strokes.isEmpty)
                    Spacer()
                    Text("لوّن فوق الشيء الذي تريد إزالته").font(.footnote).foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain).foregroundStyle(.white)
                .padding(.horizontal).padding(.bottom, 12)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var lamaBanner: some View {
        VStack(spacing: 8) {
            Text("الإزالة في «دقيق» تستخدم أداة LaMa (حوالي ٢١٦ ميغابايت) وتحتاج إلى تحميلها مرة واحدة.")
                .font(.footnote).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
            if let p = models.lamaProgress {
                ProgressView(value: p).tint(.white)
                Button("إلغاء") { models.cancelLaMa() }.font(.footnote)
            } else {
                Button("حمِّل أداة الإزالة") { models.downloadLaMa() }
                    .font(.footnote.bold()).foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 8).background(.white, in: Capsule())
            }
        }
        .padding(12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    private func send() {
        guard !strokes.isEmpty else { return }
        let s = ui.size
        let mask = EditFiles.render(s) { c in
            c.setFillColor(UIColor.black.cgColor); c.fill(CGRect(origin: .zero, size: s))
            c.setStrokeColor(UIColor.white.cgColor); c.setFillColor(UIColor.white.cgColor)
            c.setLineCap(.round); c.setLineJoin(.round)
            for st in strokes {
                let w = st.width * s.width
                if st.pts.count == 1, let q = st.pts.first {
                    c.fillEllipse(in: CGRect(x: q.x * s.width - w / 2, y: q.y * s.height - w / 2, width: w, height: w))
                    continue
                }
                c.setLineWidth(w)
                c.beginPath()
                c.addLines(between: st.pts.map { CGPoint(x: $0.x * s.width, y: $0.y * s.height) })
                c.strokePath()
            }
        }
        var plan = EditPlan(kind: .remove)
        plan.mask = EditFiles.write(mask, "mask")
        onSend("إزالة المنطقة المحددة من الصورة", plan)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
