import Foundation

/// أصوات ما ننشرها داخل التطبيق (رخصتها ما تسمح بإعادة التوزيع)، فتنزل من مصدرها الأصلي على جوالك لما تطلبها.
@MainActor
final class VoiceDownloads: ObservableObject {
    static let shared = VoiceDownloads()

    struct Item: Identifiable {
        let id: String          // نفس معرّف VoiceOption
        let folder: String
        let bases: [String]     // بدايات روابط التنزيل بالترتيب (الأول أساسي والباقي احتياط)
        let files: [(remote: [String], local: String)]   // أكثر من جزء = تنضم بالترتيب
        let approx: String
        let gb: Double
    }

    static let items: [Item] = [
        // نبرة السعودية (Apache-2.0، من oddadmix/Nabra-Saudi-82M): المصدر الأصلي PyTorch بس،
        // فننزّل نسختنا المحوّلة لـONNX من إصدار الأصوات العام
        Item(id: "nabra-saudi", folder: "nabra-saudi",
             bases: ["https://github.com/za7ef/sawt-releases/releases/download/voices/",
                     "https://github.com/za7ef/sowtly/releases/download/voices/"],
             files: [((0..<9).map { String(format: "nabra-saudi-model.int8.onnx.part%02d", $0) }, "model.int8.onnx"),
                     (["nabra-saudi-tokens.txt"], "tokens.txt"),
                     (["nabra-saudi-voices.bin"], "voices.bin")],
             approx: "~84 MB", gb: 0.1),
        Item(id: "piper-miro", folder: "piper-miro",
             bases: ["https://huggingface.co/csukuangfj/vits-piper-ar_JO-SA_miro_V2-high-int8/resolve/main/"],
             files: [(["ar_JO-SA_miro_V2-high.onnx"], "ar_JO-SA_miro_V2-high.onnx"), (["tokens.txt"], "tokens.txt")],
             approx: "~19 MB", gb: 0.05),
        // Supertonic 3 (Supertone، رخصة OpenRAIL-M): نسخة sherpa-onnx بدقة int8، من مستودع ملفاتها على Hugging Face
        Item(id: "supertonic", folder: "supertonic-3",
             bases: ["https://huggingface.co/csukuangfj2/sherpa-onnx-supertonic-3-tts-int8-2026-05-11/resolve/main/"],
             files: ["duration_predictor.int8.onnx", "text_encoder.int8.onnx", "vector_estimator.int8.onnx",
                     "vocoder.int8.onnx", "tts.json", "unicode_indexer.bin", "voice.bin", "LICENSE"].map { ([$0], $0) },
             approx: "~129 MB", gb: 0.15),
    ]

    enum State: Equatable { case idle, downloading(Double), failed(String) }
    @Published var state: [String: State] = [:]

    nonisolated static var root: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voices", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        var u = d; try? u.setResourceValues(v)
        return d
    }

    func installed(_ item: Item) -> Bool {
        item.files.allSatisfy { FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("\(item.folder)/\($0.local)").path) }
    }

    func download(_ item: Item) {
        if case .downloading = state[item.id] { return }
        state[item.id] = .downloading(0)
        Task {
            Storage.otherDownloads += 1
            defer { Storage.otherDownloads -= 1 }
            if let why = Storage.spaceProblem(forGB: item.gb) { state[item.id] = .failed(why); return }
            guard await NetworkGate.shared.permit(L("تحميل صوت %@", Catalog.allVoices.first { $0.id == item.id }?.title ?? item.id)) else {
                state[item.id] = .idle; return
            }
            let dir = Self.root.appendingPathComponent(item.folder, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for (i, f) in item.files.enumerated() {
                    let dest = dir.appendingPathComponent(f.local)
                    let partial = dir.appendingPathComponent(f.local + ".download")
                    try? FileManager.default.removeItem(at: dest)
                    try? FileManager.default.removeItem(at: partial)
                    FileManager.default.createFile(atPath: partial.path, contents: nil)
                    let out = try FileHandle(forWritingTo: partial)
                    defer { try? out.close() }
                    for r in f.remote {
                        var got: URL?
                        var lastErr: Error = URLError(.badServerResponse)
                        for base in item.bases {
                            guard let url = URL(string: base + r) else { continue }
                            do {
                                let (t, resp) = try await URLSession.shared.download(from: url)
                                if (resp as? HTTPURLResponse)?.statusCode == 200 { got = t; break }
                                try? FileManager.default.removeItem(at: t)
                            } catch { lastErr = error }
                            slog("voice: \(r) not at \(base), trying next")
                        }
                        guard let tmp = got else { throw lastErr }
                        try out.write(contentsOf: try Data(contentsOf: tmp, options: .mappedIfSafe))
                        try? FileManager.default.removeItem(at: tmp)
                    }
                    try out.close()
                    try FileManager.default.moveItem(at: partial, to: dest)
                    state[item.id] = .downloading(Double(i + 1) / Double(item.files.count))
                }
                state[item.id] = .idle
                slog("voice: downloaded \(item.id)")
                // نبرة السعودية هي المقترحة للمكالمات: نختارها أول ما تنزل
                if item.id == "nabra-saudi" { AppSettings.shared.voiceID = item.id; ModelManager.shared.voiceChanged() }
                objectWillChange.send()
            } catch {
                try? FileManager.default.removeItem(at: dir)
                state[item.id] = .failed(SawtError.friendly(error).localizedDescription)
                slog("voice: download failed \(item.id) \(error)")
            }
        }
    }

    func delete(_ item: Item) {
        try? FileManager.default.removeItem(at: Self.root.appendingPathComponent(item.folder))
        objectWillChange.send()
    }
}
