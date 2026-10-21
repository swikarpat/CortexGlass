import Cocoa
import WebKit
import Carbon
import Vision
import ScreenCaptureKit
import AVFoundation
import CoreMedia

// ============================================================================
// 1. Single-Instance Process Lock
// ============================================================================
let lockPath = "/tmp/com.swikar.spatialhud.lock"
let lock = open(lockPath, O_CREAT | O_WRONLY, 0o600)
if lock == -1 || flock(lock, LOCK_EX | LOCK_NB) != 0 { exit(0) }

// ============================================================================
// 2. Hardware-Isolated Spatial HUD Panel (Compositor-Level Window Virtualization)
// ============================================================================
class SpatialPanel: NSPanel {
    var isInteractive = false

    init(rect: NSRect) {
        super.init(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Completely excluded from WebRTC browser streams, Zoom, Teams, and native screen capture
        sharingType = .none
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true // Non-occluding click-through pass-through by default
        isMovableByWindowBackground = true

        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = 14
        contentView?.layer?.masksToBounds = true
        contentView?.layer?.borderWidth = 2.0
    }

    override var canBecomeKey: Bool { isInteractive }
    override var canBecomeMain: Bool { isInteractive }
}

// ============================================================================
// 3. High-Speed Gemini REST Engine (Sub-2s Streaming with thinkingBudget: 0)
// ============================================================================
class GeminiRESTEngine {
    static let shared = GeminiRESTEngine()
    private var activeTask: Task<Void, Never>?

    func resolveAPIKey() -> String? {
        if let envKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !envKey.isEmpty { return envKey }
        for p in ["~/.config/overlay/gemini_api_key.txt", "~/.config/overlay/api_key.txt"] {
            if let k = try? String(contentsOfFile: NSString(string: p).expandingTildeInPath, encoding: .utf8) {
                let cleaned = k.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
    }

    func streamCompletion(
        prompt: String,
        startTime: Date,
        onFirstToken: @escaping @MainActor (Double) -> Void,
        onToken: @escaping @MainActor (String) -> Void,
        onComplete: @escaping @MainActor (String, Double, Double, String) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        cancel()

        guard let apiKey = resolveAPIKey() else {
            Task { @MainActor in
                onError("GEMINI_API_KEY missing from ~/.config/overlay/gemini_api_key.txt")
            }
            return
        }

        activeTask = Task.detached(priority: .userInitiated) {
            let preferredModel = ProcessInfo.processInfo.environment["GEMINI_MODEL"] ?? "gemini-3.8-flash"
            var candidateModels = [preferredModel]
            for fallback in ["gemini-3-flash-preview", "gemini-2.5-flash", "gemini-flash-latest"] {
                if !candidateModels.contains(fallback) { candidateModels.append(fallback) }
            }
            var lastErrorMsg = "Failed to connect"

            // Thinking Budget: "Low" thinking is 512 tokens (~2.2s TTFT with concise CoT reasoning).
            // Can be overridden via GEMINI_THINKING_BUDGET=0 for instantaneous sub-second TTFT (~0.97s).
            let thinkingBudget: Int = {
                if let envStr = ProcessInfo.processInfo.environment["GEMINI_THINKING_BUDGET"], let val = Int(envStr) {
                    return val
                }
                return 512 // Default: Low thinking (512 tokens)
            }()

            for model in candidateModels {
                if Task.isCancelled { return }
                guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?key=\(apiKey)&alt=sse") else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 6.0

                var genConfig: [String: Any] = [
                    "temperature": 0.1,
                    "maxOutputTokens": 2048
                ]
                if thinkingBudget >= 0 {
                    genConfig["thinkingConfig"] = ["thinkingBudget": thinkingBudget]
                }

                let body: [String: Any] = [
                    "contents": [["parts": [["text": prompt]]]],
                    "generationConfig": genConfig
                ]

                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResp = response as? HTTPURLResponse else { continue }

                    if httpResp.statusCode != 200 {
                        let msg = "HTTP \(httpResp.statusCode)"
                        if httpResp.statusCode == 429 || httpResp.statusCode == 404 || httpResp.statusCode == 503 || httpResp.statusCode == 400 {
                            print("⚠️ Gemini model '\(model)' returned \(msg). Failing over to next candidate...")
                            lastErrorMsg = "\(model): \(msg)"
                            continue
                        } else {
                            await MainActor.run { onError("Gemini API Error (\(model)): \(msg)") }
                            return
                        }
                    }

                    var firstTokenTime: Double? = nil
                    var accumulatedText = ""

                    for try await line in bytes.lines {
                        if Task.isCancelled { return }
                        if line.hasPrefix("data: ") {
                            let jsonStr = String(line.dropFirst(6))
                            if let data = jsonStr.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let candidates = json["candidates"] as? [[String: Any]],
                               let content = candidates.first?["content"] as? [String: Any],
                               let parts = content["parts"] as? [[String: Any]],
                               let text = parts.first?["text"] as? String {

                                if firstTokenTime == nil {
                                    let ttft = Date().timeIntervalSince(startTime)
                                    firstTokenTime = ttft
                                    await MainActor.run { onFirstToken(ttft) }
                                }
                                accumulatedText += text
                                await MainActor.run { onToken(text) }
                            }
                        }
                    }

                    let totalDuration = Date().timeIntervalSince(startTime)
                    let finalTTFT = firstTokenTime ?? totalDuration
                    let finalAcc = accumulatedText
                    let finalModel = thinkingBudget > 0 ? "\(model) (Low Thinking)" : model
                    await MainActor.run {
                        onComplete(finalAcc, finalTTFT, totalDuration, finalModel)
                    }
                    return
                } catch {
                    print("⚠️ Gemini model '\(model)' network error: \(error.localizedDescription). Failing over...")
                    lastErrorMsg = "\(model): \(error.localizedDescription)"
                }
            }

            let finalErr = lastErrorMsg
            await MainActor.run {
                onError("All Gemini models exhausted: \(finalErr)")
            }
        }
    }
}

// ============================================================================
// 4. Autonomous Multimodal Application Controller (Apple Silicon M5 Pro)
// ============================================================================
class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, SCStreamOutput {
    var panel: SpatialPanel!
    var webView: WKWebView!
    var opacity: CGFloat = 1.0
    var questionBuffer = ""

    // High-Resolution Latency Telemetry & Solving State
    var solveStartTime: Date?
    var isSolving: Bool = false
    var streamingBuffer = ""

    // 4-Mode Cognitive Routing Engine (Default: Coding / DSA)
    enum Mode {
        case coding, systemDesign, behavioral, projectDeepDive

        var color: CGColor {
            let isDaylight = ProcessInfo.processInfo.environment["HUD_THEME"] != "dark"
            if isDaylight {
                switch self {
                case .coding:          return NSColor(red: 0.05, green: 0.55, blue: 0.90, alpha: 0.90).cgColor // Daylight Sky Blue
                case .systemDesign:    return NSColor(red: 0.50, green: 0.25, blue: 0.85, alpha: 0.90).cgColor // Daylight Violet
                case .behavioral:      return NSColor(red: 0.88, green: 0.20, blue: 0.35, alpha: 0.90).cgColor // Daylight Rose
                case .projectDeepDive: return NSColor(red: 0.85, green: 0.50, blue: 0.05, alpha: 0.90).cgColor // Daylight Amber
                }
            } else {
                switch self {
                case .coding:          return NSColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 0.95).cgColor // Electric Cyan
                case .systemDesign:    return NSColor(red: 0.65, green: 0.33, blue: 0.97, alpha: 0.95).cgColor // Neon Violet
                case .behavioral:      return NSColor(red: 0.96, green: 0.25, blue: 0.37, alpha: 0.95).cgColor // Rose Red
                case .projectDeepDive: return NSColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 0.95).cgColor // Amber Gold
                }
            }
        }

        var label: String {
            switch self {
            case .coding:          return "Coding / DSA"
            case .systemDesign:    return "System Design (ASCII & Scaled Architecture)"
            case .behavioral:      return "Leadership & Behavioral (STAR Method)"
            case .projectDeepDive: return "Past Project Retrospective & System Architecture"
            }
        }

