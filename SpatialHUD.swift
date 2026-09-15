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

    // Autonomous Background Screen-Change Sentinel (Disabled to prevent CoderPad thrashing)
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

        // Hands-Free Sentinel Boot: Auto-start audio tap (screen OCR strictly on utterance finish or Option+O)
        startAudioCapture()
        startScreenWatcher()
        print("🚀 CortexGlass Online: System Audio Stream Tap ACTIVE. Screen OCR restricted to Utterance Snapshot & Option+O.")
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
    // 6. Autonomous Screen-Change Sentinel (Disabled to Eliminate UI Thrashing)
    // ========================================================================
    // NOTE: Autonomous screen diffing (delta >= 20 trigger) is disabled so typing
    // in CoderPad NEVER triggers Gemini or causes HUD refreshes.
    // Screen OCR is strictly restricted to:
    // 1. Audio stream completion snapshot (silenceDuration >= 0.9s)
    // 2. Explicit manual hotkey (Option + O)
    func startScreenWatcher() {
        guard isScreenWatching else { return }
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

        // 2. System Design & Excalidraw Whiteboard Check (Prioritized over Project Name)
        let systemKeywords = [
            "system design", "design a", "design an", "scale to", "qps", "tps",
            "throughput", "latency sla", "microservice", "kafka", "distributed system",
            "sharding", "load balancer", "excalidraw", "whiteboard", "rate limiter",
            "cache-aside", "write-through", "cdn", "nosql vs sql", "partition key",
            "architecture", "draw", "diagram", "topology", "component flow"
        ]
        var systemScore = 0
        for kw in systemKeywords {
            if combined.contains(kw) { systemScore += 1 }
        }

        if systemScore > 0 && (combined.contains("design") || combined.contains("excalidraw") || combined.contains("whiteboard") || combined.contains("architecture") || combined.contains("diagram") || combined.contains("topology") || combined.contains("draw")) {
            return .systemDesign
        }

        // 3. Candidate Ground Truth Architecture Check
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

        CONTINUITY & ANCHORING MANDATE:
        Inspect the existing code currently in CoderPad. You MUST preserve the candidate's existing algorithmic strategy, data structures, and variable naming conventions. Expand or patch the current code. NEVER pivot to an entirely different algorithmic paradigm unless explicitly instructed by the interviewer's speech.
        """

        switch currentMode {
        case .coding:
            return """
            \(baseInstructions)

            SPEAKER AUDIO QUERY:
            "\(spokenInput)"

            CURRENT SCREEN CODE BUFFER (OCR from Workspace/IDE):
            \(screenContext)

            OUTPUT EXACTLY IN THIS DUAL-TIER FORMAT:
            ### 1. TALKING POINTS & CONCEPTUAL REASONING (Verbatim to speak aloud)
            2 to 3 natural sentences explaining the approach, trade-offs, and Big-O time/space complexity.

            ### 2. EXACT CODE IMPLEMENTATION / PATCH
            Clean Python 3 code matching CoderPad `main.py`. If the interviewer only asked a conceptual question, output: "No code changes needed—verbal answer only."
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

            ### 2. MONOSPACE ASCII ARCHITECTURE (If architecture/flow asked, output exact ASCII diagram from ContextVault)
            If the question asks about architecture, system components, or Excalidraw flow, output the clean monospace ASCII topology from ContextVault. Otherwise, provide a 1-sentence summary of the component boundaries.

            ### 3. TECHNICAL MECHANISMS & TRADE-OFFS (Bullet points to speak through)
            - How it worked under the hood (mention MCP, Neo4j GraphRAG, FSMs, Redis, H3, Kafka, or PSI).
            - The specific production incident, scalability crisis, or architectural veto.
            - The engineering trade-off accepted.

            ### 4. PROACTIVE TECHNICAL DIRECTION
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

    // Manual OCR Snapshot (Option + O)
    func runOCR() {
        Task {
            let text = await captureScreenText()
            guard !text.isEmpty else { return }

            lastScreenText = text

            let detected = classifyContext(spokenText: "", screenText: text)
            if detected != currentMode {
                currentMode = detected
                DispatchQueue.main.async { self.updateBorder() }
            }

            let prompt = buildPrompt(spokenInput: "", screenContext: text)
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
    // 9. Carbon Hotkeys & Swallowing Engine (Streamlined to 4 Essential Hotkeys)
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

        // 4 Essential Hotkeys:
        // 1. Option + O : Manual Screen OCR Snapshot
        // 2. Option + Z : Stealth HUD Visibility Toggle
        // 3. Option + I : Interactive Click-Through Toggle
        // 4. Option + R : Silent Round & Memory Reset
        let binds: [(UInt32, Int)] = [
            (1, kVK_ANSI_O), // Option + O
            (2, kVK_ANSI_Z), // Option + Z
            (3, kVK_ANSI_I), // Option + I
            (4, kVK_ANSI_R)  // Option + R
        ]
        for (id, code) in binds {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(code), opt, EventHotKeyID(signature: OSType(0x5350), id: id), GetApplicationEventTarget(), 0, &ref)
        }

        // Active key suppression matrix to swallow all other Option + key chords.
        // Prevents dead-key symbol leaks into external code editors (CoderPad).
        // Preserves Option + Left/Right arrows for native word navigation.
        let swallow = [
            kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F,
            kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M,
            kVK_ANSI_N, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
            kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y,
            kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
            kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
            kVK_ANSI_Equal, kVK_ANSI_Minus, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket,
            kVK_ANSI_Semicolon, kVK_ANSI_Slash, kVK_ANSI_Quote, kVK_ANSI_Comma,
            kVK_ANSI_Period, kVK_ANSI_Grave, kVK_ANSI_Backslash
        ]
        for code in swallow {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(code), opt, EventHotKeyID(signature: OSType(0x5350), id: 9999), GetApplicationEventTarget(), 0, &ref)
        }
    }

    func handleKey(_ id: UInt32) {
        switch id {
        case 1: runOCR()                                               // Option + O : Manual Screen OCR Snapshot
        case 2: panel.alphaValue = panel.alphaValue > 0 ? 0 : opacity   // Option + Z : Stealth HUD Visibility Toggle
        case 3: toggleInteractive()                                    // Option + I : Interactive Click-Through Toggle
        case 4: resetRound()                                           // Option + R : Silent Round & Memory Reset
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

