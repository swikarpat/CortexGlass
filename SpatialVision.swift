import Cocoa
import Carbon
import Vision
import ScreenCaptureKit
import CoreMedia
import CoreGraphics

// ============================================================================
// 1. Process Guard & Single-Instance Daemon Lock
// ============================================================================
let lockPath = "/tmp/com.swikar.spatialvision.lock"
let lock = open(lockPath, O_CREAT | O_WRONLY, 0o600)
if lock == -1 || flock(lock, LOCK_EX | LOCK_NB) != 0 { exit(0) }

// ============================================================================
// 2. State Machine Definition
// ============================================================================
enum PillState {
    case idle
    case analyzing
    case typing
    case awaitingRun
    case evaluating
    case awaitingSubmit
    case error(String)

    var badgeText: String {
        switch self {
        case .idle:           return "READY"
        case .analyzing:      return "ANALYZING"
        case .typing:         return "TYPING..."
        case .awaitingRun:    return "RUN TESTS NOW"
        case .evaluating:     return "EVALUATING"
        case .awaitingSubmit: return "ALL PASSED"
        case .error(let msg): return msg
        }
    }

    var subText: String {
        switch self {
        case .idle:           return "[Opt+S to Solve]"
        case .analyzing:      return "[Vision OCR + LLM]"
        case .typing:         return "[DO NOT TOUCH KB/MOUSE]"
        case .awaitingRun:    return "[Click 'Run Code' in Browser]"
        case .evaluating:     return "[Diagnosing Console Drawer]"
        case .awaitingSubmit: return "[Ready to Click Submit]"
        case .error:          return "[Opt+R to Reset]"
        }
    }

    var icon: String {
        switch self {
        case .idle:           return "●"
        case .analyzing:      return "⚡"
        case .typing:         return "⌨️"
        case .awaitingRun:    return "👉"
        case .evaluating:     return "⚠️"
        case .awaitingSubmit: return "🚀"
        case .error:          return "❌"
        }
    }

    var borderColor: NSColor {
        switch self {
        case .idle:           return NSColor(white: 0.45, alpha: 0.85)
        case .analyzing:      return NSColor(red: 0.98, green: 0.65, blue: 0.12, alpha: 0.95) // Amber
        case .typing:         return NSColor(red: 0.15, green: 0.78, blue: 0.98, alpha: 0.95) // Electric Cyan
        case .awaitingRun:    return NSColor(red: 0.10, green: 0.88, blue: 0.45, alpha: 1.0)  // Flashing Emerald
        case .evaluating:     return NSColor(red: 0.95, green: 0.25, blue: 0.35, alpha: 0.95) // Rose Red
        case .awaitingSubmit: return NSColor(red: 0.05, green: 0.95, blue: 0.40, alpha: 1.0)  // Solid Vibrant Green
        case .error:          return NSColor(red: 0.95, green: 0.15, blue: 0.15, alpha: 1.0)
        }
    }
}

// ============================================================================
// 3. Undetectable Hardware-Level Micro-HUD Pill View & Panel
// ============================================================================
class PillContentView: NSView {
    private let iconLabel = NSTextField(labelWithString: "●")
    private let titleLabel = NSTextField(labelWithString: "READY")
    private let hintLabel = NSTextField(labelWithString: "[Opt+S to Solve]")
    private var flashTimer: Timer?
    private var isFlashVisible = true
    var currentState: PillState = .idle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.masksToBounds = true
        layer?.borderWidth = 1.8
        layer?.backgroundColor = NSColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 0.92).cgColor
        
        setupLabels()
        applyState(.idle)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupLabels() {
        iconLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        iconLabel.alignment = .center
        iconLabel.frame = NSRect(x: 10, y: 11, width: 22, height: 20)
        addSubview(iconLabel)

        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .heavy)
        titleLabel.textColor = .white
        titleLabel.frame = NSRect(x: 34, y: 20, width: 220, height: 16)
        addSubview(titleLabel)

        hintLabel.font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)
        hintLabel.textColor = NSColor(white: 0.72, alpha: 0.9)
        hintLabel.frame = NSRect(x: 34, y: 6, width: 220, height: 14)
        addSubview(hintLabel)
    }

    func applyState(_ state: PillState) {
        currentState = state
        flashTimer?.invalidate()
        flashTimer = nil

        iconLabel.stringValue = state.icon
        titleLabel.stringValue = state.badgeText
        titleLabel.textColor = (state.badgeText == "READY") ? NSColor(white: 0.85, alpha: 1) : state.borderColor
        hintLabel.stringValue = state.subText
        layer?.borderColor = state.borderColor.cgColor

        if case .awaitingRun = state {
            // Flashing emerald border animation
            flashTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.isFlashVisible.toggle()
                self.layer?.borderColor = self.isFlashVisible ? state.borderColor.cgColor : NSColor.clear.cgColor
            }
        }
    }
}