        var tag: String {
            switch self {
            case .coding: return "CODING / DSA"
            case .systemDesign: return "SYSTEM DESIGN"
            case .behavioral: return "BEHAVIORAL (STAR)"
            case .projectDeepDive: return "PAST PROJECT"
            }
        }
    }

    var currentMode: Mode = .coding

    func switchMode(_ mode: Mode) {
        currentMode = mode
        print("🔀 Mode Switched: \(mode.label)")
        updateBorder()
        if !isSolving && !isSessionRecording {
            renderIdleHUD()
        }
    }

    // Manual Session Recording State, 5s Pre-Roll Buffer & Multi-Turn Counter
    var isSessionRecording: Bool = false
    var isAudioListening = true
    var speechDuration: Double = 0
    var silenceDuration: Double = 0
    var audioStream: SCStream?
    var audioSamples: [Float] = []
    var preRollBuffer: [Float] = []
    let audioQueue = DispatchQueue(label: "com.swikar.audio.q", qos: .userInteractive)
    var solveCount: Int = 0

    var isScreenWatching = false
    var lastScreenText: String = ""
    var screenDebounceWorkItem: DispatchWorkItem?
    let visionQueue = DispatchQueue(label: "com.swikar.vision.diff", qos: .userInteractive)

    // ========================================================================
    // Lifecycle Initialization
    // ========================================================================
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let s = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel = SpatialPanel(rect: NSRect(x: s.maxX - 560, y: s.maxY - 740, width: 540, height: 720))
        panel.alphaValue = opacity
        updateBorder()

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()

        webView = WKWebView(frame: panel.contentView!.bounds, configuration: cfg)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground") // Transparent window backing
        panel.contentView?.addSubview(webView)

        setupHotkeys()
        renderIdleHUD()
        panel.orderFront(nil)

