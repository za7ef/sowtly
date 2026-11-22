import SwiftUI
import UIKit
import Photos

/// صورة مولّدة داخل المحادثة: حفظ، مشاركة، نسخ، والوصف اللي انرسمت منه
struct GenImageView: View {
    let file: String
    let prompt: String?
    var negative: String? = nil
    @State private var saved: String?
    @State private var showPrompt = false
    @State private var full = false

    private var url: URL { ImageGenerator.outDir.appendingPathComponent(file) }

    var body: some View {
        if let ui = UIImage(contentsOfFile: url.path) {
            VStack(alignment: .leading, spacing: 8) {
                Image(uiImage: ui)
                    .resizable().scaledToFit()
                    .frame(maxWidth: 320, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .onTapGesture { full = true }
                    .accessibilityLabel("الصورة المرسومة")
                HStack(spacing: 20) {
                    Button { save(ui) } label: { Image(systemName: "square.and.arrow.down") }
                        .accessibilityLabel("حفظ في الصور")
                    ShareLink(item: Image(uiImage: ui), preview: SharePreview("صورة من صوت لايت", image: Image(uiImage: ui))) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("مشاركة")
                    Button { UIPasteboard.general.image = ui; saved = L("نُسخت") } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel("نسخ الصورة")
                    if let p = prompt, !p.isEmpty {
                        Button { withAnimation { showPrompt.toggle() } } label: { Image(systemName: "text.quote") }
                            .accessibilityLabel("الوصف المستخدم")
                    }
                    if let s = saved { Text(s).font(.caption) }
                }
                .font(.system(size: 14))
                .foregroundStyle(Color.gray.opacity(0.75))
                .buttonStyle(.plain)
                if showPrompt, let p = prompt {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("الوصف الذي رُسمت منه").font(.caption).foregroundStyle(.secondary)
                        Text(p).font(.caption).textSelection(.enabled)
                            .environment(\.layoutDirection, .leftToRight)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let n = negative, !n.isEmpty {
                            Text(L("مستبعَد: %@", n)).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                .environment(\.layoutDirection, .leftToRight)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .fullScreenCover(isPresented: $full) {
                ImageViewer(ui: ui, prompt: prompt)
            }
        } else {
            Label("حُذفت الصورة", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save(_ ui: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else {
                Task { @MainActor in saved = L("اسمح بالحفظ من الإعدادات") }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAsset(from: ui)
            } completionHandler: { ok, _ in
                Task { @MainActor in saved = ok ? L("حُفظت ✓") : L("لم تُحفظ") }
            }
        }
    }
}

