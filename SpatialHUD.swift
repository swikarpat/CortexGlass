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
        ignoresMouseEvents = true // Non-occluding click-through pass-through by default
        isMovableByWindowBackground = true

        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = 12
        contentView?.layer?.masksToBounds = true
        contentView?.layer?.borderWidth = 2.0
    }

    override var canBecomeKey: Bool { isInteractive }
    override var canBecomeMain: Bool { isInteractive }
}

// ============================================================================
// 3. Autonomous Multimodal Application Controller (Apple Silicon M5 Pro)
// ============================================================================
class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, SCStreamOutput {
    var panel: SpatialPanel!
    var webView: WKWebView!
    var opacity: CGFloat = 1.0
    var questionBuffer = ""

    // 4-Mode Cognitive Routing Engine
    enum Mode {
        case coding, systemDesign, projectDeepDive, behavioral

        var color: CGColor {
            switch self {
            case .coding:          return NSColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 0.95).cgColor // Electric Cyan
            case .systemDesign:    return NSColor(red: 0.65, green: 0.33, blue: 0.97, alpha: 0.95).cgColor // Neon Violet
            case .projectDeepDive: return NSColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 0.95).cgColor // Amber Gold
            case .behavioral:      return NSColor(red: 0.96, green: 0.25, blue: 0.37, alpha: 0.95).cgColor // Rose Red
            }
        }

        var label: String {
            switch self {
            case .coding:          return "Coding / DSA"
            case .systemDesign:    return "System Design (ASCII)"
            case .projectDeepDive: return "Project Deep Dive"
            case .behavioral:      return "Leadership / STAR"
            }
        }
    }

    var currentMode: Mode = .coding

    // Continuous Rolling Audio Tap & VAD State (Auto-Active on Boot)
    var isAudioListening = true
    var isSpeaking = false
    var isTranscribing = false
    var speechDuration: Double = 0
    var silenceDuration: Double = 0
    var audioStream: SCStream?
    var audioSamples: [Float] = []
    let audioQueue = DispatchQueue(label: "com.swikar.audio.q", qos: .userInteractive)

    // Autonomous Background Screen-Change Sentinel
    var isScreenWatching = true
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
        cfg.websiteDataStore = .default()
        cfg.userContentController.addUserScript(
            WKUserScript(
                source: "Object.defineProperty(navigator, 'webdriver', { get: () => undefined });",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )

        webView = WKWebView(frame: panel.contentView!.bounds, configuration: cfg)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        panel.contentView?.addSubview(webView)

        setupHotkeys()
        if let url = URL(string: "https://gemini.google.com/app") {
            webView.load(URLRequest(url: url))
        }
        panel.orderFront(nil)

        // Hands-Free Sentinel Boot: Auto-start audio tap and screen change watcher
        startAudioCapture()
        startScreenWatcher()
        print("🚀 CortexGlass Online: Audio Stream Tap & Differential Screen Sentinel ACTIVE.")
    }

    // Strips extraneous Gemini UI elements for a clean HUD telemetry view
    func webView(_ wv: WKWebView, didFinish n: WKNavigation!) {
        let css = """
        bard-sidenav, mat-sidenav, .boqGeminiUiSideNav, .side-navigation-v2,
        header, .top-bar, button[aria-label*="Main menu"], 
        button[aria-label*="Google Account"], .profile-button, .user-menu { 
            display: none !important; 
            width: 0 !important; 
            height: 0 !important; 
        }
        main, .main-container, .conversation-container, chat-window {
            margin: 0 !important; 
            padding: 0 10px !important; 
            width: 100% !important; 
            max-width: 100% !important; 
        }
        """
        wv.evaluateJavaScript("const s=document.createElement('style');s.innerHTML=`\(css)`;document.head.appendChild(s);", completionHandler: nil)
    }

    // Dynamic Border Visual Feedback:
    // White = Interactive Mode; Glowing Emerald = Remote Audio Stream Active; Mode Color = Idle Sentinel Mode
    func updateBorder() {
        if panel.isInteractive {
            panel.contentView?.layer?.borderColor = NSColor.white.cgColor
            panel.contentView?.layer?.borderWidth = 2.5
        } else if isSpeaking {
            panel.contentView?.layer?.borderColor = NSColor(red: 0.1, green: 0.85, blue: 0.55, alpha: 1.0).cgColor // Vivid Emerald
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

    // Option + R : Silent DOM & Memory Reset between collaborative sessions
    func resetRound() {
        questionBuffer = ""
        audioSamples.removeAll()
        isSpeaking = false
        speechDuration = 0
        silenceDuration = 0
        lastScreenText = ""
        screenDebounceWorkItem?.cancel()
        try? FileManager.default.removeItem(atPath: "/tmp/cortex_audio_stream.wav")

        let js = """
        const b = document.querySelector('button[aria-label*="New chat"], [data-test-id="new-chat-button"], a[href="/app"]');
        if (b) {
            b.click();
        } else {
            const e = document.querySelector('[contenteditable="true"]');
            if (e) {
                e.focus();
                document.execCommand('selectAll');
                document.execCommand('delete');
            }
        }
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
        print("🔄 Session context, audio buffers, and screen caches cleanly purged.")
        updateBorder()
    }

    // Reads ContextVault.md first (structured semantic markdown), falls back to .txt
    func loadContextVault() -> String {
        let mdPath = NSString(string: "~/.config/overlay/ContextVault.md").expandingTildeInPath
        if let t = try? String(contentsOfFile: mdPath, encoding: .utf8), !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return t
        }
        let txtPath = NSString(string: "~/.config/overlay/ContextVault.txt").expandingTildeInPath
        return (try? String(contentsOfFile: txtPath, encoding: .utf8)) ?? ""
    }

    // ========================================================================
    // 4. Autonomous Audio Tap Engine (ScreenCaptureKit System Audio Stream)
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

    // Option + A : Toggle live system audio capture on/off
    func toggleAudio() {
        isAudioListening.toggle()
        if !isAudioListening {
            audioStream?.stopCapture(completionHandler: nil)
            audioStream = nil
            isSpeaking = false
            print("🔇 Audio Tap Muted.")
        } else {
            startAudioCapture()
        }
        updateBorder()
    }

    // Continuous Rolling Buffer + VAD Turn Completion Engine
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isAudioListening, !isTranscribing,
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

        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
        let dur = Double(chunk.count) / 16000.0

        if rms >= 0.015 {
            if !isSpeaking {
                isSpeaking = true
                speechDuration = 0
                DispatchQueue.main.async { self.updateBorder() }
            }
            silenceDuration = 0
            speechDuration += dur
            audioSamples.append(contentsOf: chunk)

            // SLIDING BUFFER TRIGGER: Continuous remote speech (>= 18s) without pause
            if speechDuration >= 18.0 {
                let s = audioSamples
                isTranscribing = true
                speechDuration = 0
                if audioSamples.count > 32000 { audioSamples = Array(audioSamples.suffix(32000)) } // Retain 2s context
                DispatchQueue.global(qos: .userInteractive).async { self.processWhisper(samples: s) }
            }

            if audioSamples.count > 480000 { audioSamples.removeFirst(80000) }
        } else if isSpeaking {
            silenceDuration += dur
            audioSamples.append(contentsOf: chunk)

            // AGGRESSIVE TURN COMPLETION: 0.9s silence confirms speaker finished query
            if silenceDuration >= 0.9 {
                let s = audioSamples
                let spk = speechDuration
                isSpeaking = false
                speechDuration = 0
                silenceDuration = 0
                audioSamples.removeAll()
                DispatchQueue.main.async { self.updateBorder() }

                if spk >= 1.0 {
                    self.isTranscribing = true
                    DispatchQueue.global(qos: .userInteractive).async { self.processWhisper(samples: s) }
                }
            }
        }
    }

    // Whisper ANE Execution & Multimodal Audio-Visual Fusion Trigger
    func processWhisper(samples: [Float]) {
        defer { isTranscribing = false }
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
        // Scaled to 8 threads on Apple Silicon M5 Pro for sub-200ms transcription
        p.arguments = ["-m", modelBin, "-f", "/tmp/cortex_audio_stream.wav", "--no-timestamps", "-nt", "-t", "8"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()

        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()

        guard let txt = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return }
        let c = txt.replacingOccurrences(of: "[BLANK_AUDIO]", with: "").trimmingCharacters(in: .whitespacesAndNewlines)

        if c.count >= 6 {
            print("🎯 Audio Query Transcribed: \"\(c)\"")
            Task {
                let screenText = await self.captureScreenText()
                if !screenText.isEmpty { self.lastScreenText = screenText }

                // Auto-classify problem mode from spoken + screen context
                let detected = self.classifyContext(spokenText: c, screenText: screenText)
                if detected != self.currentMode {
                    self.currentMode = detected
                    print("🔀 Auto-Switched Mode: \(detected.label)")
                    DispatchQueue.main.async { self.updateBorder() }
                }

                let prompt = self.buildPrompt(spokenInput: c, screenContext: screenText)
                DispatchQueue.main.async { self.sendToGemini(prompt) }
            }
        }
    }

    func makeWav(size: Int) -> Data {
        var h = Data("RIFF".utf8); var s = UInt32(36 + size).littleEndian; h.append(Data(bytes: &s, count: 4))
        h.append(Data("WAVEfmt ".utf8)); var ss: UInt32 = 16, f: UInt16 = 1, ch: UInt16 = 1, sr: UInt32 = 16000
        var br: UInt32 = 32000, ba: UInt16 = 2, bp: UInt16 = 16, ds = UInt32(size).littleEndian
        h.append(Data(bytes: &ss, count: 4)); h.append(Data(bytes: &f, count: 2)); h.append(Data(bytes: &ch, count: 2))
        h.append(Data(bytes: &sr, count: 4)); h.append(Data(bytes: &br, count: 4)); h.append(Data(bytes: &ba, count: 2))
        h.append(Data(bytes: &bp, count: 2)); h.append(Data("data".utf8)); h.append(Data(bytes: &ds, count: 4))
        return h
    }

    // ========================================================================
    // 5. High-Speed Silent Screen Capture (Apple Vision OCR)
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

    // ========================================================================
    // 6. Autonomous Screen-Change Sentinel (Silent Workspace Diffing Engine)
    // ========================================================================
    func startScreenWatcher() {
        guard isScreenWatching else { return }
        Task { [weak self] in
            guard let self = self, self.isScreenWatching else { return }
            let currentText = await self.captureScreenText()

            if !currentText.isEmpty {
                if self.lastScreenText.isEmpty {
                    // Initial baseline snapshot
                    self.lastScreenText = currentText
                    print("📸 Baseline Workspace/Screen Context Cached (\(currentText.count) chars).")
                } else {
                    let delta = abs(currentText.count - self.lastScreenText.count)
                    if delta >= 20 || self.isSignificantTextChange(old: self.lastScreenText, new: currentText) {
                        print("⚡ Workspace update detected (Δ \(delta) chars). Debouncing for stabilization...")
                        self.screenDebounceWorkItem?.cancel()

                        let workItem = DispatchWorkItem { [weak self] in
                            guard let self = self else { return }
                            self.lastScreenText = currentText
                            print("🚀 Auto-Triggering Multimodal Solution from workspace text update...")

                            // Auto-classify mode
                            let detected = self.classifyContext(spokenText: "", screenText: currentText)
                            if detected != self.currentMode {
                                self.currentMode = detected
                                print("🔀 Auto-Switched Mode: \(detected.label)")
                                DispatchQueue.main.async { self.updateBorder() }
                            }

                            let prompt = self.buildPrompt(spokenInput: "", screenContext: currentText)
                            DispatchQueue.main.async { self.sendToGemini(prompt) }
                        }

                        self.screenDebounceWorkItem = workItem
                        self.visionQueue.asyncAfter(deadline: .now() + 1.2, execute: workItem)
                    }
                }
            }

            // Continuous 2.0s Sentinel Heartbeat on Apple Silicon M5 Pro
            self.visionQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.startScreenWatcher()
            }
        }
    }

    // Detects meaningful code/diagram updates while filtering clock/cursor noise
    func isSignificantTextChange(old: String, new: String) -> Bool {
        let oldLines = Set(old.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 3 })
        let newLines = Set(new.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 3 })
        let added = newLines.subtracting(oldLines)
        return added.count >= 2 || (added.count == 1 && (added.first?.count ?? 0) >= 15)
    }

    // ========================================================================
    // 7. Auto-Adaptive Cognitive Classifier (Zero-Hotkey Mode Routing)
    // ========================================================================
    func classifyContext(spokenText: String, screenText: String) -> Mode {
        let combined = (spokenText + " " + screenText).lowercased()

        // 1. Leadership / Principles Check
        let behavioralKeywords = [
            "tell me about a time", "greatest failure", "disagreement with",
            "leadership principle", "conflict with", "star method", "leadership question",
            "how do you handle conflict", "describe a situation"
        ]
        for kw in behavioralKeywords {
            if combined.contains(kw) { return .behavioral }
        }

        // 2. Candidate Ground Truth Architecture Check
        let projectKeywords = [
            "hyperroute", "socure", "wire fraud", "capital one", "t-mobile", "ranking engine",
            "h3 geospatial", "graphrag", "past project", "previous experience",
            "production incident", "ast complexity", "clean room", "double-entry",
            "fsm-engine", "banking-core", "avx-512", "google adk", "transaction guardrail",
            "sanctions screening", "settlement", "ofac", "simd"
        ]
        for kw in projectKeywords {
            if combined.contains(kw) { return .projectDeepDive }
        }

        // 3. System Design Keywords
        let systemKeywords = [
            "system design", "design a", "design an", "scale to", "qps", "tps",
            "throughput", "latency sla", "microservice", "kafka", "distributed system",
            "sharding", "load balancer", "excalidraw", "whiteboard", "rate limiter",
            "cache-aside", "write-through", "cdn", "nosql vs sql", "partition key"
        ]
        var systemScore = 0
        for kw in systemKeywords {
            if combined.contains(kw) { systemScore += 1 }
        }

        // 4. Algorithmic Engineering Keywords
        let codingKeywords = [
            "def ", "class ", "function", "public static void", "vector<", "return ",
            "leetcode", "workspace", "given an array", "two sum", "binary tree",
            "dynamic programming", "time complexity", "space complexity", "constraints:",
            "example 1:", "test case", "stdin", "stdout", "hash map", "two pointers"
        ]
        var codingScore = 0
        for kw in codingKeywords {
            if combined.contains(kw) { codingScore += 1 }
        }

        if systemScore > codingScore {
            return .systemDesign
        } else if codingScore > 0 {
            return .coding
        }

        return currentMode
    }

    // ========================================================================
    // 8. Cognitive Technical Synthesis Engine
    // ========================================================================
    func buildPrompt(spokenInput: String, screenContext: String) -> String {
        let vault = loadContextVault()

        let baseInstructions = """
        ROLE & TONE:
        You are my personal real-time technical copilot in a live high-stakes architectural collaboration session.
        Write in FIRST PERSON ("I", "my team", "we") as a senior Staff AI/ML & Distributed Systems Architect.
        Write clean, direct, conversational English for me to reference and speak through aloud.
        NEVER write meta-commentary, introductory remarks, or academic lectures.

        GROUND TRUTH CONTEXT (My technical career history, projects, and numbers):
        \(vault)

        FALLBACK POLICY:
        For past projects, technical vetoes, or architectural decisions, answer STRICTLY using the ground truth above.
        For new algorithmic challenges, live debugging, or distributed systems design questions not covered above, seamlessly leverage your full Staff-level knowledge to provide the optimal solution in my voice.
        """

        switch currentMode {
        case .coding:
            return """
            \(baseInstructions)

            SPEAKER AUDIO QUERY:
            "\(spokenInput)"

            CURRENT SCREEN CODE BUFFER (OCR from Workspace/IDE):
            \(screenContext)

            OUTPUT EXACTLY IN THIS TECHNICAL BRIEFING FORMAT:
            ### 1. TECHNICAL APPROACH SUMMARY (Verbatim Script — Read out loud)
            2 to 3 natural spoken sentences directly explaining the optimal algorithmic approach or the exact bug/race condition, and setting up the code change.

            ### 2. EXACT CODE IMPLEMENTATION / BUG FIX
            Minimal, clean, production-grade code. If debugging, provide ONLY the corrected snippet replacing the faulty lines. If writing from scratch, match any existing function signatures on screen.

            ### 3. TIME & SPACE COMPLEXITY
            1 sentence summarizing Big-O time and auxiliary space to explain aloud.

            ### 4. SUBTLE TRAP / EDGE CASE TO HIGHLIGHT
            1 sentence calling out a senior engineering consideration (e.g., concurrency deadlock, off-by-one, null safety, or memory leak).
            """

        case .systemDesign:
            return """
            \(baseInstructions)

            SYSTEM DESIGN SCENARIO (Spoken or Architecture Canvas):
            "\(spokenInput)"

            ARCHITECTURE CANVAS / SCREEN TEXT:
            \(screenContext)

            OUTPUT EXACTLY IN THIS TECHNICAL BRIEFING FORMAT:
            ### 1. ARCHITECTURAL SCOPE & SLA (Verbatim Opener — Read out loud)
            2 to 3 sentences clarifying scale constraints (QPS/TPS, p99 latency SLA), state requirements, and primary bottleneck.

            ### 2. MONOSPACE ASCII ARCHITECTURE (Optimized for Excalidraw)
            Clean ASCII diagram using standard box characters (+, -, |, >) that maps directly into Excalidraw shapes:
            [Client] --> [API Gateway] --> [Service] --> [Kafka/DB]

            ### 3. KEY ARCHITECTURAL TRADEOFFS & NUMBERS
            - Storage & Partitioning Strategy: Sharding key and replication topology.
            - Caching & Ingestion Strategy: Write-through vs. write-back, Redis evictions.
            - Failure Recovery: Backpressure, split-brain mitigation, idempotency.

            ### 4. ARCHITECTURAL EXPLORATION (1 sentence)
            A natural prompt to explore distributed systems deep dives with the team.
            """

        case .projectDeepDive:
            return """
            \(baseInstructions)

            PROJECT RETROSPECTIVE QUERY:
            "\(spokenInput)"

            OUTPUT EXACTLY IN THIS TECHNICAL BRIEFING FORMAT:
            ### 1. DIRECT TECHNICAL ANSWER (Verbatim Script — Read out loud)
            2 to 3 sentences directly answering the question, anchoring on the exact project from my ground truth (Project A, B, or C), and quoting real scale ($40M+ wire fraud, 10M+ sessions, or 50k+ TPS).

            ### 2. TECHNICAL MECHANISMS & TRADE-OFFS (Bullet points to speak through)
            - How it worked under the hood (mention MCP, Neo4j GraphRAG, FSMs, Redis, H3, Kafka, or PSI).
            - The specific production incident, scalability crisis, or architectural veto.
            - The engineering trade-off accepted.

            ### 3. PROACTIVE TECHNICAL DIRECTION
            1 follow-up question to steer the discussion deeper into an area of strength.
            """

        case .behavioral:
            return """
            \(baseInstructions)

            LEADERSHIP & ENGINEERING INCIDENT QUERY:
            "\(spokenInput)"

            OUTPUT EXACTLY IN THIS TECHNICAL BRIEFING FORMAT:
            ### 1. EXECUTIVE RETROSPECTIVE (Verbatim STAR Story — Read out loud)
            - Situation & Task (20s): High-stakes business crisis, scale constraint, and technical conflict.
            - Actions Taken (40s): 3 specific engineering leadership actions I executed (design, veto, or cross-team alignment).
            - Quantified Results (15s): Concrete metrics, cost reduction, or incident prevention achieved.
            """
        }
    }

    // Manual OCR Fallback (Option + O / Option + P)
    func runOCR(append: Bool = false) {
        Task {
            let text = await captureScreenText()
            guard !text.isEmpty else { return }

            let dump = append && !questionBuffer.isEmpty ? "\(questionBuffer)\n\(text)" : text
            questionBuffer = append ? "" : text
            lastScreenText = dump

            let detected = classifyContext(spokenText: "", screenText: dump)
            if detected != currentMode {
                currentMode = detected
                DispatchQueue.main.async { self.updateBorder() }
            }

            let prompt = buildPrompt(spokenInput: "", screenContext: dump)
            DispatchQueue.main.async { self.sendToGemini(prompt) }
        }
    }

    // DOM Injector & Form Submitter
    func sendToGemini(_ text: String) {
        if panel.alphaValue == 0 { panel.alphaValue = opacity }
        guard let d = try? JSONSerialization.data(withJSONObject: [text]), let j = String(data: d, encoding: .utf8) else { return }
        let js = "(()=>{const e=document.querySelector('[contenteditable=\"true\"]');if(!e)return;e.focus();document.execCommand('selectAll');document.execCommand('insertText',false,\(j)[0]);e.dispatchEvent(new Event('input',{bubbles:true}));setTimeout(()=>{let s=false;document.querySelectorAll('button,[role=\"button\"]').forEach(b=>{const a=(b.getAttribute('aria-label')||'').toLowerCase();if((a.includes('send')||a.includes('submit'))&&!b.disabled){b.click();s=true;}});if(!s)e.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',keyCode:13,bubbles:true}));},300);})();"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // ========================================================================
    // 9. Carbon Hotkeys & Swallowing Engine
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
        let binds: [(UInt32, Int)] = [
            (1, kVK_ANSI_Z), (2, kVK_ANSI_V), (3, kVK_ANSI_S), (4, kVK_ANSI_Q),
            (5, kVK_ANSI_Equal), (6, kVK_ANSI_Minus), (7, kVK_ANSI_LeftBracket), (8, kVK_ANSI_RightBracket),
            (9, kVK_DownArrow), (10, kVK_UpArrow), (11, kVK_ANSI_O), (12, kVK_ANSI_P),
            (13, kVK_ANSI_A), (14, kVK_ANSI_1), (15, kVK_ANSI_2), (16, kVK_ANSI_3),
            (17, kVK_ANSI_4), (18, kVK_ANSI_R), (19, kVK_ANSI_T), (20, kVK_ANSI_E),
            (21, kVK_ANSI_I)
        ]
        for (id, code) in binds {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(code), opt, EventHotKeyID(signature: OSType(0x5350), id: id), GetApplicationEventTarget(), 0, &ref)
        }

        // Active key suppression matrix to swallow stray dead-key chords
        let swallow = [
            kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H,
            kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_U,
            kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7,
            kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0, kVK_ANSI_Semicolon, kVK_ANSI_Slash,
            kVK_ANSI_Quote, kVK_ANSI_Comma, kVK_ANSI_Period, kVK_ANSI_Grave, kVK_ANSI_Backslash
        ]
        for code in swallow {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(code), opt, EventHotKeyID(signature: OSType(0x5350), id: 9999), GetApplicationEventTarget(), 0, &ref)
        }
    }

    func handleKey(_ id: UInt32) {
        switch id {
        case 1: panel.alphaValue = panel.alphaValue > 0 ? 0 : opacity
        case 2: if let t = NSPasteboard.general.string(forType: .string) { sendToGemini(t) }
        case 3: webView.evaluateJavaScript("document.querySelectorAll('button').forEach(b => (b.innerText.includes('Stop') || b.getAttribute('aria-label')?.includes('Stop')) && b.click())", completionHandler: nil)
        case 4: exit(0)
        case 5: scaleWindow(1.08)
        case 6: scaleWindow(0.92)
        case 7, 8: opacity = max(0.2, min(1.0, opacity + (id == 8 ? 0.15 : -0.15))); panel.alphaValue = opacity
        case 9, 10: webView.evaluateJavaScript("window.scrollBy({top: \(id == 9 ? 400 : -400), behavior: 'smooth'})", completionHandler: nil)
        case 11: runOCR(append: false)
        case 12: runOCR(append: true)
        case 13: toggleAudio()
        case 14: currentMode = .coding; updateBorder(); print("Manual Switch: Coding")
        case 15: currentMode = .systemDesign; updateBorder(); print("Manual Switch: System Design")
        case 16: currentMode = .projectDeepDive; updateBorder(); print("Manual Switch: Project Deep Dive")
        case 17: currentMode = .behavioral; updateBorder(); print("Manual Switch: Leadership")
        case 18: resetRound()
        case 19: sendToGemini("Summarize your previous response into 2 ultra-concise, high-impact bullet points for an immediate 15-second verbal summary right now.")
        case 20: sendToGemini("Elaborate on that specific solution: drill down into low-level internals, concurrency handling, and failure modes.")
        case 21: toggleInteractive()
        default: break
        }
    }

    func scaleWindow(_ d: CGFloat) {
        guard let s = NSScreen.main?.visibleFrame else { return }
        var f = panel.frame; let nw = max(320, min(s.width, f.width * d)), nh = max(300, min(s.height, f.height * d))
        f.origin.y = max(s.minY, f.maxY - nh); f.size = CGSize(width: nw, height: nh)
        panel.setFrame(f, display: true, animate: false)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

