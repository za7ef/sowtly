import Foundation
import MLXLMCommon

/// نموذج سحابي للدردشة (اختياري): يتفعّل من صفحة النماذج ← «النماذج السحابية»
/// المفاتيح نفسها حقت الوكيل (سلسلة المفاتيح). النماذج المحلية تبقى الاحتياط.
enum CloudLLM {
    /// داخل مكالمة؟ (CallController يحطها) — السحابي في المكالمة بس لو فعّلته
    @TaskLocal static var inCall = false

    static var consent: Bool { UserDefaults.standard.bool(forKey: "cloudConsent") }
    static var useInCalls: Bool { UserDefaults.standard.bool(forKey: "cloudCalls") }

    /// المزوّد المفعّل للدردشة (لو له مفتاح وتمت الموافقة)
    static var active: CloudProvider? {
        guard let r = UserDefaults.standard.string(forKey: "cloudActive"), !r.isEmpty,
              let p = CloudProvider(rawValue: r), p.hasKey, consent else { return nil }
        return p
    }

    /// يُستخدم للرد الحين؟ (ما يمشي لو فيه إجبار للمعالج مثل اختبار المعالج)
    static func forThisReply(forcedDevice: String?) -> CloudProvider? {
        guard forcedDevice == nil, let p = active else { return nil }
        if inCall && !useInCalls { return nil }
        return p
    }

    static func setActive(_ p: CloudProvider?) {
        UserDefaults.standard.set(p?.rawValue ?? "", forKey: "cloudActive")
        slog("llm: cloud active → \(p?.rawValue ?? "off")")
    }

    private static func mime(_ u: URL) -> String {
        switch u.pathExtension.lowercased() {
        case "png": "image/png"
        case "heic": "image/heic"
        case "webp": "image/webp"
        default: "image/jpeg"
        }
    }

    /// حالة مشتركة بين التدفق والمراقب (وصول أول بايت / انتهاء المهلة)
    private final class Watch: @unchecked Sendable {
        private let lock = NSLock()
        private var _first = false, _timedOut: String?
        var first: Bool { lock.lock(); defer { lock.unlock() }; return _first }
        func gotFirst() { lock.lock(); _first = true; lock.unlock() }
        var timedOut: String? { lock.lock(); defer { lock.unlock() }; return _timedOut }
        func timeout(_ m: String) { lock.lock(); _timedOut = m; lock.unlock() }
    }

    static let firstByteTimeout: UInt64 = 20
    static let overallTimeout: UInt64 = 150