class PillPanel: NSPanel {
    init(rect: NSRect) {
        super.init(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Compositor-level isolation: mathematically stripped from WebRTC, Zoom, Teams, and browser hooks
        sharingType = .none
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true // Zero mouse interference with active browser
        hasShadow = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// ============================================================================
// 4. Biometric Human-Jitter Typing Engine
// ============================================================================
class BiometricTyper {
    static let shared = BiometricTyper()
    private let lock = NSLock()
    private var _isCancelled = false
    private let workQueue = DispatchQueue(label: "com.swikar.spatialvision.typer.q", qos: .userInteractive)

    var isCancelled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isCancelled
        }
        set {
            lock.lock()
            _isCancelled = newValue
            lock.unlock()
        }
    }

    func cancel() {
        isCancelled = true
    }

    // High-resolution interruptible sleep that checks cancellation every 15ms
    // Guarantees <15ms abort latency upon Option + X panic abort
    @discardableResult
    private func interruptibleSleep(microseconds: useconds_t) -> Bool {
        var remaining = microseconds
        let chunk: useconds_t = 15_000
        while remaining > 0 {
            if isCancelled { return false }
            let sleepTime = min(remaining, chunk)
            usleep(sleepTime)
            remaining -= sleepTime
        }
        return !isCancelled
    }

    // Thread-safe UI state dispatch helper ensuring AppKit main-thread execution
    private func notifyProgress(_ state: PillState, callback: @escaping (PillState) -> Void) {
        DispatchQueue.main.async {
            callback(state)
        }
    }

    // Box-Muller Gaussian Inter-Keystroke Interval (µ = 65ms, σ = 25ms, clamped [30, 145]ms)
    private func sampleGaussianIKI() -> useconds_t {
        let u1 = max(1e-6, Double.random(in: 0.0...1.0))
        let u2 = Double.random(in: 0.0...1.0)
        let z = sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
        let val = 65.0 + z * 25.0
        let clamped = max(30.0, min(145.0, val))
        return useconds_t(clamped * 1000.0)
    }

    // Cognitive hesitation pause at semantic syntax boundaries (450ms - 950ms)
    private func isSyntaxBoundary(prev: Character?, current: Character) -> Bool {
        guard let p = prev else { return false }
        if p == ":" || p == "{" || p == ";" { return true }
        return false
    }

    // Adjacent keyboard key map for simulated typo generation
    private func adjacentTypoKey(for c: Character) -> Character {
        let qwertyAdj: [Character: String] = [
            "a": "sqwz", "b": "vngh", "c": "xdfv", "d": "serfcx", "e": "wsdr",
            "f": "drtgvc", "g": "ftyhbv", "h": "gyujnb", "i": "ujko", "j": "huikmn",
            "k": "jiolm", "l": "kop", "m": "njk", "n": "bhjm", "o": "iklp",
            "p": "ol", "q": "wa", "r": "edft", "s": "awedxz", "t": "rfgy",
            "u": "yhji", "v": "cfgb", "w": "qase", "x": "zsdc", "y": "tghu", "z": "asx"
        ]
        let lower = Character(c.lowercased())
        if let adj = qwertyAdj[lower], let randKey = adj.randomElement() {
            return c.isUppercase ? Character(randKey.uppercased()) : randKey
        }
        return "e"
    }

    // Kernel HID Event injection using CGEvent
    private func postUnicodeChar(_ char: Character) {
        var unichars = Array(String(char).utf16)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return }

        down.keyboardSetUnicodeString(stringLength: unichars.count, unicodeString: &unichars)
        up.keyboardSetUnicodeString(stringLength: unichars.count, unicodeString: &unichars)

        down.post(tap: .cghidEventTap)
        _ = interruptibleSleep(microseconds: useconds_t(Int.random(in: 12000...22000))) // Natural key hold duration
        up.post(tap: .cghidEventTap)
    }