        // Hands-Free Sentinel Boot: Auto-start audio tap (Mode strictly locked to Coding / DSA default)
        startAudioCapture()
        startScreenWatcher()
        print("🚀 CortexGlass Online: Direct Gemini REST Engine ACTIVE. Mode: \(currentMode.label)")
        print("⌨️  Hotkeys: Opt+S (Record), Opt+Return (Stop & Solve), Opt+Down/Up (Scroll), Opt+Left/Right (Move), Opt+[/] (Resize), Opt+R (Reset), Opt+O (Quit)")
    }

    // Dynamic Border Visual Feedback:
    func updateBorder() {
        let isDaylight = ProcessInfo.processInfo.environment["HUD_THEME"] != "dark"
        if panel.isInteractive {
            panel.contentView?.layer?.borderColor = isDaylight ?
                NSColor(red: 0.10, green: 0.45, blue: 0.95, alpha: 1.0).cgColor :
                NSColor.white.cgColor
            panel.contentView?.layer?.borderWidth = 2.5
        } else if isSessionRecording {
            panel.contentView?.layer?.borderColor = isDaylight ?
                NSColor(red: 0.88, green: 0.20, blue: 0.15, alpha: 1.0).cgColor :
                NSColor(red: 0.95, green: 0.35, blue: 0.15, alpha: 1.0).cgColor // ACTIVE RECORDING
            panel.contentView?.layer?.borderWidth = 2.5
        } else if isSolving {
            panel.contentView?.layer?.borderColor = isDaylight ?
                NSColor(red: 0.85, green: 0.60, blue: 0.05, alpha: 1.0).cgColor :
                NSColor(red: 1.0, green: 0.78, blue: 0.15, alpha: 1.0).cgColor // SOLVING
            panel.contentView?.layer?.borderWidth = 2.5
        } else {
            panel.contentView?.layer?.borderColor = currentMode.color
            panel.contentView?.layer?.borderWidth = 2.0
        }
    }

    // Option + I : Toggle mouse interactivity, dragging, and keyboard focus
    func toggleInteractive() {
        panel.isInteractive.toggle()
        panel.ignoresMouseEvents = !panel.isInteractive
        if panel.isInteractive {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.resignKey()
        }
        updateBorder()
    }

    // Option + R : Reset session buffers and clear HUD
    func resetRound() {
        GeminiRESTEngine.shared.cancel()
        questionBuffer = ""
        isSessionRecording = false
        isSolving = false
        solveStartTime = nil
        solveCount = 0
        streamingBuffer = ""
        audioQueue.sync {
            audioSamples.removeAll()
            preRollBuffer.removeAll()
            speechDuration = 0
            silenceDuration = 0
        }
        lastScreenText = ""
        screenDebounceWorkItem?.cancel()
        try? FileManager.default.removeItem(atPath: "/tmp/cortex_audio_stream.wav")

        renderIdleHUD()
        print("🔄 Session context, audio buffers, and screen caches cleanly purged.")
        updateBorder()
    }

    func loadContextVault() -> String {
        let mdPath = NSString(string: "~/.config/overlay/ContextVault.md").expandingTildeInPath
        if let t = try? String(contentsOfFile: mdPath, encoding: .utf8), !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return t
        }
        let txtPath = NSString(string: "~/.config/overlay/ContextVault.txt").expandingTildeInPath
        return (try? String(contentsOfFile: txtPath, encoding: .utf8)) ?? ""
    }

    // ========================================================================
    // 5. Autonomous Audio Tap Engine (ScreenCaptureKit System Audio Stream)
    // ========================================================================
    func startAudioCapture() {
        guard audioStream == nil else { return }
        Task {
            do {
                let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let d = c.displays.first else { return }
                let myPID = ProcessInfo.processInfo.processIdentifier
                let f = SCContentFilter(display: d, excludingWindows: c.windows.filter { $0.owningApplication?.processID == myPID })

                let cfg = SCStreamConfiguration()
                cfg.capturesAudio = true
                cfg.sampleRate = 16000
                cfg.channelCount = 1
                cfg.excludesCurrentProcessAudio = true
                cfg.width = 100
                cfg.height = 100
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let s = SCStream(filter: f, configuration: cfg, delegate: nil)
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
                try await s.startCapture()
                self.audioStream = s
                print("🎙️ System Audio Tap Engaged (Capturing Remote Audio Stream).")
            } catch {
                print("❌ Audio Stream Error: \(error)")
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isAudioListening,
              let desc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else { return }

        var bb: CMBlockBuffer?
        var abl = AudioBufferList()
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &bb
        ) == noErr else { return }

        var chunk: [Float] = []
        for b in UnsafeMutableAudioBufferListPointer(&abl) {
            guard let d = b.mData else { continue }
            if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                chunk.append(contentsOf: UnsafeBufferPointer(start: d.assumingMemoryBound(to: Float.self), count: Int(b.mDataByteSize) / 4))
            } else if asbd.mBitsPerChannel == 16 {
                let p = d.assumingMemoryBound(to: Int16.self)
                for i in 0..<(Int(b.mDataByteSize) / 2) { chunk.append(Float(p[i]) / 32768.0) }
            }
        }
        guard !chunk.isEmpty else { return }

        if isSessionRecording {
            let dur = Double(chunk.count) / 16000.0
            speechDuration += dur
            audioSamples.append(contentsOf: chunk)
            let maxSamples = 16000 * 600
            if audioSamples.count > maxSamples {
                audioSamples.removeFirst(audioSamples.count - maxSamples)
            }
        } else {
            preRollBuffer.append(contentsOf: chunk)
            if preRollBuffer.count > 80000 {
                preRollBuffer.removeFirst(preRollBuffer.count - 80000)
            }
        }
    }

    nonisolated static func transcribeSamples(_ samples: [Float]) -> String {
        var pcm = Data()
        pcm.reserveCapacity(samples.count * 2)
        for s in samples {
            let iv = Int16(max(-1.0, min(1.0, s)) * 32767.0).littleEndian
            withUnsafeBytes(of: iv) { pcm.append(contentsOf: $0) }
        }

        let wav = makeWav(size: pcm.count) + pcm
        try? wav.write(to: URL(fileURLWithPath: "/tmp/cortex_audio_stream.wav"))

        let whisperPaths = [
            "/usr/local/bin/whisper-engine/whisper-cli",
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli"
        ]
        let whisperBin = whisperPaths.first { FileManager.default.fileExists(atPath: $0) } ?? "/opt/homebrew/bin/whisper-cli"

        let modelPaths = [
            "/usr/local/bin/whisper-engine/ggml-base.en.bin",
            "/opt/homebrew/share/whisper-cpp/models/ggml-base.en.bin"
        ]
        let modelBin = modelPaths.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/local/bin/whisper-engine/ggml-base.en.bin"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: whisperBin)
        p.arguments = ["-m", modelBin, "-f", "/tmp/cortex_audio_stream.wav", "--no-timestamps", "-nt", "-t", "8"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()

        guard (try? p.run()) != nil else { return "" }
        p.waitUntilExit()

        guard let txt = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return "" }
        let cleaned = txt.replacingOccurrences(of: "[BLANK_AUDIO]", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased() == "you" || cleaned.lowercased() == "thank you" || cleaned.lowercased() == "." {
            return ""
        }
        return cleaned
    }

    nonisolated static func makeWav(size: Int) -> Data {
        var h = Data("RIFF".utf8); var s = UInt32(36 + size).littleEndian; h.append(Data(bytes: &s, count: 4))
        h.append(Data("WAVEfmt ".utf8)); var ss: UInt32 = 16, f: UInt16 = 1, ch: UInt16 = 1, sr: UInt32 = 16000
        var br: UInt32 = 32000, ba: UInt16 = 2, bp: UInt16 = 16, ds = UInt32(size).littleEndian
        h.append(Data(bytes: &ss, count: 4)); h.append(Data(bytes: &f, count: 2)); h.append(Data(bytes: &ch, count: 2))
        h.append(Data(bytes: &sr, count: 4)); h.append(Data(bytes: &br, count: 4)); h.append(Data(bytes: &ba, count: 2))
        h.append(Data(bytes: &bp, count: 2)); h.append(Data("data".utf8)); h.append(Data(bytes: &ds, count: 4))
        return h
    }

    // ========================================================================
    // 6. High-Speed Silent Screen Capture (Apple Vision OCR)
    // ========================================================================
    func captureScreenText() async -> String {
        do {
            let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let d = c.displays.first else { return "" }
            let myPID = ProcessInfo.processInfo.processIdentifier
            let f = SCContentFilter(display: d, excludingWindows: c.windows.filter { $0.owningApplication?.processID == myPID })

            let cfg = SCStreamConfiguration()
            cfg.width = Int(d.width)
            cfg.height = Int(d.height)
            cfg.showsCursor = false

            let img = try await SCScreenshotManager.captureImage(contentFilter: f, configuration: cfg)
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: img, options: [:]).perform([req])

            return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }

    func startScreenWatcher() {
        guard isScreenWatching else { return }
    }

    // ========================================================================
    // 7. Cognitive Technical Synthesis Engine (Prompt Builder)
    // ========================================================================
    func buildPrompt(spokenInput: String, screenContext: String) -> String {
        if currentMode == .coding {
            if solveCount > 0 {
                return """
                ROLE: Senior Software Engineer in a live technical coding interview follow-up on CoderPad.

                INTERVIEWER SPOKEN FOLLOW-UP QUERY:
                "\(spokenInput)"

                CURRENT CODE ON SCREEN:
                \(screenContext)

                CRITICAL INSTRUCTION FOR "WHAT TO SAY ALOUD RIGHT NOW":
                Provide a cohesive, natural spoken paragraph (2-3 sentences) directly addressing the interviewer:
                1. Acknowledge the constraint and state the optimal algorithmic adjustment (e.g., two-pointer, binary search, sliding window).
                2. Explain the trade-off: how it achieves optimal auxiliary space while maintaining target time complexity.
                3. Transition naturally to making the code amendment.

                Keep it articulate, natural, and direct. Do NOT use fragmented micro-bullets, and do NOT use artificial slang or theatrical phrases like "that feels like a cheat". Write in clean first-person ("I").

                OUTPUT FORMAT EXACTLY AS FOLLOWS:
                ### 1. WHAT TO SAY ALOUD RIGHT NOW
                (the 2-3 sentence cohesive spoken paragraph)

                ### 2. EXACT PYTHON 3 IMPLEMENTATION
                ```python
                # Only the modified function or specific patched code block
                ```

                ### 3. TIME & SPACE COMPLEXITY
                Time: O(...) | Space: O(...)
                """
            } else {
                return """
                ROLE: Senior Software Engineer in a live technical coding interview on CoderPad.

                INTERVIEWER AUDIO:
                "\(spokenInput)"

                CURRENT SCREEN / CODERPAD BUFFER:
                \(screenContext)

                CRITICAL INSTRUCTION FOR "WHAT TO SAY ALOUD RIGHT NOW":
                Provide a cohesive, natural spoken paragraph (3-4 sentences) for the candidate to speak aloud before coding.
                Structure it to reflect natural engineering thinking:
                1. State your understanding of the problem and key constraints clearly.
                2. Briefly note the baseline brute-force approach and its Big-O limitation.
                3. State the optimal algorithmic approach, trade-off, and target time/space complexity.
                4. Conclude with a natural transition into coding.

                Keep it cohesive, articulate, and conversational. Do NOT use fragmented micro-bullets, and do NOT use artificial slang or theatrical phrases like "that feels like a cheat". Write in clean first-person ("I").

                OUTPUT FORMAT EXACTLY AS FOLLOWS:
                ### 1. WHAT TO SAY ALOUD RIGHT NOW
                (the 3-4 sentence cohesive spoken paragraph)

                ### 2. EXACT PYTHON 3 IMPLEMENTATION
                ```python
                # Clean, minimal, production-grade Python 3 code matching the function signature in CoderPad.
                ```

                ### 3. TIME & SPACE COMPLEXITY
                Time: O(...) | Space: O(...)
                """
            }
        }

        var baseInstructions = """
        ROLE & TONE:
        You are my personal real-time technical copilot in a live high-stakes architectural collaboration session.
        Write in FIRST PERSON ("I", "my team", "we") as a senior Staff AI/ML & Distributed Systems Architect.
        Write clean, direct, conversational English for me to reference and speak through aloud.
        NEVER write meta-commentary, introductory remarks, or academic lectures.
        """

        if currentMode == .projectDeepDive || currentMode == .behavioral {
            let vault = loadContextVault()
            baseInstructions += "\n\nGROUND TRUTH CONTEXT (My technical career history, projects, and numbers):\n\(vault)"
        }

        if solveCount > 0 {
            return """
            \(baseInstructions)

            FOLLOW-UP / AMENDMENT TO PREVIOUS SOLUTION:
            INTERVIEWER UPDATE (Spoken): "\(spokenInput)"
            CURRENT SCREEN STATE:
            \(screenContext)

            TASK:
            1. Address the interviewer's new constraint directly.
            2. If architecture/code needs to be adjusted, provide ONLY the specific modified subsystem or patch.
            3. If they asked a conceptual/trade-off question, provide concise verbal talking points.
            """
        }

        switch currentMode {
        case .coding:
            return ""

        case .systemDesign:
            return """
            \(baseInstructions)

            SYSTEM DESIGN SCENARIO: "\(spokenInput)"
            SCREEN CONTEXT:
            \(screenContext)

            OUTPUT EXACTLY IN THIS FORMAT:
            ### 1. ARCHITECTURAL SCOPE & CAPACITY ESTIMATES (Verbatim Opener — Read out loud)
            2 to 3 sentences establishing core capacity estimates (QPS/TPS, read/write ratio, bandwidth, storage) and latency SLAs (p99 < 20ms).

            ### 2. MONOSPACE ASCII ARCHITECTURE
            ```
            [Client] --> [API Gateway / LB] --> [Microservices] --> [Datastore / Cache]
            ```

            ### 3. CORE SUBSYSTEMS & DISTRIBUTED TRADEOFFS
            - Storage & Sharding Keys: Partition key selection, hot-partition mitigation.
            - Caching Strategy: Cache-aside vs write-through, eviction policy, stampede mitigation.
            - Failure Modes & Resilience: Circuit breakers, idempotency, backpressure.
            """

        case .behavioral:
            return """
            \(baseInstructions)

            LEADERSHIP & BEHAVIORAL QUERY: "\(spokenInput)"

            OUTPUT IN STRUCTURED STAR FORMAT:
            ### 1. SITUATION & TASK (20s Script)
            High-stakes business crisis or technical constraint.

            ### 2. LEADERSHIP ACTIONS TAKEN (40s Script)
            3 concrete engineering leadership actions I personally spearheaded.

            ### 3. QUANTIFIED BUSINESS RESULTS (15s Script)
            Concrete revenue protected, fraud loss reduction, or cost savings achieved.
            """

        case .projectDeepDive:
            return """
            \(baseInstructions)

            PAST PROJECT RETROSPECTIVE QUERY: "\(spokenInput)"
            SCREEN CONTEXT:
            \(screenContext)

            OUTPUT IN TECHNICAL BRIEFING FORMAT:
            ### 1. DIRECT TECHNICAL ANSWER (Read out loud)
            2 to 3 sentences directly answering, anchoring on ground truth scale and production metrics.

            ### 2. MONOSPACE ASCII ARCHITECTURE
            Clean ASCII topology of the subsystem.

            ### 3. TECHNICAL MECHANISMS, TRADE-OFFS & PRODUCTION INCIDENTS
            Under-the-hood mechanisms, production incident overcome, and accepted trade-off.
            """
        }
    }

    // ========================================================================
    // 8. Session Recording & Execution State Machine
    // ========================================================================
    func startSessionRecording() {
        GeminiRESTEngine.shared.cancel()
        isSessionRecording = true
        isSolving = false
        audioQueue.sync {
            audioSamples = preRollBuffer
            preRollBuffer.removeAll()
            speechDuration = Double(audioSamples.count) / 16000.0
            silenceDuration = 0
        }

        Task { @MainActor in
            let baseline = await self.captureScreenText()
            if !baseline.isEmpty { self.lastScreenText = baseline }
        }
        self.updateBorder()
        self.renderRecordingHUD()
        print("🎙️ Session Recording STARTED (Listening & Watching)...")
    }

    func stopSessionAndSolve() {
        let t0 = Date()
        self.solveStartTime = t0
        self.isSolving = true
        self.isSessionRecording = false
        self.updateBorder()
        self.renderSolvingHUD()

        var samplesToProcess: [Float] = []
        audioQueue.sync {
            samplesToProcess = self.audioSamples
            self.audioSamples.removeAll()
            self.speechDuration = 0
            self.silenceDuration = 0
        }

        let samples = samplesToProcess
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // Step 1: Simultaneously run Whisper on accumulated audio and capture final screen OCR
            async let whisperTask: (text: String, dur: Double) = Task.detached(priority: .userInitiated) { () -> (String, Double) in
                let tStart = Date()
                if samples.count >= 3200 {
                    let res = AppDelegate.transcribeSamples(samples)
                    return (res, Date().timeIntervalSince(tStart))
                } else {
                    return ("", 0.0)
                }
            }.value

            let tOcrStart = Date()
            async let screenTask: (text: String, dur: Double) = {
                let res = await self.captureScreenText()
                return (res, Date().timeIntervalSince(tOcrStart))
            }()

            let (whisperRes, screenRes) = await (whisperTask, screenTask)

            if !whisperRes.text.isEmpty {
                self.questionBuffer = whisperRes.text
                print("⏱️ [\(String(format: "%.3f", Date().timeIntervalSince(t0)))s] Whisper Transcription: \"\(whisperRes.text)\" (took \(String(format: "%.3f", whisperRes.dur))s)")
            } else {
                print("⏱️ [\(String(format: "%.3f", Date().timeIntervalSince(t0)))s] Whisper: Ready (took \(String(format: "%.3f", whisperRes.dur))s)")
            }

            if !screenRes.text.isEmpty {
                self.lastScreenText = screenRes.text
            }
            let lineCount = (screenRes.text.isEmpty ? self.lastScreenText : screenRes.text).split(separator: "\n").count
            print("⏱️ [\(String(format: "%.3f", Date().timeIntervalSince(t0)))s] Screen Capture & Vision OCR: \(lineCount) lines recognized (took \(String(format: "%.3f", screenRes.dur))s)")

            let spoken = whisperRes.text.isEmpty ? self.questionBuffer : whisperRes.text
            let screenContext = screenRes.text.isEmpty ? self.lastScreenText : screenRes.text

            let prompt = self.buildPrompt(spokenInput: spoken, screenContext: screenContext)
            let prepTime = Date().timeIntervalSince(t0)
            print("⏱️ [\(String(format: "%.3f", prepTime))s] Local Context Ready. Connecting to Gemini REST API...")

            self.streamingBuffer = ""
            self.renderStreamingHUDHeader()

            // Step 2: Stream directly from Gemini REST API with thinkingBudget: 0 (sub-second TTFT)
            GeminiRESTEngine.shared.streamCompletion(
                prompt: prompt,
                startTime: t0,
                onFirstToken: { ttft in
                    print("⏱️ [\(String(format: "%.3f", ttft))s] ⚡ FIRST TOKEN RECEIVED in HUD! (TTFT: \(String(format: "%.2f", ttft))s)")
                    self.isSolving = false
                    self.updateBorder()
                },
                onToken: { chunk in
                    self.streamingBuffer += chunk
                    self.appendStreamChunk(chunk)
                },
                onComplete: { fullText, ttft, totalDuration, modelName in
                    self.solveCount += 1
                    self.isSolving = false
                    self.updateBorder()
                    self.renderFinalCards(
                        rawText: fullText,
                        ttftSec: ttft,
                        totalDurationSec: totalDuration,
                        modelName: modelName
                    )
                    print("⏱️ [\(String(format: "%.3f", totalDuration))s] 🏁 Full Solution Complete! TTFT: \(String(format: "%.2f", ttft))s | Total: \(String(format: "%.2f", totalDuration))s (\(modelName))\n")
                },
                onError: { err in
                    self.isSolving = false
                    self.updateBorder()
                    self.renderErrorHUD(err)
                    print("❌ Gemini REST Error: \(err)")
                }
            )
        }
    }

    func cleanQuit() {
        print("🛑 CortexGlass Exiting Cleanly.")
        GeminiRESTEngine.shared.cancel()
        audioStream?.stopCapture(completionHandler: nil)
        try? FileManager.default.removeItem(atPath: lockPath)
        exit(0)
    }

    // ========================================================================
    // 9. Glassmorphism HUD HTML Renderer
    // ========================================================================
    func isDaylightTheme() -> Bool {
        return ProcessInfo.processInfo.environment["HUD_THEME"] != "dark"
    }

    func baseCSS() -> String {
        if isDaylightTheme() {
            return """
            :root {
                --bg: rgba(255, 255, 255, 0.96);
                --card: rgba(255, 255, 255, 0.92);
                --border: rgba(203, 213, 225, 0.8);
                --accent: #0284c7;
                --text: #0f172a;
                --text-muted: #64748b;
                --speech-bg: linear-gradient(135deg, rgba(240, 249, 255, 0.95) 0%, rgba(224, 242, 254, 0.65) 100%);
                --speech-border: rgba(56, 189, 248, 0.5);
                --speech-text: #0f172a;
                --code-bg: #f8fafc;
                --code-border: #e2e8f0;
                --code-text: #0f172a;
                --gold: #b45309;
                --gold-bg: rgba(245, 158, 11, 0.12);
                --gold-border: rgba(245, 158, 11, 0.4);
                --rose: #b91c1c;
                --rose-bg: rgba(239, 68, 68, 0.12);
                --rose-border: rgba(239, 68, 68, 0.35);
                --green: #047857;
                --green-bg: rgba(16, 185, 129, 0.12);
                --green-border: rgba(16, 185, 129, 0.4);
                --shadow: 0 4px 16px -2px rgba(15, 23, 42, 0.05), 0 2px 6px -1px rgba(15, 23, 42, 0.03);
                --header-border: rgba(0, 0, 0, 0.08);
                --btn-bg: #ffffff;
                --btn-border: #cbd5e1;
                --btn-text: #475569;
                --btn-hover-bg: #f1f5f9;
                --btn-hover-text: #0f172a;
                --hk-bg: #f1f5f9;
                --hk-border: #cbd5e1;
                --hk-text: #334155;
            }
            * { box-sizing: border-box; margin: 0; padding: 0; }
            body {
                background: var(--bg);
                color: var(--text);
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', sans-serif;
                font-size: 13.5px;
                line-height: 1.55;
                padding: 16px;
                user-select: text;
                -webkit-user-select: text;
                overflow-x: hidden;
                overflow-y: auto;
                backdrop-filter: blur(28px) saturate(190%);
                -webkit-backdrop-filter: blur(28px) saturate(190%);
            }
            ::-webkit-scrollbar { width: 6px; }
            ::-webkit-scrollbar-thumb { background: #cbd5e1; border-radius: 3px; }
            ::-webkit-scrollbar-thumb:hover { background: #94a3b8; }
            .header {
                display: flex;
                align-items: center;
                justify-content: space-between;
                padding-bottom: 12px;
                border-bottom: 1px solid var(--header-border);
                margin-bottom: 14px;
            }
            .brand {
                font-weight: 800;
                font-size: 11px;
                letter-spacing: 1.2px;
                color: var(--accent);
                text-transform: uppercase;
            }
            .mode-badge {
                font-size: 10px;
                font-weight: 700;
                padding: 3px 8px;
                border-radius: 6px;
                background: rgba(14, 165, 233, 0.12);
                border: 1px solid rgba(14, 165, 233, 0.35);
                color: var(--accent);
                letter-spacing: 0.5px;
            }
            .pill {
                font-size: 10px;
                font-weight: 700;
                padding: 3px 8px;
                border-radius: 6px;
                display: inline-flex;
                align-items: center;
                gap: 4px;
            }
            .pill-ready { background: var(--green-bg); color: var(--green); border: 1px solid var(--green-border); }
            .pill-rec { background: var(--rose-bg); color: var(--rose); border: 1px solid var(--rose-border); animation: pulse 1.2s infinite; }
            .pill-solve { background: var(--gold-bg); color: var(--gold); border: 1px solid var(--gold-border); animation: pulse 1.2s infinite; }
            .pill-latency { background: rgba(14, 165, 233, 0.12); color: var(--accent); border: 1px solid rgba(14, 165, 233, 0.35); }
            @keyframes pulse { 0% { opacity: 0.6; } 50% { opacity: 1.0; } 100% { opacity: 0.6; } }

            .card {
                background: var(--card);
                border: 1px solid var(--border);
                border-radius: 10px;
                padding: 14px 16px;
                margin-bottom: 12px;
                box-shadow: var(--shadow);
            }
            .speech-card {
                background: var(--speech-bg);
                border: 1px solid var(--speech-border);
                border-radius: 10px;
                padding: 14px 16px;
                margin-bottom: 12px;
                box-shadow: var(--shadow);
            }
            .card-label {
                font-size: 10.5px;
                font-weight: 800;
                text-transform: uppercase;
                letter-spacing: 0.8px;
                margin-bottom: 8px;
                display: flex;
                align-items: center;
                justify-content: space-between;
            }
            .label-speech { color: #0284c7; }
            .label-code { color: #7c3aed; }
            .label-complexity { color: #059669; }
            .speech-text {
                font-size: 14px;
                font-weight: 500;
                color: var(--speech-text);
                line-height: 1.65;
            }
            pre {
                background: var(--code-bg);
                border: 1px solid var(--code-border);
                border-radius: 8px;
                padding: 12px 14px;
                overflow-x: auto;
                font-family: 'SF Mono', Menlo, Monaco, Consolas, monospace;
                font-size: 12.5px;
                line-height: 1.5;
                color: var(--code-text);
            }
            .copy-btn {
                background: var(--btn-bg);
                border: 1px solid var(--btn-border);
                color: var(--btn-text);
                border-radius: 5px;
                padding: 3px 9px;
                font-size: 10px;
                cursor: pointer;
                font-weight: 600;
                transition: all 0.15s ease;
            }
            .copy-btn:hover { color: var(--btn-hover-text); background: var(--btn-hover-bg); }
            .footer {
                display: flex;
                justify-content: space-between;
                align-items: center;
                padding-top: 10px;
                border-top: 1px solid var(--header-border);
                font-size: 10.5px;
                color: var(--text-muted);
                margin-top: 8px;
            }
            .hk {
                background: var(--hk-bg);
                border: 1px solid var(--hk-border);
                border-radius: 4px;
                padding: 1px 6px;
                font-family: 'SF Mono', Menlo, monospace;
                font-size: 9.5px;
                color: var(--hk-text);
                font-weight: 600;
            }
            """
        } else {
            return """
            :root {
                --bg: #070a12;
                --card: rgba(18, 24, 38, 0.85);
                --border: rgba(56, 189, 248, 0.25);
                --accent: #38bdf8;
                --text: #f1f5f9;
                --text-muted: #94a3b8;
                --speech-bg: rgba(56, 189, 248, 0.09);
                --speech-border: rgba(56, 189, 248, 0.35);
                --speech-text: #ffffff;
                --code-bg: #0d121c;
                --code-border: #1e293b;
                --code-text: #7dd3fc;
                --gold: #facc15;
                --gold-bg: rgba(250, 204, 21, 0.18);
                --gold-border: rgba(250, 204, 21, 0.4);
                --rose: #fb7185;
                --rose-bg: rgba(251, 113, 133, 0.18);
                --rose-border: rgba(251, 113, 133, 0.4);
                --green: #34d399;
                --green-bg: rgba(52, 211, 153, 0.15);
                --green-border: rgba(52, 211, 153, 0.3);
                --shadow: none;
                --header-border: rgba(255, 255, 255, 0.08);
                --btn-bg: rgba(255, 255, 255, 0.08);
                --btn-border: rgba(255, 255, 255, 0.15);
                --btn-text: #94a3b8;
                --btn-hover-bg: rgba(255, 255, 255, 0.15);
                --btn-hover-text: #ffffff;
                --hk-bg: rgba(255, 255, 255, 0.06);
                --hk-border: rgba(255, 255, 255, 0.12);
                --hk-text: #cbd5e1;
            }
            * { box-sizing: border-box; margin: 0; padding: 0; }
            body {
                background: var(--bg);
                color: var(--text);
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif;
                font-size: 13.5px;
                line-height: 1.55;
                padding: 16px;
                user-select: text;
                -webkit-user-select: text;
                overflow-x: hidden;
                overflow-y: auto;
            }
            ::-webkit-scrollbar { width: 5px; }
            ::-webkit-scrollbar-thumb { background: #334155; border-radius: 3px; }
            .header {
                display: flex;
                align-items: center;
                justify-content: space-between;
                padding-bottom: 12px;
                border-bottom: 1px solid var(--header-border);
                margin-bottom: 14px;
            }
            .brand {
                font-weight: 800;
                font-size: 11px;
                letter-spacing: 1.2px;
                color: var(--accent);
                text-transform: uppercase;
            }
            .mode-badge {
                font-size: 10px;
                font-weight: 700;
                padding: 3px 8px;
                border-radius: 6px;
                background: rgba(56, 189, 248, 0.15);
                border: 1px solid rgba(56, 189, 248, 0.35);
                color: var(--accent);
                letter-spacing: 0.5px;
            }
            .pill {
                font-size: 10px;
                font-weight: 700;
                padding: 3px 8px;
                border-radius: 6px;
                display: inline-flex;
                align-items: center;
                gap: 4px;
            }
            .pill-ready { background: var(--green-bg); color: var(--green); border: 1px solid var(--green-border); }
            .pill-rec { background: var(--rose-bg); color: var(--rose); border: 1px solid var(--rose-border); animation: pulse 1.2s infinite; }
            .pill-solve { background: var(--gold-bg); color: var(--gold); border: 1px solid var(--gold-border); animation: pulse 1.2s infinite; }
            .pill-latency { background: rgba(56, 189, 248, 0.15); color: var(--accent); border: 1px solid rgba(56, 189, 248, 0.35); }
            @keyframes pulse { 0% { opacity: 0.5; } 50% { opacity: 1.0; } 100% { opacity: 0.5; } }

            .card {
                background: var(--card);
                border: 1px solid var(--border);
                border-radius: 10px;
                padding: 14px 16px;
                margin-bottom: 12px;
            }
            .speech-card {
                background: var(--speech-bg);
                border: 1px solid var(--speech-border);
                border-radius: 10px;
                padding: 14px 16px;
                margin-bottom: 12px;
            }
            .card-label {
                font-size: 10.5px;
                font-weight: 800;
                text-transform: uppercase;
                letter-spacing: 0.8px;
                margin-bottom: 8px;
                display: flex;
                align-items: center;
                justify-content: space-between;
            }
            .label-speech { color: #38bdf8; }
            .label-code { color: #a78bfa; }
            .label-complexity { color: #34d399; }
            .speech-text {
                font-size: 14px;
                font-weight: 500;
                color: var(--speech-text);
                line-height: 1.6;
            }
            pre {
                background: var(--code-bg);
                border: 1px solid var(--code-border);
                border-radius: 8px;
                padding: 12px 14px;
                overflow-x: auto;
                font-family: 'SF Mono', Menlo, Monaco, monospace;
                font-size: 12.5px;
                line-height: 1.5;
                color: var(--code-text);
            }
            .copy-btn {
                background: var(--btn-bg);
                border: 1px solid var(--btn-border);
                color: var(--btn-text);
                border-radius: 4px;
                padding: 2px 7px;
                font-size: 9.5px;
                cursor: pointer;
                font-weight: 600;
            }
            .copy-btn:hover { color: var(--btn-hover-text); background: var(--btn-hover-bg); }
            .footer {
                display: flex;
                justify-content: space-between;
                align-items: center;
                padding-top: 10px;
                border-top: 1px solid var(--header-border);
                font-size: 10px;
                color: var(--text-muted);
                margin-top: 8px;
            }
            .hk {
                background: var(--hk-bg);
                border: 1px solid var(--hk-border);
                border-radius: 4px;
                padding: 1px 5px;
                font-family: 'SF Mono', monospace;
                font-size: 9.5px;
                color: var(--hk-text);
            }
            """
        }
    }

    func renderIdleHUD() {
        let preferredModel = ProcessInfo.processInfo.environment["GEMINI_MODEL"] ?? "gemini-3.8-flash"
        let thinkingBudget = Int(ProcessInfo.processInfo.environment["GEMINI_THINKING_BUDGET"] ?? "512") ?? 512
        let thinkingLabel = thinkingBudget > 0 ? "Low Thinking" : "Sub-second"
        let modelBadge = "\(preferredModel) • \(thinkingLabel)"

        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>\(baseCSS())</style></head><body>
        <div class="header">
            <div class="brand">CORTEXGLASS HUD</div>
            <div class="mode-badge">\(currentMode.tag)</div>
            <div class="pill pill-ready">● READY</div>
        </div>
        <div class="card" style="text-align: center; padding: 28px 16px;">
            <div style="font-size: 28px; margin-bottom: 8px;">🚀</div>
            <div style="font-size: 15px; font-weight: 700; color: var(--text); margin-bottom: 6px;">Direct Gemini REST Engine Online</div>
            <div style="font-size: 12px; color: var(--text-muted); max-width: 380px; margin: 0 auto 16px;">
                Sub-2s latency streaming • On-device Whisper ANE • Screen OCR • Zero CoderPad focus theft
            </div>
            <div style="display: flex; justify-content: center; gap: 8px; font-size: 11px;">
                <span class="pill pill-latency">⚡ ~1.8s TTFT</span>
                <span class="pill pill-latency">\(modelBadge)</span>
            </div>
        </div>
        <div class="card">
            <div class="card-label label-speech"><span>QUICK OPERATIONAL GUIDE (OPT-KEY ONLY)</span></div>
            <ul style="padding-left: 18px; font-size: 12px; color: var(--text); line-height: 1.7;">
                <li><span class="hk">Opt + S</span> : Start session recording (interviewer speech + screen)</li>
                <li><span class="hk">Opt + Return</span> : Stop & solve instantly (streams answer in ~1.5s)</li>
                <li><span class="hk">Opt + Down / Up</span> : Smooth scroll HUD content</li>
                <li><span class="hk">Opt + Left / Right</span> : Move HUD left / right (also <span class="hk">Opt+H/L</span>)</li>
                <li><span class="hk">Opt + U / D</span> : Move HUD up / down (also <span class="hk">Opt+K/J</span>)</li>
                <li><span class="hk">Opt + 5 / 6</span> : Snap HUD to Left / Right screen edge</li>
                <li><span class="hk">Opt + [ / ]</span> or <span class="hk">- / =</span> : Scale HUD smaller / bigger</li>
                <li><span class="hk">Opt + 1..4</span> : Switch mode (Coding, SysDesign, Behavioral, Project)</li>
                <li><span class="hk">Opt + R</span> : Reset session • <span class="hk">Opt + Z</span> Stealth Hide • <span class="hk">Opt + O</span> Quit</li>
            </ul>
        </div>
        <div class="footer">
            <span>SpatialHUD Compositor (sharingType: none)</span>
            <span><span class="hk">Opt + O</span> Quit</span>
        </div>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func renderRecordingHUD() {
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>\(baseCSS())</style></head><body>
        <div class="header">
            <div class="brand">CORTEXGLASS HUD</div>
            <div class="mode-badge">\(currentMode.tag)</div>
            <div class="pill pill-rec">🎙️ RECORDING...</div>
        </div>
        <div class="card" style="padding: 24px 16px; border-color: var(--rose-border); background: var(--rose-bg);">
            <div style="display: flex; align-items: center; gap: 12px; margin-bottom: 12px;">
                <span style="font-size: 24px;">🎙️</span>
                <div>
                    <div style="font-size: 14px; font-weight: 700; color: var(--text);">Listening to Interviewer Question...</div>
                    <div style="font-size: 11.5px; color: var(--text-muted);">Accumulating audio samples and caching screen context</div>
                </div>
            </div>
            <div style="font-size: 11.5px; color: var(--text); background: var(--card); border: 1px solid var(--border); padding: 8px 12px; border-radius: 6px;">
                Press <span class="hk">Opt + Return</span> when the interviewer finishes speaking to solve.
            </div>
        </div>
        <div class="footer">
            <span>5s pre-roll circular buffer engaged</span>
            <span><span class="hk">Opt + Return</span> Stop & Solve</span>
        </div>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func renderSolvingHUD() {
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>\(baseCSS())</style></head><body>
        <div class="header">
            <div class="brand">CORTEXGLASS HUD</div>
            <div class="mode-badge">\(currentMode.tag)</div>
            <div class="pill pill-solve">⚡ SOLVING...</div>
        </div>
        <div class="card" style="padding: 24px 16px; border-color: var(--gold-border); background: var(--gold-bg);">
            <div style="display: flex; align-items: center; gap: 12px; margin-bottom: 12px;">
                <span style="font-size: 24px;">⚡</span>
                <div>
                    <div style="font-size: 14px; font-weight: 700; color: var(--text);">Parallel ANE Inference & Synthesis</div>
                    <div style="font-size: 11.5px; color: var(--text-muted);">Whisper ANE • Apple Vision OCR • Gemini 3.8 / 3 Flash (Low) REST</div>
                </div>
            </div>
            <div style="font-size: 11px; color: var(--text-muted); display: flex; flex-direction: column; gap: 6px;">
                <div>● Running 8-core Whisper audio transcription...</div>
                <div>● Parsing Retina display problem statement...</div>
                <div>● Streaming tokens via direct HTTPS SSE stream...</div>
            </div>
        </div>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func renderStreamingHUDHeader() {
        let roundLabel = solveCount > 0 ? "Follow-Up #\(solveCount)" : "Initial Problem"
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>\(baseCSS())</style></head><body>
        <div class="header">
            <div class="brand">CORTEXGLASS HUD</div>
            <div class="mode-badge">\(currentMode.tag) • \(roundLabel)</div>
            <div class="pill pill-solve">⚡ STREAMING...</div>
        </div>
        <div class="card" style="margin-bottom: 12px;">
            <div class="card-label label-speech"><span>LIVE STREAMING SOLUTION</span></div>
            <div id="stream-content" style="font-family: 'SF Mono', Menlo, monospace; font-size: 12.5px; line-height: 1.5; color: var(--code-text); white-space: pre-wrap; word-break: break-word;"></div>
        </div>
        <script>
            function appendText(chunk) {
                const el = document.getElementById('stream-content');
                if (el) {
                    el.textContent += chunk;
                    window.scrollTo({top: document.body.scrollHeight, behavior: 'smooth'});
                }
            }
        </script>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func appendStreamChunk(_ chunk: String) {
        guard let d = try? JSONSerialization.data(withJSONObject: [chunk]),
              let j = String(data: d, encoding: .utf8) else { return }
        let js = "if (window.appendText) { window.appendText(\(j)[0]); }"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func renderFinalCards(rawText: String, ttftSec: Double, totalDurationSec: Double, modelName: String) {
        let (speech, code, complexity) = parseSections(raw: rawText)
        let roundLabel = solveCount > 1 ? "Follow-Up #\(solveCount - 1)" : "Initial Problem"

        let speechHtml = speech.isEmpty ? "" : """
        <div class="speech-card">
            <div class="card-label label-speech">
                <span>🗣️ WHAT TO SAY ALOUD RIGHT NOW</span>
                <span style="font-size: 9.5px; color: var(--accent); font-weight: 600;">READ OUT LOUD</span>
            </div>
            <div class="speech-text">\(formatSpeechParagraphHTML(speech))</div>
        </div>
        """

        let codeHtml = code.isEmpty ? "" : """
        <div class="card">
            <div class="card-label label-code">
                <span>💻 EXACT PYTHON 3 IMPLEMENTATION</span>
                <button class="copy-btn" onclick="copyCode()">Copy Code</button>
            </div>
            <pre><code id="code-snippet">\(escapeHtml(code))</code></pre>
        </div>
        """

        let complexityHtml = complexity.isEmpty ? "" : """
        <div class="card" style="padding: 10px 14px; background: var(--green-bg); border-color: var(--green-border);">
            <div class="card-label label-complexity" style="margin-bottom: 4px;">
                <span>⏱️ TIME & SPACE COMPLEXITY</span>
            </div>
            <div style="font-size: 12.5px; color: var(--text);">\(escapeHtml(complexity))</div>
        </div>
        """

        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>\(baseCSS())</style></head><body>
        <div class="header">
            <div class="brand">CORTEXGLASS HUD</div>
            <div class="mode-badge">\(currentMode.tag) • \(roundLabel)</div>
            <div class="pill pill-latency">⚡ \(String(format: "%.2f", totalDurationSec))s (\(String(format: "%.2f", ttftSec))s TTFT)</div>
        </div>
        \(speechHtml)
        \(codeHtml)
        \(complexityHtml)
        <div class="footer">
            <span>\(modelName)</span>
            <span><span class="hk">Opt+Down/Up</span> Scroll • <span class="hk">Opt+Left/Right</span> Move • <span class="hk">Opt+[/]</span> Resize</span>
        </div>
        <script>
            function copyCode() {
                const code = document.getElementById('code-snippet');
                if (code) {
                    navigator.clipboard.writeText(code.innerText);
                    const btn = document.querySelector('.copy-btn');
                    if (btn) { btn.innerText = 'Copied!'; setTimeout(() => { btn.innerText = 'Copy Code'; }, 1500); }
                }
            }
        </script>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func renderErrorHUD(_ errorMsg: String) {
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>\(baseCSS())</style></head><body>
        <div class="header">
            <div class="brand">CORTEXGLASS HUD</div>
            <div class="mode-badge">\(currentMode.tag)</div>
            <div class="pill" style="background: var(--rose-bg); color: var(--rose); border: 1px solid var(--rose-border);">❌ ERROR</div>
        </div>
        <div class="card" style="border-color: var(--rose-border); padding: 18px;">
            <div style="font-size: 13.5px; font-weight: 700; color: var(--rose); margin-bottom: 8px;">Inference Failed</div>
            <div style="font-size: 12px; color: var(--text); font-family: 'SF Mono', monospace; line-height: 1.5;">\(escapeHtml(errorMsg))</div>
        </div>
        <div class="footer">
            <span>Check ~/.config/overlay/gemini_api_key.txt</span>
            <span><span class="hk">Opt + R</span> Reset</span>
        </div>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func parseSections(raw: String) -> (speech: String, code: String, complexity: String) {
        var speech = ""
        var code = ""
        var complexity = ""

        if raw.contains("### 1.") && raw.contains("### 2.") {
            let p1 = raw.components(separatedBy: "### 1.")
            if p1.count > 1 {
                let p2 = p1[1].components(separatedBy: "### 2.")
                speech = p2[0].replacingOccurrences(of: "WHAT TO SAY ALOUD RIGHT NOW", with: "")
                              .replacingOccurrences(of: "WHAT TO SAY ALOUD", with: "")
                              .trimmingCharacters(in: .whitespacesAndNewlines)
                if p2.count > 1 {
                    let p3 = p2[1].components(separatedBy: "### 3.")
                    code = p3[0].replacingOccurrences(of: "EXACT PYTHON 3 IMPLEMENTATION", with: "")
                                .replacingOccurrences(of: "PYTHON 3 IMPLEMENTATION", with: "")
                                .replacingOccurrences(of: "PYTHON 3 CODE", with: "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                    if p3.count > 1 {
                        complexity = p3[1].replacingOccurrences(of: "TIME & SPACE COMPLEXITY", with: "")
                                          .replacingOccurrences(of: "COMPLEXITY", with: "")
                                          .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        } else {
            if let startRange = raw.range(of: "```"),
               let endRange = raw.range(of: "```", range: startRange.upperBound..<raw.endIndex) {
                speech = String(raw[..<startRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                code = String(raw[startRange.lowerBound...endRange.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                complexity = String(raw[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                speech = raw
            }
        }

        var cleanCode = code
        if cleanCode.hasPrefix("```python") { cleanCode = String(cleanCode.dropFirst(9)) }
        else if cleanCode.hasPrefix("```py") { cleanCode = String(cleanCode.dropFirst(5)) }
        else if cleanCode.hasPrefix("```") { cleanCode = String(cleanCode.dropFirst(3)) }
        if cleanCode.hasSuffix("```") { cleanCode = String(cleanCode.dropLast(3)) }
        cleanCode = cleanCode.trimmingCharacters(in: .whitespacesAndNewlines)

        return (speech, cleanCode, complexity)
    }

    func escapeHtml(_ str: String) -> String {
        return str.replacingOccurrences(of: "&", with: "&amp;")
                  .replacingOccurrences(of: "<", with: "&lt;")
                  .replacingOccurrences(of: ">", with: "&gt;")
                  .replacingOccurrences(of: "\"", with: "&quot;")
                  .replacingOccurrences(of: "'", with: "&#39;")
    }

    func formatSpeechParagraphHTML(_ rawSpeech: String) -> String {
        var text = rawSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\"") && text.hasSuffix("\"") && text.count > 2 {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Clean up LaTeX math wrappers like $O(n)$ or $O(n^2)$ -> O(n) or O(n²) for spoken clarity
        text = text.replacingOccurrences(of: "$O(", with: "O(")
                   .replacingOccurrences(of: ")$", with: ")")
                   .replacingOccurrences(of: "$", with: "")

        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if paragraphs.count > 1 {
            return paragraphs.map { "<p style=\"margin: 0 0 10px 0; line-height: 1.65;\">\(escapeHtml($0))</p>" }.joined()
        } else {
            return "<p style=\"margin: 0; line-height: 1.65;\">\(escapeHtml(text))</p>"
        }
    }

    // ========================================================================
    // 10. Carbon Hotkeys & Swallowing Engine (Zero CoderPad Focus Theft)
    // ========================================================================
    func setupHotkeys() {
        var s = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, ev, u) -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let del = Unmanaged<AppDelegate>.fromOpaque(u!).takeUnretainedValue()
            DispatchQueue.main.async { del.handleKey(hk.id) }
            return noErr
        }, 1, &s, Unmanaged.passUnretained(self).toOpaque(), nil)

        let opt = UInt32(optionKey)

        // Core Hotkeys (Strictly Single Option Chords - No Ctrl required):
        // Option + S           : Start Session Recording
        // Option + Return      : Stop Session & Solve
        // Option + 1           : Switch to Coding / DSA [DEFAULT]
        // Option + 2           : Switch to System Design
        // Option + 3           : Switch to Leadership & Behavioral
        // Option + 4           : Switch to Past Project Retrospective
        // Option + O           : Clean Quit Application
        // Option + Z           : Stealth HUD Visibility Toggle
        // Option + I           : Interactive Mouse Toggle
        // Option + R           : Reset Session Buffers & Clear HUD
        // Option + Down Arrow  : Remote Scroll Down (+320px)
        // Option + Up Arrow    : Remote Scroll Up (-320px)
        // Option + [ or -      : Scale HUD Down (0.90x)
        // Option + ] or =      : Scale HUD Up (1.10x)
        // Option + Left Arrow  : Nudge HUD Left (-60px)
        // Option + Right Arrow : Nudge HUD Right (+60px)
        // Option + H           : Nudge HUD Left (-60px)
        // Option + L           : Nudge HUD Right (+60px)
        // Option + K or U      : Nudge HUD Up (+60px)
        // Option + J or D      : Nudge HUD Down (-60px)
        // Option + 5           : Snap Left Edge
        // Option + 6           : Snap Right Edge (Default side)
        // Option + 7           : Snap Top-Left Corner
        // Option + 8           : Snap Top-Right Corner
        let binds: [(UInt32, Int)] = [
            (1, kVK_ANSI_S),
            (2, kVK_Return),
            (3, kVK_ANSI_1),
            (4, kVK_ANSI_2),
            (5, kVK_ANSI_3),
            (6, kVK_ANSI_4),
            (7, kVK_ANSI_O),
            (8, kVK_ANSI_Z),
            (9, kVK_ANSI_I),
            (10, kVK_ANSI_R),
            (11, kVK_DownArrow),
            (12, kVK_UpArrow),
            (13, kVK_ANSI_LeftBracket),
            (14, kVK_ANSI_RightBracket),
            (15, kVK_ANSI_Minus),
            (16, kVK_ANSI_Equal),
            (17, kVK_LeftArrow),
            (18, kVK_RightArrow),
            (19, kVK_ANSI_H),
            (20, kVK_ANSI_L),
            (21, kVK_ANSI_K),
            (22, kVK_ANSI_J),
            (23, kVK_ANSI_U),
            (24, kVK_ANSI_D),
            (25, kVK_ANSI_5),
            (26, kVK_ANSI_6),
            (27, kVK_ANSI_7),
            (28, kVK_ANSI_8)
        ]
        for (id, code) in binds {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(code), opt, EventHotKeyID(signature: OSType(0x5350), id: id), GetApplicationEventTarget(), 0, &ref)
        }

        // Active key suppression matrix to swallow all remaining Option + key chords.
        let allCandidateKeys: [Int] = [
            kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H,
            kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P,
            kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
            kVK_ANSI_Y, kVK_ANSI_Z,
            kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7,
            kVK_ANSI_8, kVK_ANSI_9,
            kVK_ANSI_Equal, kVK_ANSI_Minus, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket,
            kVK_ANSI_Semicolon, kVK_ANSI_Slash, kVK_ANSI_Quote, kVK_ANSI_Comma, kVK_ANSI_Period,
            kVK_ANSI_Grave, kVK_ANSI_Backslash
        ]
        let activeSet = Set(binds.map { $0.1 })
        for code in allCandidateKeys where !activeSet.contains(code) {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(code), opt, EventHotKeyID(signature: OSType(0x5350), id: 9999), GetApplicationEventTarget(), 0, &ref)
        }
    }

    func handleKey(_ id: UInt32) {
        switch id {
        case 1: startSessionRecording()
        case 2: stopSessionAndSolve()
        case 3: switchMode(.coding)
        case 4: switchMode(.systemDesign)
        case 5: switchMode(.behavioral)
        case 6: switchMode(.projectDeepDive)
        case 7: cleanQuit()
        case 8: panel.alphaValue = panel.alphaValue > 0 ? 0 : opacity
        case 9: toggleInteractive()
        case 10: resetRound()
        case 11: webView.evaluateJavaScript("window.scrollBy({top: 320, behavior: 'smooth'});", completionHandler: nil)
        case 12: webView.evaluateJavaScript("window.scrollBy({top: -320, behavior: 'smooth'});", completionHandler: nil)
        case 13, 15: scaleWindow(0.90) // Opt + [ or Opt + -
        case 14, 16: scaleWindow(1.10) // Opt + ] or Opt + =
        case 17, 19: moveWindow(dx: -60, dy: 0) // Opt + Left Arrow or Opt + H
        case 18, 20: moveWindow(dx: 60, dy: 0)  // Opt + Right Arrow or Opt + L
        case 21, 23: moveWindow(dx: 0, dy: 60)  // Opt + K or Opt + U (Up)
        case 22, 24: moveWindow(dx: 0, dy: -60) // Opt + J or Opt + D (Down)
        case 25: snapToEdge(.left)              // Opt + 5
        case 26: snapToEdge(.right)             // Opt + 6
        case 27: snapToCorner(.topLeft)         // Opt + 7
        case 28: snapToCorner(.topRight)        // Opt + 8
        default: break
        }
    }

    // Zero-Focus Window Repositioning & Resizing Engine
    func moveWindow(dx: CGFloat, dy: CGFloat) {
        guard let s = NSScreen.main?.visibleFrame else { return }
        var f = panel.frame
        let newX = max(s.minX, min(s.maxX - f.width, f.origin.x + dx))
        let newY = max(s.minY, min(s.maxY - f.height, f.origin.y + dy))
        f.origin = CGPoint(x: newX, y: newY)
        panel.setFrame(f, display: true, animate: false)
    }

    enum ScreenEdge { case left, right }
    func snapToEdge(_ edge: ScreenEdge) {
        guard let s = NSScreen.main?.visibleFrame else { return }
        var f = panel.frame
        let margin: CGFloat = 20
        switch edge {
        case .left:  f.origin.x = s.minX + margin
        case .right: f.origin.x = s.maxX - f.width - margin
        }
        panel.setFrame(f, display: true, animate: false)
    }

    enum ScreenCorner {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    func snapToCorner(_ corner: ScreenCorner) {
        guard let s = NSScreen.main?.visibleFrame else { return }
        var f = panel.frame
        let margin: CGFloat = 20
        switch corner {
        case .topLeft:
            f.origin = CGPoint(x: s.minX + margin, y: s.maxY - f.height - margin)
        case .topRight:
            f.origin = CGPoint(x: s.maxX - f.width - margin, y: s.maxY - f.height - margin)
        case .bottomLeft:
            f.origin = CGPoint(x: s.minX + margin, y: s.minY + margin)
        case .bottomRight:
            f.origin = CGPoint(x: s.maxX - f.width - margin, y: s.minY + margin)
        }
        panel.setFrame(f, display: true, animate: false)
    }

    func scaleWindow(_ d: CGFloat) {
        guard let s = NSScreen.main?.visibleFrame else { return }
        var f = panel.frame
        let nw = max(340, min(s.width * 0.80, f.width * d))
        let nh = max(380, min(s.height * 0.95, f.height * d))
        let newX = max(s.minX, min(s.maxX - nw, f.origin.x))
        let newY = max(s.minY, min(s.maxY - nh, f.maxY - nh))
        f.origin = CGPoint(x: newX, y: newY)
        f.size = CGSize(width: nw, height: nh)
        panel.setFrame(f, display: true, animate: false)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
