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

    // 4-Mode Cognitive Routing Engine (Default: Coding / DSA)
    enum Mode {
        case coding, systemDesign, behavioral, projectDeepDive

        var color: CGColor {
            switch self {
            case .coding:          return NSColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 0.95).cgColor // Electric Cyan
            case .systemDesign:    return NSColor(red: 0.65, green: 0.33, blue: 0.97, alpha: 0.95).cgColor // Neon Violet
            case .behavioral:      return NSColor(red: 0.96, green: 0.25, blue: 0.37, alpha: 0.95).cgColor // Rose Red
            case .projectDeepDive: return NSColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 0.95).cgColor // Amber Gold
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
    }

    var currentMode: Mode = .coding

    func switchMode(_ mode: Mode) {
        currentMode = mode
        print("🔀 Mode Switched: \(mode.label)")
        updateBorder()
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

        // Hands-Free Sentinel Boot: Auto-start audio tap (Mode strictly locked to Coding / DSA default)
        startAudioCapture()
        startScreenWatcher()
        print("🚀 CortexGlass Online: Audio Stream Tap ACTIVE. Mode Locked: \(currentMode.label) (Opt+1, Opt+2, Opt+3, Opt+4). Opt+S starts recording, Opt+Return stops & solves, Opt+O quits.")
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
    // White = Interactive Mode; Vivid Amber/Red = Active Session Recording; Mode Color = Idle Sentinel Mode
    func updateBorder() {
        if panel.isInteractive {
            panel.contentView?.layer?.borderColor = NSColor.white.cgColor
            panel.contentView?.layer?.borderWidth = 2.5
        } else if isSessionRecording {
            panel.contentView?.layer?.borderColor = NSColor(red: 0.95, green: 0.35, blue: 0.15, alpha: 1.0).cgColor // Vivid Amber/Red ACTIVE RECORDING
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
        isSessionRecording = false
        solveCount = 0
        audioQueue.sync {
            audioSamples.removeAll()
            preRollBuffer.removeAll()
            speechDuration = 0
            silenceDuration = 0
        }
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
            print("🔇 Audio Tap Muted.")
        } else {
            startAudioCapture()
        }
        updateBorder()
    }

    // Audio Stream Tap - Rolling Pre-Roll Buffer (Idle) & Session Accumulation (Recording)
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

            // Keep sample capacity safe up to 10 minutes of continuous recording (16000 samples/sec * 600s)
            let maxSamples = 16000 * 600
            if audioSamples.count > maxSamples {
                audioSamples.removeFirst(audioSamples.count - maxSamples)
            }
        } else {
            // Rolling 5-second pre-roll audio buffer (16,000 samples/sec * 5s = 80,000 samples)
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
        // Scaled to 8 threads on Apple Silicon M5 Pro for sub-200ms transcription
        p.arguments = ["-m", modelBin, "-f", "/tmp/cortex_audio_stream.wav", "--no-timestamps", "-nt", "-t", "8"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()

        guard (try? p.run()) != nil else { return "" }
        p.waitUntilExit()

        guard let txt = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return "" }
        return txt.replacingOccurrences(of: "[BLANK_AUDIO]", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
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
    // 1. Session Recording completion snapshot (Option + Return: Stop & Solve)
    // 2. Direct single-shot snapshot (Option + Return when not recording)
    func startScreenWatcher() {
        guard isScreenWatching else { return }
    }

    // ========================================================================
    // 7. Cognitive Context Classifier (Strict Mode Locking - Auto-Switching Disabled)
    // ========================================================================
    // NOTE: Automatic mode switching is strictly disabled. The HUD strictly remains
    // in the candidate's selected mode (default: .coding) until explicitly switched
    // via Option + 1, Option + 2, Option + 3, or Option + 4.
    func classifyContext(spokenText: String, screenText: String) -> Mode {
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

        if solveCount > 0 {
            return """
            \(baseInstructions)

            FOLLOW-UP / AMENDMENT TO PREVIOUS SOLUTION:
            The interviewer just provided an update, new constraint, or follow-up question.
            INTERVIEWER UPDATE (Spoken): "\(spokenInput)"
            CURRENT CODERPAD STATE (Screen OCR):
            \(screenContext)

            TASK:
            1. Address the interviewer's new constraint or question directly.
            2. If code needs to be adjusted, provide ONLY the specific modified function or patch matching their change.
            3. If they asked a conceptual/trade-off question, provide concise verbal talking points. Do not rewrite unchanged code.
            """
        }

        switch currentMode {
        case .coding:
            return """
            \(baseInstructions)

            SPEAKER AUDIO QUERY:
            "\(spokenInput)"

            CURRENT SCREEN CODE BUFFER (OCR from Workspace/IDE):
            \(screenContext)

            NEGATIVE CONSTRAINT:
            IGNORE real-world enterprise architectures, Kafka, Neo4j, or microservices from ContextVault.md. Focus strictly and exclusively on the algorithmic problem, data structures, and the code at hand.

            OUTPUT EXACTLY IN THIS FORMAT:
            ### 1. WHAT TO SAY ALOUD RIGHT NOW
            2 to 3 natural sentences for immediate verbal delivery: restate the problem concisely, ask 2 critical edge cases to validate assumptions, and pitch the brute force vs. optimal approach with Big-O intuition.

            ### 2. EXACT PYTHON 3 IMPLEMENTATION
            Minimal, production-grade Python 3 code matching CoderPad `main.py`. Anchor strictly to candidate's existing variable names, function signatures, and data structures visible in the screen buffer. If only a verbal question was asked, output: "No code changes needed—verbal answer only."

            ### 3. TIME & SPACE COMPLEXITY
            State the exact Time Complexity and Space Complexity with a 1-sentence mathematical justification.
            """

        case .systemDesign:
            return """
            \(baseInstructions)

            SYSTEM DESIGN SCENARIO (Spoken or Architecture Canvas):
            "\(spokenInput)"

            ARCHITECTURE CANVAS / SCREEN TEXT:
            \(screenContext)

            OUTPUT EXACTLY IN THIS TECHNICAL BRIEFING FORMAT:
            ### 1. ARCHITECTURAL SCOPE & CAPACITY ESTIMATES (Verbatim Opener — Read out loud)
            2 to 3 sentences establishing core capacity estimates (QPS/TPS, read/write ratio, bandwidth, storage over 5 years) and latency SLAs (p99 < 20ms).

            ### 2. MONOSPACE ASCII ARCHITECTURE (Optimized for Excalidraw / Whiteboard)
            Clean, copy-pasteable monospace ASCII diagram using standard box characters (+, -, |, >) designed to be drawn directly onto an Excalidraw or whiteboard canvas:
            [Client] --> [API Gateway / LB] --> [Microservice Cluster] --> [Cache / DB Shards]

            ### 3. CORE SUBSYSTEMS & DISTRIBUTED TRADEOFFS
            - Storage & Sharding Keys: Partition key selection, hot-partition mitigation, replication & consensus topology.
            - Caching Strategy: Cache-aside vs. write-through, eviction policy (TTL/LRU), cache stampede mitigation.
            - Failure Modes & Resilience: Backpressure, circuit breakers, idempotency keys, split-brain recovery.

            ### 4. ARCHITECTURAL EXPLORATION (1 sentence)
            A natural Staff-level prompt to proactively explore deep architectural trade-offs with the interviewer.
            """

        case .behavioral:
            return """
            \(baseInstructions)

            LEADERSHIP & BEHAVIORAL QUERY:
            "\(spokenInput)"

            OUTPUT EXACTLY IN THIS STRUCTURED STAR FORMAT:
            ### 1. SITUATION & TASK (20s - Verbatim Script to speak aloud)
            Concise high-stakes business crisis, severe technical constraint, or engineering leadership conflict.

            ### 2. LEADERSHIP ACTIONS TAKEN (40s - Verbatim Script to speak aloud)
            Exactly 3 concrete engineering leadership actions I personally spearheaded (e.g., architectural veto, cross-functional consensus building, unblocking critical path).

            ### 3. QUANTIFIED BUSINESS RESULTS (15s - Verbatim Script to speak aloud)
            Concrete business impact, dollar revenue protected, fraud loss reduction, or infrastructure cost savings achieved.
            """

        case .projectDeepDive:
            return """
            \(baseInstructions)

            PAST PROJECT RETROSPECTIVE QUERY:
            "\(spokenInput)"

            SCREEN CONTEXT:
            \(screenContext)

            ANCHORING MANDATE:
            Anchor strictly on ground truth projects from ContextVault.md (e.g., Socure, HyperRoute, Capital One, T-Mobile). Quoting real verified scale ($40M+ wire fraud prevented, 10M+ sessions, 50k+ TPS).

            OUTPUT EXACTLY IN THIS TECHNICAL BRIEFING FORMAT:
            ### 1. DIRECT TECHNICAL ANSWER (Verbatim Script — Read out loud)
            2 to 3 sentences directly answering the question, anchoring on the exact project from ground truth, and quoting real-world scale and production metrics.

            ### 2. MONOSPACE ASCII ARCHITECTURE (Past Project Topology)
            If asked to draw or explain architecture: provide the clean monospace ASCII system topology of the past project from ContextVault.md. Otherwise, provide a 1-sentence summary of the component boundaries.

            ### 3. TECHNICAL MECHANISMS, TRADE-OFFS & PRODUCTION INCIDENTS
            - Under-the-Hood Mechanisms: Exactly how it functioned (e.g., FSM engine, Neo4j GraphRAG, H3 spatial indexing, Kafka event streams, Redis cache).
            - Production Incident Overcome: The specific scalability crisis, high-stakes failure, or architectural bottleneck faced and how I engineered the resolution.
            - Accepted Engineering Trade-Off: Explicit trade-off accepted (CAP theorem balance, latency vs. consistency, compute vs. memory).

            ### 4. PROACTIVE TECHNICAL DIRECTION
            1 follow-up question to steer the interviewer deeper into an area of strength.
            """
        }
    }

    // Option + S : Start Session Recording (Listening & Watching with 5s Pre-Roll)
    func startSessionRecording() {
        isSessionRecording = true
        audioQueue.sync {
            audioSamples = preRollBuffer
            preRollBuffer.removeAll()
            speechDuration = Double(audioSamples.count) / 16000.0
            silenceDuration = 0
        }

        // Invalidate/stop any active Gemini DOM generation
        let stopJs = """
        (()=>{
            const stopBtn = document.querySelector('button[aria-label*="Stop"], button[aria-label*="stop"], [data-test-id="stop-button"]');
            if (stopBtn && !stopBtn.disabled) stopBtn.click();
        })();
        """
        webView.evaluateJavaScript(stopJs, completionHandler: nil)

        Task { @MainActor in
            let baseline = await self.captureScreenText()
            if !baseline.isEmpty {
                self.lastScreenText = baseline
            }
        }
        self.updateBorder()
        print("🎙️ Session Recording STARTED (Listening & Watching)...")
    }

    // Option + Return : Stop Session & Solve (or Direct Single-Shot OCR if not recording)
    func stopSessionAndSolve() {
        guard isSessionRecording else {
            print("⚡ Single-Shot Direct OCR Triggered (No Active Recording Session)...")
            Task { @MainActor in
                let screenText = await self.captureScreenText()
                if !screenText.isEmpty { self.lastScreenText = screenText }
                let finalScreen = screenText.isEmpty ? self.lastScreenText : screenText
                let prompt = self.buildPrompt(spokenInput: self.questionBuffer, screenContext: finalScreen)
                self.sendToGemini(prompt)
                self.solveCount += 1
            }
            return
        }

        isSessionRecording = false
        self.updateBorder()
        print("🚀 Session Recording STOPPED. Solving with full audio + screen context...")

        var samplesToProcess: [Float] = []
        audioQueue.sync {
            samplesToProcess = self.audioSamples
            self.audioSamples.removeAll()
            self.speechDuration = 0
            self.silenceDuration = 0
        }

        let samples = samplesToProcess
        Task { @MainActor in
            // Simultaneously run Whisper on accumulated audio and capture final screen OCR
            async let whisperTask: String = Task.detached(priority: .userInitiated) { () -> String in
                if samples.count >= 3200 {
                    return AppDelegate.transcribeSamples(samples)
                } else {
                    return ""
                }
            }.value

            async let screenTask = self.captureScreenText()

            let (transcribedSpeech, finalScreenText) = await (whisperTask, screenTask)

            if !transcribedSpeech.isEmpty {
                self.questionBuffer = transcribedSpeech
                print("🎯 Audio Query Transcribed: \"\(transcribedSpeech)\"")
            }

            if !finalScreenText.isEmpty {
                self.lastScreenText = finalScreenText
            }

            let spoken = transcribedSpeech.isEmpty ? self.questionBuffer : transcribedSpeech
            let screenContext = finalScreenText.isEmpty ? self.lastScreenText : finalScreenText

            let prompt = self.buildPrompt(spokenInput: spoken, screenContext: screenContext)
            self.sendToGemini(prompt)
            self.solveCount += 1
        }
    }

    // Option + O : Clean Quit Application
    func cleanQuit() {
        print("🛑 CortexGlass Exiting Cleanly.")
        audioStream?.stopCapture(completionHandler: nil)
        try? FileManager.default.removeItem(atPath: lockPath)
        exit(0)
    }

    // DOM Injector & Form Submitter
    func sendToGemini(_ text: String) {
        if panel.alphaValue == 0 { panel.alphaValue = opacity }
        guard let d = try? JSONSerialization.data(withJSONObject: [text]), let j = String(data: d, encoding: .utf8) else { return }
        let js = "(()=>{const e=document.querySelector('[contenteditable=\"true\"]');if(!e)return;e.focus();document.execCommand('selectAll');document.execCommand('insertText',false,\(j)[0]);e.dispatchEvent(new Event('input',{bubbles:true}));setTimeout(()=>{let s=false;document.querySelectorAll('button,[role=\"button\"]').forEach(b=>{const a=(b.getAttribute('aria-label')||'').toLowerCase();if((a.includes('send')||a.includes('submit'))&&!b.disabled){b.click();s=true;}});if(!s)e.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',keyCode:13,bubbles:true}));},300);})();"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // ========================================================================
    // 9. Carbon Hotkeys & Swallowing Engine (Deterministic Controls & Modes)
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

        // Core Hotkeys:
        // Option + S      : Start Session Recording (Listening & Watching)
        // Option + Return : Stop Session & Solve (Whisper + Vision + Gemini)
        // Option + 1      : Switch to Coding / DSA [DEFAULT]
        // Option + 2      : Switch to System Design (ASCII & Scaled Architecture)
        // Option + 3      : Switch to Leadership & Behavioral (STAR Method)
        // Option + 4      : Switch to Past Project Retrospective & System Architecture
        // Option + O      : Clean Quit Application (exit(0))
        // Option + Z      : Stealth HUD Visibility Toggle (Alpha 0.0 <-> 1.0)
        // Option + I      : Interactive Mouse Toggle (Click-through pass-through <-> Scrollable HUD)
        // Option + R      : Reset Session Buffers & Clear Chat
        let binds: [(UInt32, Int)] = [
            (1, kVK_ANSI_S), // Option + S : Start Session Recording
            (2, kVK_Return), // Option + Return : Stop Session & Solve
            (3, kVK_ANSI_1), // Option + 1 : Coding / DSA (Default)
            (4, kVK_ANSI_2), // Option + 2 : System Design
            (5, kVK_ANSI_3), // Option + 3 : Leadership & Behavioral
            (6, kVK_ANSI_4), // Option + 4 : Past Project Retrospective
            (7, kVK_ANSI_O), // Option + O : Clean Quit Application
            (8, kVK_ANSI_Z), // Option + Z : Stealth HUD Toggle
            (9, kVK_ANSI_I), // Option + I : Interactive Mouse Toggle
            (10, kVK_ANSI_R) // Option + R : Reset Session Buffers & Clear Chat
        ]
        for (id, code) in binds {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(code), opt, EventHotKeyID(signature: OSType(0x5350), id: id), GetApplicationEventTarget(), 0, &ref)
        }

        // Active key suppression matrix to swallow all remaining Option + key chords.
        // Prevents dead-key symbol leaks into external code editors (CoderPad).
        // Preserves Option + Left/Right/Up/Down arrows for native cursor navigation.
        let swallow = [
            kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D,
            kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H,
            kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M,
            kVK_ANSI_N, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_T,
            kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
            kVK_ANSI_Y,
            kVK_ANSI_0, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7,
            kVK_ANSI_8, kVK_ANSI_9,
            kVK_ANSI_Equal, kVK_ANSI_Minus, kVK_ANSI_LeftBracket,
            kVK_ANSI_RightBracket, kVK_ANSI_Semicolon, kVK_ANSI_Slash,
            kVK_ANSI_Quote, kVK_ANSI_Comma, kVK_ANSI_Period,
            kVK_ANSI_Grave, kVK_ANSI_Backslash
        ]
        for code in swallow {
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