    private func postVirtualKey(code: CGKeyCode, flags: CGEventFlags = []) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return }

        if !flags.isEmpty {
            down.flags = flags
            up.flags = flags
        }

        down.post(tap: .cghidEventTap)
        _ = interruptibleSleep(microseconds: useconds_t(Int.random(in: 14000...25000)))
        up.post(tap: .cghidEventTap)
    }

    // Select all code in active editor and clear (Cmd + A, Delete)
    func clearEditor() {
        if isCancelled { return }
        postVirtualKey(code: 0, flags: .maskCommand) // Cmd + A (kVK_ANSI_A = 0)
        if !interruptibleSleep(microseconds: 80_000) { return }
        postVirtualKey(code: 51) // Delete / Backspace (kVK_Delete = 51)
        _ = interruptibleSleep(microseconds: 100_000)
    }

    // Execute natural typing sequence with Monaco/Ace auto-indentation reconciliation
    func typeCode(_ code: String, clearBeforeTyping: Bool = false, onProgress: @escaping (PillState) -> Void) {
        isCancelled = false
        workQueue.async {
            self.notifyProgress(.typing, callback: onProgress)

            if clearBeforeTyping {
                self.clearEditor()
                if self.isCancelled {
                    self.notifyProgress(.idle, callback: onProgress)
                    return
                }
            }

            var charCount = 0
            var typoTarget = Int.random(in: 90...130)
            var prevChar: Character? = nil
            let lines = code.components(separatedBy: "\n")
            var expectedEditorIndent = 0

            for (lineIdx, line) in lines.enumerated() {
                if self.isCancelled { break }

                // Measure leading indentation (spaces / tabs)
                var actualIndent = 0
                var contentStartIndex = line.startIndex
                for idx in line.indices {
                    let ch = line[idx]
                    if ch == " " {
                        actualIndent += 1
                    } else if ch == "\t" {
                        actualIndent += 4
                    } else {
                        contentStartIndex = idx
                        break
                    }
                }

                let isAllWhitespace = (contentStartIndex == line.endIndex && actualIndent > 0)
                let content = isAllWhitespace ? "" : line[contentStartIndex...]
                let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)

                // Monaco/Ace Collision Reconciliation:
                // Competitive coding editors auto-indent when Return is pressed after structural tokens ({, :).
                // In addition, standard code editors preserve existing indentation on Return.
                if trimmedContent.isEmpty {
                    // Blank or whitespace-only line: do not alter indentation or type spaces.
                    // Preserve expectedEditorIndent for the next substantive line.
                } else if lineIdx == 0 {
                    // Line 0: Cursor was manually placed or cleared. Type required leading spaces.
                    for _ in 0..<actualIndent {
                        if self.isCancelled { break }
                        self.postUnicodeChar(" ")
                        if !self.interruptibleSleep(microseconds: self.sampleGaussianIKI()) { break }
                    }
                } else {
                    // Line 1+: Reconcile against editor's auto-indentation state
                    if actualIndent == expectedEditorIndent {
                        // Editor auto-indentation matches target column exactly. Skip leading spaces.
                    } else if actualIndent > expectedEditorIndent {
                        // Editor indented, but line requires deeper indentation. Type only delta spaces.
                        let extraSpaces = actualIndent - expectedEditorIndent
                        for _ in 0..<extraSpaces {
                            if self.isCancelled { break }
                            self.postUnicodeChar(" ")
                            if !self.interruptibleSleep(microseconds: self.sampleGaussianIKI()) { break }
                        }
                    } else {
                        // actualIndent < expectedEditorIndent: Editor indented too far (dedent / unindent)
                        // Emit Shift + Tab for 4-space indent units, Backspace for remaining spaces
                        let excess = expectedEditorIndent - actualIndent
                        let shiftTabs = excess / 4
                        let remainingBackspaces = excess % 4

                        for _ in 0..<shiftTabs {
                            if self.isCancelled { break }
                            self.postVirtualKey(code: 48, flags: .maskShift) // Shift + Tab (kVK_Tab = 48)
                            if !self.interruptibleSleep(microseconds: 35_000) { break }
                        }

                        for _ in 0..<remainingBackspaces {
                            if self.isCancelled { break }
                            self.postVirtualKey(code: 51) // Backspace (kVK_Delete = 51)
                            if !self.interruptibleSleep(microseconds: 25_000) { break }
                        }
                    }
                }

                if self.isCancelled { break }

                // Type non-whitespace code content with human jitter
                for char in content {
                    if self.isCancelled { break }

                    // Cognitive hesitation pause at syntax boundaries
                    if self.isSyntaxBoundary(prev: prevChar, current: char) {
                        let hesitation = useconds_t(Double.random(in: 0.45...0.95) * 1_000_000)
                        if !self.interruptibleSleep(microseconds: hesitation) { break }
                    }

                    // Simulated Typo Injection every 90-130 characters
                    charCount += 1
                    if charCount >= typoTarget && char.isLetter {
                        charCount = 0
                        typoTarget = Int.random(in: 90...130)

                        let badChar = self.adjacentTypoKey(for: char)
                        self.postUnicodeChar(badChar)
                        if !self.interruptibleSleep(microseconds: 180_000) { break } // Realization pause
                        self.postVirtualKey(code: 51) // Backspace
                        if !self.interruptibleSleep(microseconds: useconds_t(Int.random(in: 80000...130000))) { break }
                    }

                    // Type actual character
                    self.postUnicodeChar(char)
                    prevChar = char

                    // Inter-keystroke interval
                    let iki = self.sampleGaussianIKI()
                    if !self.interruptibleSleep(microseconds: iki) { break }
                }

                // Determine expectedEditorIndent for subsequent line
                if !trimmedContent.isEmpty {
                    let cleanLine = trimmedContent.components(separatedBy: "#").first?.trimmingCharacters(in: .whitespaces) ?? trimmedContent
                    if cleanLine.hasSuffix(":") || cleanLine.hasSuffix("{") {
                        expectedEditorIndent = actualIndent + 4
                    } else {
                        expectedEditorIndent = actualIndent
                    }
                }

                // Newline handling
                if lineIdx < lines.count - 1 {
                    self.postVirtualKey(code: 36) // Return (kVK_Return = 36)
                    let returnDelay = useconds_t(Int.random(in: 90000...180000))
                    if !self.interruptibleSleep(microseconds: returnDelay) { break }
                    prevChar = "\n"
                }
            }

            if !self.isCancelled {
                self.notifyProgress(.awaitingRun, callback: onProgress)
            } else {
                self.notifyProgress(.idle, callback: onProgress)
            }
        }
    }
}