    /// تدفق الرد (SSE) من المزوّد — ما يعلق أبدًا: مهلة لأول رد ومهلة كاملة
    static func stream(_ p: CloudProvider, system: String, history: [Chat.Message], user: String,
                       maxTokens: Int, images: [URL]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let watch = Watch()
            let task = Task {
                var model = p.model
                var triedFallback = false
                while true {
                    do {
                        try await run(p, model: model, system: system, history: history, user: user,
                                      maxTokens: maxTokens, images: images, watch: watch, cont: cont)
                        cont.finish()
                        return
                    } catch let f as CloudAPI.Failure {
                        // Gemini عليه ضغط: نجرّب الموديل الاحتياطي مرة وحدة (قبل ما يطلع أي نص)
                        if f.code == 503, p.isGemini, !triedFallback, !watch.first, model != CloudAPI.geminiFallback {
                            triedFallback = true
                            model = CloudAPI.geminiFallback
                            slog("llm: gemini 503 → fallback \(model)")
                            continue
                        }
                        slog("llm: cloud error \(p.rawValue) \(f.code)")
                        cont.finish(throwing: f)
                        return
                    } catch {
                        if let t = watch.timedOut {
                            slog("llm: cloud timeout \(p.rawValue)")
                            cont.finish(throwing: CloudAPI.Failure(message: t, code: -1))
                            return
                        }
                        let ns = error as NSError
                        if error is CancellationError || ns.code == NSURLErrorCancelled { cont.finish(); return }
                        slog("llm: cloud net error \(p.rawValue) \(ns.code)")
                        let msg: String
                        switch ns.code {
                        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: msg = L("لا يوجد إنترنت — النموذج السحابي يحتاج إلى اتصال")
                        case NSURLErrorTimedOut: msg = L("لم يرد %@ في الوقت المحدد — حاول بعد قليل أو غيّر النموذج", p.short)
                        default: msg = L("تعذّر الاتصال بـ%@", p.short)
                        }
                        cont.finish(throwing: CloudAPI.Failure(message: msg))
                        return
                    }
                }
            }
            // المراقب: لو ما وصل شي خلال ٢٠ ثانية، أو طوّل الرد كله، نوقف بدل ما تبقى «...» للأبد
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: firstByteTimeout * 1_000_000_000)
                if Task.isCancelled { return }
                if !watch.first {
                    watch.timeout(L("لم يرد %1$@ خلال %2$@ ثانية — غالبًا بسبب ضغط عليه. حاول بعد قليل أو غيّر النموذج", p.short, String(firstByteTimeout)))
                    task.cancel(); return
                }
                try? await Task.sleep(nanoseconds: (overallTimeout - firstByteTimeout) * 1_000_000_000)
                if Task.isCancelled { return }
                watch.timeout(L("استغرق %@ وقتًا أطول من اللازم في الرد — تم إيقافه", p.short))
                task.cancel()
            }
            cont.onTermination = { _ in task.cancel(); watchdog.cancel() }
        }
    }

    private static func run(_ p: CloudProvider, model: String, system: String, history: [Chat.Message], user: String,
                            maxTokens: Int, images: [URL], watch: Watch,
                            cont: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let req = try request(p, model: model, system: system, history: history, user: user, maxTokens: maxTokens, images: images)
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if !(200...299).contains(code) {
            // البث وفيه خطأ: نقرا جسم الخطأ (JSON) ونطلع رسالة واضحة
            var body = Data()
            for try await b in bytes { body.append(b); if body.count > 20_000 { break } }
            let any = try? JSONSerialization.jsonObject(with: body)
            let j = (any as? [String: Any]) ?? (any as? [[String: Any]])?.first
            throw CloudAPI.Failure(message: CloudAPI.errorText(p, code: code, json: j), code: code)
        }
        var got = false
        var raw = ""   // لو الرد مو SSE (JSON عادي) نقراه بالنهاية
        for try await line in bytes.lines {
            if Task.isCancelled { throw CancellationError() }
            guard line.hasPrefix("data:") else { if raw.count < 20_000 { raw += line }; continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let d = payload.data(using: .utf8),
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            if let e = j["error"] as? [String: Any] {
                let c = (e["code"] as? Int) ?? 0
                throw CloudAPI.Failure(message: CloudAPI.errorText(p, code: c == 0 ? 500 : c, json: j), code: c)
            }
            let piece = delta(p, j)
            if !piece.isEmpty { got = true; watch.gotFirst(); cont.yield(piece) }
        }
        if Task.isCancelled { throw CancellationError() }
        if !got {
            if let d = raw.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: d) {
                let j = (any as? [String: Any]) ?? (any as? [[String: Any]])?.first
                if j?["error"] != nil {
                    let c = ((j?["error"] as? [String: Any])?["code"] as? Int) ?? 500
                    throw CloudAPI.Failure(message: CloudAPI.errorText(p, code: c, json: j), code: c)
                }
            }
            throw CloudAPI.Failure(message: L("أعاد %@ ردًّا فارغًا — حاول مرة أخرى أو غيّر النموذج", p.short), code: 0)
        }
    }

    private static func delta(_ p: CloudProvider, _ j: [String: Any]) -> String {
        switch p {
        case .openai, .openrouter:
            let ch = (j["choices"] as? [[String: Any]])?.first
            return ((ch?["delta"] as? [String: Any])?["content"] as? String) ?? ""
        case .anthropic:
            guard (j["type"] as? String) == "content_block_delta", let d = j["delta"] as? [String: Any],
                  (d["type"] as? String) == "text_delta" else { return "" }
            return d["text"] as? String ?? ""
        case .gemini, .geminiPaid:
            let cand = (j["candidates"] as? [[String: Any]])?.first
            let parts = (cand?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            return parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        }
    }

    private static func request(_ p: CloudProvider, model: String, system: String, history: [Chat.Message], user: String,
                                maxTokens: Int, images: [URL]) throws -> URLRequest {
        guard let key = p.key else { throw CloudAPI.Failure(message: L("لا يوجد مفتاح لـ%@ — أضفه في صفحة النماذج ← السحابية", p.short)) }
        // السجل: مستخدم/مساعد بالتناوب
        let hist = LLMService.strictAlternation(history + [.user(user)])
        let imgs: [(String, String)] = images.compactMap { u in
            guard let d = try? Data(contentsOf: u), d.count < 8_000_000 else { return nil }
            return (mime(u), d.base64EncodedString())
        }
        let tokens = max(maxTokens, 1024)   // النماذج السحابية تفكر داخليًا وتحتاج مساحة
        var req: URLRequest
        var body: [String: Any]
        switch p {
        case .openai, .openrouter:
            let or = p == .openrouter
            req = URLRequest(url: URL(string: or ? "https://openrouter.ai/api/v1/chat/completions" : "https://api.openai.com/v1/chat/completions")!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if or { req.setValue("Sawt", forHTTPHeaderField: "X-Title") }
            var msgs: [[String: Any]] = [["role": "system", "content": system]]
            for m in hist { msgs.append(["role": m.role == .assistant ? "assistant" : "user", "content": m.content]) }
            var content: [[String: Any]] = [["type": "text", "text": user]]
            for (mt, b) in imgs { content.append(["type": "image_url", "image_url": ["url": "data:\(mt);base64,\(b)"]]) }
            msgs.append(["role": "user", "content": content])
            body = ["model": model, "messages": msgs, "stream": true]
            // OpenRouter: بس الأساسيات (التوجيه يرفض لو طلبنا خاصية ما يدعمها المزوّد)
            if !or { body["max_completion_tokens"] = tokens * 3 }
        case .anthropic:
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var msgs: [[String: Any]] = hist.map { ["role": $0.role == .assistant ? "assistant" : "user", "content": $0.content] }
            var content: [[String: Any]] = imgs.map { ["type": "image", "source": ["type": "base64", "media_type": $0.0, "data": $0.1]] }
            content.append(["type": "text", "text": user])
            msgs.append(["role": "user", "content": content])
            body = ["model": model, "max_tokens": tokens * 2, "system": system, "messages": msgs, "stream": true]
        case .gemini, .geminiPaid:
            let m = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(m):streamGenerateContent?alt=sse")!)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            var contents: [[String: Any]] = hist.map { ["role": $0.role == .assistant ? "model" : "user", "parts": [["text": $0.content]]] }
            var parts: [[String: Any]] = [["text": user]]
            for (mt, b) in imgs { parts.append(["inlineData": ["mimeType": mt, "data": b]]) }
            contents.append(["role": "user", "parts": parts])
            body = ["systemInstruction": ["parts": [["text": system]]], "contents": contents,
                    "generationConfig": ["maxOutputTokens": tokens * 4]]
        }
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }
}