// ============================================================================
// 5. Spatial Split-Pane OCR & Sliding Overlap Deduplicator
// ============================================================================
class SpatialOCRManager {
    static let shared = SpatialOCRManager()
    private var accumulatedProblemLines: [String] = []

    func reset() {
        accumulatedProblemLines.removeAll()
    }

    // Captures Retina display buffer and splits text by X-coordinate
    func captureSplitScreen() async -> (problemText: String, editorText: String)? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return nil }

            let myPID = ProcessInfo.processInfo.processIdentifier
            let excluded = content.windows.filter { $0.owningApplication?.processID == myPID }

            let config = SCStreamConfiguration()
            config.width = Int(display.width)
            config.height = Int(display.height)
            config.showsCursor = false

            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]

            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            guard let results = request.results, !results.isEmpty else { return nil }

            var leftObservations: [(text: String, box: CGRect)] = []
            var rightObservations: [(text: String, box: CGRect)] = []

            for obs in results {
                guard let candidate = obs.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty else { continue }
                let box = obs.boundingBox // Normalized [0, 1] coordinates (bottom-left origin)

                // Split at X = 0.52: Left is problem specification, Right is code editor & console
                if box.midX <= 0.52 {
                    leftObservations.append((candidate, box))
                } else {
                    rightObservations.append((candidate, box))
                }
            }

            // Sort vertical descending (top of screen to bottom)
            let sortedLeft = leftObservations.sorted { $0.box.midY > $1.box.midY }.map { $0.text }
            let sortedRight = rightObservations.sorted { $0.box.midY > $1.box.midY }.map { $0.text }

            let leftStitched = self.stitchScrollBuffer(incomingLines: sortedLeft)
            let rightRaw = sortedRight.joined(separator: "\n")

            return (problemText: leftStitched, editorText: rightRaw)
        } catch {
            print("❌ OCR Error: \(error.localizedDescription)")
            return nil
        }
    }

    // Sliding Overlap Deduplicator across user scroll events
    private func stitchScrollBuffer(incomingLines: [String]) -> String {
        guard !incomingLines.isEmpty else { return accumulatedProblemLines.joined(separator: "\n") }

        if accumulatedProblemLines.isEmpty {
            accumulatedProblemLines = incomingLines
            return incomingLines.joined(separator: "\n")
        }

        // Divergence Check: If incoming screen shares zero overlap with previous buffer, a new problem was loaded
        let existingTokens = Set(accumulatedProblemLines.joined(separator: " ").lowercased().components(separatedBy: .whitespacesAndNewlines))
        let incomingTokens = Set(incomingLines.joined(separator: " ").lowercased().components(separatedBy: .whitespacesAndNewlines))
        let overlapRatio = Double(existingTokens.intersection(incomingTokens).count) / Double(max(1, incomingTokens.count))
        if overlapRatio < 0.12 && incomingLines.count > 6 {
            print("🔄 Divergence detected: Fresh problem statement loaded. Flushing buffer.")
            accumulatedProblemLines = incomingLines
            return incomingLines.joined(separator: "\n")
        }

        // Suffix-Prefix Matching (10 lines down to 2)
        let maxMatch = min(accumulatedProblemLines.count, incomingLines.count, 10)
        var matchCount = 0

        for count in stride(from: maxMatch, through: 2, by: -1) {
            let bufferSuffix = accumulatedProblemLines.suffix(count).map { $0.trimmingCharacters(in: .whitespaces) }
            let incomingPrefix = incomingLines.prefix(count).map { $0.trimmingCharacters(in: .whitespaces) }
            if Array(bufferSuffix) == Array(incomingPrefix) {
                matchCount = count
                break
            }
        }

        let freshLines = incomingLines.dropFirst(matchCount)
        accumulatedProblemLines.append(contentsOf: freshLines)
        return accumulatedProblemLines.joined(separator: "\n")
    }
}

// ============================================================================
// 6. Direct REST Intelligence Engine (Gemini 2.0 Flash REST Client)
// ============================================================================
class GeminiRESTClient {
    static let shared = GeminiRESTClient()

    // Resolves API key from environment variable or ~/.config/overlay/gemini_api_key.txt
    private func resolveAPIKey() -> String? {
        if let envKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !envKey.isEmpty {
            return envKey
        }
        let candidatePaths = [
            "~/.config/overlay/gemini_api_key.txt",
            "~/.config/overlay/api_key.txt"
        ]
        for candidate in candidatePaths {
            let path = NSString(string: candidate).expandingTildeInPath
            if let fileKey = try? String(contentsOfFile: path, encoding: .utf8) {
                let cleaned = fileKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    func requestSolution(problem: String, starterCode: String) async throws -> String {
        guard let apiKey = resolveAPIKey() else {
            throw NSError(domain: "SpatialVision", code: 401, userInfo: [NSLocalizedDescriptionKey: "GEMINI_API_KEY missing. Set env or ~/.config/overlay/gemini_api_key.txt"])
        }

        let prompt = """
        You are an autonomous algorithmic code solver.
        The candidate is in a competitive coding assessment (e.g. HackerRank, CodeSignal).

        PROBLEM STATEMENT & CONSTRAINTS:
        \(problem)

        CURRENT EDITOR BOILERPLATE & FUNCTION SIGNATURE:
        \(starterCode)

        STRICT SYSTEM INSTRUCTIONS:
        1. Return ONLY the executable code body that belongs directly INSIDE the pre-declared target function/method.
        2. Do NOT include markdown code blocks (``` or ```python), class definitions, or duplicate function signatures already present.
        3. Do NOT provide any explanatory prose, time complexity annotations, or comments.
        4. Match the exact parameter names and types present in the starter code.
        5. Optimize strictly for the required Big-O time and auxiliary space constraints.
        """

        return try await executeGeminiRequest(prompt: prompt, apiKey: apiKey)
    }

    func requestPatch(previousCode: String, consoleDiagnostics: String, problemContext: String) async throws -> String {
        guard let apiKey = resolveAPIKey() else {
            throw NSError(domain: "SpatialVision", code: 401, userInfo: [NSLocalizedDescriptionKey: "GEMINI_API_KEY missing"])
        }

        let prompt = """
        You are an autonomous algorithmic code debugger in a live assessment environment.
        The candidate clicked "Run Code", and test cases failed.

        PROBLEM CONTEXT:
        \(problemContext)

        PREVIOUS CODE IMPLEMENTATION:
        \(previousCode)

        FAILED TEST CONSOLE OUTPUT & TRACEBACK:
        \(consoleDiagnostics)

        TASK:
        1. Diagnose the exact edge-case failure, off-by-one error, or time limit exceeded bottleneck.
        2. Provide the complete corrected replacement code body for the function.
        3. Return ONLY the raw executable code body with zero markdown backticks (```), no function signature re-declarations, and no conversational prose.
        """

        return try await executeGeminiRequest(prompt: prompt, apiKey: apiKey)
    }

    private func executeGeminiRequest(prompt: String, apiKey: String) async throws -> String {
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=\(apiKey)"
        guard let url = URL(string: endpoint) else {
            throw NSError(domain: "SpatialVision", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15.0

        let body: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]]
            ],
            "generationConfig": [
                "temperature": 0.1,
                "maxOutputTokens": 4096
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            let errBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "SpatialVision", code: 500, userInfo: [NSLocalizedDescriptionKey: "Gemini HTTP error: \(errBody)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw NSError(domain: "SpatialVision", code: 502, userInfo: [NSLocalizedDescriptionKey: "Failed to parse Gemini response"])
        }

        return sanitizeGeneratedCode(text)
    }

    // Strips accidental markdown backticks or outer wrapper text
    private func sanitizeGeneratedCode(_ raw: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeFirst()
        }
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// ============================================================================
// 7. Global Hotkeys & Application Controller
// ============================================================================
class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: PillPanel!
    var pillView: PillContentView!
    var lastProblemText = ""
    var lastGeneratedCode = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // Strips Dock icon and system menu presence

        let s = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let pillW: CGFloat = 264
        let pillH: CGFloat = 40
        let rect = NSRect(x: s.midX - (pillW / 2), y: s.maxY - pillH - 8, width: pillW, height: pillH)

        panel = PillPanel(rect: rect)
        pillView = PillContentView(frame: NSRect(x: 0, y: 0, width: pillW, height: pillH))
        panel.contentView = pillView
        panel.orderFront(nil)

        setupHotkeys()
        print("🚀 SpatialVision Online: Pill Active at Top-Center. Hotkeys Ready.")
    }

    func setupHotkeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, theEvent, userData) -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(theEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let del = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { del.handleHotkey(hkID.id) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)

        let opt = UInt32(optionKey)
        let binds: [(UInt32, Int)] = [
            (1, kVK_ANSI_S), // Option + S : Solve & Inject
            (2, kVK_ANSI_T), // Option + T : Diagnose & Patch
            (3, kVK_ANSI_R), // Option + R : Reset State & Buffer
            (4, kVK_ANSI_X), // Option + X : Panic Abort
            (5, kVK_ANSI_Q)  // Option + Q : Clean Quit
        ]

        for (id, code) in binds {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(code), opt, EventHotKeyID(signature: OSType(0x5356), id: id), GetApplicationEventTarget(), 0, &ref)
        }

        // Dead-key chord swallow matrix (absorbs stray dead-key characters)
        let swallow = [
            kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F,
            kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
            kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_U, kVK_ANSI_V,
            kVK_ANSI_W, kVK_ANSI_Y, kVK_ANSI_Z, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7,
            kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0, kVK_ANSI_Semicolon, kVK_ANSI_Slash,
            kVK_ANSI_Quote, kVK_ANSI_Comma, kVK_ANSI_Period, kVK_ANSI_Grave, kVK_ANSI_Backslash
        ]
        for code in swallow {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(code), opt, EventHotKeyID(signature: OSType(0x5356), id: 9999), GetApplicationEventTarget(), 0, &ref)
        }
    }

    func handleHotkey(_ id: UInt32) {
        switch id {
        case 1: // Option + S: Solve & Inject
            triggerSolvePipeline()
        case 2: // Option + T: Diagnose & Patch
            triggerPatchPipeline()
        case 3: // Option + R: Reset
            resetAll()
        case 4: // Option + X: Panic Abort
            panicAbort()
        case 5: // Option + Q: Quit
            exit(0)
        default:
            break
        }
    }

    // Option + S : Solve & Human-Jitter Inject
    func triggerSolvePipeline() {
        pillView.applyState(.analyzing)
        Task { [weak self] in
            guard let self = self else { return }
            guard let split = await SpatialOCRManager.shared.captureSplitScreen() else {
                await MainActor.run { self.pillView.applyState(.error("OCR FAILED")) }
                return
            }

            self.lastProblemText = split.problemText
            print("⚡ Problem Analyzed (\(split.problemText.count) chars). Calling Gemini REST...")

            do {
                let code = try await GeminiRESTClient.shared.requestSolution(problem: split.problemText, starterCode: split.editorText)
                self.lastGeneratedCode = code
                print("🎯 Optimal Code Generated (\(code.count) chars). Beginning Biometric Typing...")

                await MainActor.run {
                    BiometricTyper.shared.typeCode(code) { [weak self] state in
                        self?.pillView.applyState(state)
                    }
                }
            } catch {
                print("❌ REST Intelligence Error: \(error.localizedDescription)")
                await MainActor.run {
                    let msg = error.localizedDescription.contains("API_KEY") ? "NO API KEY" : "REST ERROR"
                    self.pillView.applyState(.error(msg))
                }
            }
        }
    }

    // Option + T : Closed-Loop Test Failure Diagnosis & Patch
    func triggerPatchPipeline() {
        pillView.applyState(.evaluating)
        Task { [weak self] in
            guard let self = self else { return }
            guard let split = await SpatialOCRManager.shared.captureSplitScreen() else {
                await MainActor.run { self.pillView.applyState(.error("OCR FAILED")) }
                return
            }

            print("⚠️ Diagnosing Test Failure Console Drawer (\(split.editorText.count) chars)...")

            do {
                let patch = try await GeminiRESTClient.shared.requestPatch(
                    previousCode: self.lastGeneratedCode,
                    consoleDiagnostics: split.editorText,
                    problemContext: self.lastProblemText
                )
                self.lastGeneratedCode = patch
                print("🛠️ In-Place Patch Synthesized (\(patch.count) chars). Replacing previous code...")

                await MainActor.run {
                    BiometricTyper.shared.typeCode(patch, clearBeforeTyping: true) { [weak self] state in
                        self?.pillView.applyState(state)
                    }
                }
            } catch {
                print("❌ Patch Error: \(error.localizedDescription)")
                await MainActor.run {
                    self.pillView.applyState(.error("PATCH ERROR"))
                }
            }
        }
    }

    func resetAll() {
        BiometricTyper.shared.cancel()
        SpatialOCRManager.shared.reset()
        lastProblemText = ""
        lastGeneratedCode = ""
        pillView.applyState(.idle)
        print("🔄 SpatialVision State & Buffers Reset to IDLE.")
    }

    func panicAbort() {
        BiometricTyper.shared.cancel()
        pillView.applyState(.idle)
        print("🛑 PANIC ABORT TRIGGERED: Typing halted instantly.")
    }
}

// ============================================================================
// 8. Application Entry Point
// ============================================================================
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
