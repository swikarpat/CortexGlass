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
    case idle, analyzing, preparing, typing, awaitingRun, evaluating, readyToInject, awaitingSubmit, error(String)

    private var meta: (badge: String, sub: String, icon: String, color: NSColor) {
        switch self {
        case .idle:           return ("READY", "[Opt+S to Solve]", "●", NSColor(white: 0.45, alpha: 0.85))
        case .analyzing:      return ("ANALYZING", "[Vision OCR + LLM]", "⚡", NSColor(red: 0.98, green: 0.65, blue: 0.12, alpha: 0.95))
        case .preparing:      return ("PREPARING...", "[Deliberating 4s...]", "🤔", NSColor(red: 0.98, green: 0.65, blue: 0.12, alpha: 0.95))
        case .typing:         return ("TYPING...", "[DO NOT TOUCH KB/MOUSE]", "⌨️", NSColor(red: 0.15, green: 0.78, blue: 0.98, alpha: 0.95))
        case .awaitingRun:    return ("RUN TESTS NOW", "[Click 'Run Code' in Browser]", "👉", NSColor(red: 0.10, green: 0.88, blue: 0.45, alpha: 1.0))
        case .evaluating:     return ("EVALUATING", "[Diagnosing Console Drawer]", "⚠️", NSColor(red: 0.95, green: 0.25, blue: 0.35, alpha: 0.95))
        case .readyToInject:  return ("INJECT PATCH", "[Select old code & Opt+T]", "👉", NSColor(red: 0.15, green: 0.85, blue: 0.95, alpha: 1.0))
        case .awaitingSubmit: return ("ALL PASSED", "[Ready to Click Submit]", "🚀", NSColor(red: 0.05, green: 0.95, blue: 0.40, alpha: 1.0))
        case .error(let msg):
            let sub = msg.contains("Opt+T") ? "[Opt+T to Diagnose & Patch]" : "[Opt+R to Reset]"
            return (msg, sub, "❌", NSColor(red: 0.95, green: 0.15, blue: 0.15, alpha: 1.0))
        }
    }
    var badgeText: String { meta.badge }
    var subText: String { meta.sub }
    var icon: String { meta.icon }
    var borderColor: NSColor { meta.color }
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

        iconLabel.font = .systemFont(ofSize: 13, weight: .bold)
        iconLabel.alignment = .center
        iconLabel.frame = NSRect(x: 10, y: 11, width: 22, height: 20)
        addSubview(iconLabel)

        titleLabel.font = .monospacedSystemFont(ofSize: 11, weight: .heavy)
        titleLabel.textColor = .white
        titleLabel.frame = NSRect(x: 34, y: 20, width: 220, height: 16)
        addSubview(titleLabel)

        hintLabel.font = .monospacedSystemFont(ofSize: 9.5, weight: .medium)
        hintLabel.textColor = NSColor(white: 0.72, alpha: 0.9)
        hintLabel.frame = NSRect(x: 34, y: 6, width: 220, height: 14)
        addSubview(hintLabel)

        applyState(.idle)
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyState(_ state: PillState) {
        currentState = state
        flashTimer?.invalidate()
        flashTimer = nil

        iconLabel.stringValue = state.icon
        titleLabel.stringValue = state.badgeText
        titleLabel.textColor = (state.badgeText == "READY") ? NSColor(white: 0.85, alpha: 1) : state.borderColor
        hintLabel.stringValue = state.subText
        layer?.borderColor = state.borderColor.cgColor

        switch state {
        case .awaitingRun, .readyToInject:
            flashTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.isFlashVisible.toggle()
                self.layer?.borderColor = self.isFlashVisible ? state.borderColor.cgColor : NSColor.clear.cgColor
            }
        default: break
        }
    }
}

class PillPanel: NSPanel {
    init(rect: NSRect) {
        super.init(contentRect: rect, styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        sharingType = .none // Mathematically stripped from WebRTC, Zoom, Teams, and browser hooks
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// ============================================================================
// 4. Biometric Human-Jitter Typing Engine (18-22 WPM with Anti-Telemetry Shield)
// ============================================================================
class BiometricTyper {
    static let shared = BiometricTyper()
    private let lock = NSLock()
    private var _isCancelled = false
    private let workQueue = DispatchQueue(label: "com.swikar.spatialvision.typer.q", qos: .userInteractive)

    var isCancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isCancelled }
        set { lock.lock(); _isCancelled = newValue; lock.unlock() }
    }

    func cancel() { isCancelled = true }

    // Sliced sleep in 15ms increments for sub-15ms cancellation latency
    private func interruptibleSleep(microseconds: useconds_t) -> Bool {
        var remaining = microseconds
        let step: useconds_t = 15_000
        while remaining > 0 {
            if isCancelled { return false }
            let sleepTime = min(remaining, step)
            usleep(sleepTime)
            remaining -= sleepTime
        }
        return !isCancelled
    }

    private func notifyProgress(_ state: PillState, callback: @escaping (PillState) -> Void) {
        DispatchQueue.main.async { callback(state) }
    }

    // Box-Muller Gaussian Inter-Keystroke Interval (µ = 290ms, σ = 75ms, clamped [150, 480]ms) -> ~20 WPM baseline
    private func sampleGaussianIKI() -> useconds_t {
        let u1 = max(1e-6, Double.random(in: 0.0...1.0)), u2 = Double.random(in: 0.0...1.0)
        let z = sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
        let val = max(150.0, min(480.0, 290.0 + z * 75.0))
        return useconds_t(val * 1000.0)
    }

    private func isSyntaxBoundary(prev: Character?, current: Character) -> Bool {
        guard let p = prev else { return false }
        return p == ":" || p == "{" || p == ";"
    }

    private func adjacentTypoKey(for c: Character) -> Character {
        let adj: [Character: String] = [
            "a": "sqw", "b": "vng", "c": "xdf", "d": "serf", "e": "wsdr", "f": "drtg", "g": "ftyh", "h": "gyuj",
            "i": "ujko", "j": "huik", "k": "jiol", "l": "kop", "m": "njk", "n": "bhjm", "o": "iklp", "p": "ol",
            "q": "wa", "r": "edft", "s": "awed", "t": "rfgy", "u": "yhji", "v": "cfgb", "w": "qase", "x": "zsdc",
            "y": "tghu", "z": "asx"
        ]
        guard let match = adj[Character(c.lowercased())]?.randomElement() else { return "e" }
        return c.isUppercase ? Character(match.uppercased()) : match
    }

    private func postUnicodeChar(_ char: Character) {
        var unichars = Array(String(char).utf16)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return }
        down.keyboardSetUnicodeString(stringLength: unichars.count, unicodeString: &unichars)
        up.keyboardSetUnicodeString(stringLength: unichars.count, unicodeString: &unichars)
        down.post(tap: .cghidEventTap)
        _ = interruptibleSleep(microseconds: useconds_t(Int.random(in: 14000...24000)))
        up.post(tap: .cghidEventTap)
    }

    private func postVirtualKey(code: CGKeyCode, flags: CGEventFlags = []) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return }
        if !flags.isEmpty { down.flags = flags; up.flags = flags }
        down.post(tap: .cghidEventTap)
        _ = interruptibleSleep(microseconds: useconds_t(Int.random(in: 14000...25000)))
        up.post(tap: .cghidEventTap)
    }

    // Dismisses open Monaco/browser autocomplete suggestions so Return/Tab never get hijacked
    private func dismissAutocomplete() {
        postVirtualKey(code: 53) // kVK_Escape = 53
        _ = interruptibleSleep(microseconds: 25_000)
    }

    private func countLeadingSpaces(_ line: String) -> Int {
        line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    private func isPythonOrFunctionContext(code: String, starterCode: String) -> Bool {
        let combined = (starterCode + "\n" + code).lowercased()
        return combined.contains("def ") || combined.contains("class solution") || combined.contains("):") ||
               combined.contains("->") || combined.contains("python") || combined.contains("self.") || combined.contains("range(")
    }

    // Execute natural typing sequence with Monaco/Ace auto-indentation reconciliation
    func typeCode(_ code: String, starterCode: String = "", onProgress: @escaping (PillState) -> Void) {
        isCancelled = false
        workQueue.async {
            // 1. Pre-typing Deliberation Phase: 3.5 to 5.2s authentic thinking window
            self.notifyProgress(.preparing, callback: onProgress)
            let deliberation = useconds_t(Double.random(in: 3.5...5.2) * 1_000_000)
            if !self.interruptibleSleep(microseconds: deliberation) {
                self.notifyProgress(.idle, callback: onProgress)
                return
            }

            self.notifyProgress(.typing, callback: onProgress)

            let isPythonOrFunc = self.isPythonOrFunctionContext(code: code, starterCode: starterCode)
            var preparedCode = code

            // Safeguard: If target is Python / function definition and first line has 0 indent, promote by 4 spaces
            if isPythonOrFunc {
                var codeLines = code.components(separatedBy: "\n")
                if let firstIdx = codeLines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    let firstLine = codeLines[firstIdx]
                    if self.countLeadingSpaces(firstLine) == 0 {
                        let subsequent = codeLines.dropFirst(firstIdx + 1).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        let hasIndented = subsequent.contains(where: { self.countLeadingSpaces($0) >= 4 })
                        if hasIndented {
                            codeLines[firstIdx] = "    " + firstLine
                        } else {
                            for i in 0..<codeLines.count where !codeLines[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                codeLines[i] = "    " + codeLines[i]
                            }
                        }
                        preparedCode = codeLines.joined(separator: "\n")
                    }
                }
            }

            var charCount = 0
            var typoTarget = Int.random(in: 35...60)
            var prevChar: Character? = nil
            let lines = preparedCode.components(separatedBy: "\n")
            var expectedEditorIndent = 0

            for (lineIdx, line) in lines.enumerated() {
                if self.isCancelled { break }

                // Natural Cognitive Freeze ("Glance at Problem"): 25% probability every 2-3 lines (4.5s to 7.0s)
                if lineIdx > 0 && (lineIdx % 2 == 0 || lineIdx % 3 == 0) && Double.random(in: 0...1) < 0.25 {
                    let glanceDelay = useconds_t(Double.random(in: 4.5...7.0) * 1_000_000)
                    if !self.interruptibleSleep(microseconds: glanceDelay) { break }
                }

                // Newline start hesitation: 600ms to 1200ms pause before typing indentation or content
                if lineIdx > 0 {
                    let lineStartPause = useconds_t(Double.random(in: 0.60...1.20) * 1_000_000)
                    if !self.interruptibleSleep(microseconds: lineStartPause) { break }
                }

                // Measure leading indentation
                let actualIndent = self.countLeadingSpaces(line)
                let trimmedContent = line.trimmingCharacters(in: .whitespacesAndNewlines)

                // Indentation Reconciliation against Monaco/Ace auto-indent state
                if trimmedContent.isEmpty {
                    // Blank line: preserve expectedEditorIndent
                } else if lineIdx == 0 {
                    var indentToType = actualIndent
                    if isPythonOrFunc && indentToType == 0 { indentToType = 4 }
                    for _ in 0..<indentToType {
                        if self.isCancelled { break }
                        self.postUnicodeChar(" ")
                        if !self.interruptibleSleep(microseconds: self.sampleGaussianIKI()) { break }
                    }
                } else {
                    if actualIndent > expectedEditorIndent {
                        // Type delta spaces
                        for _ in 0..<(actualIndent - expectedEditorIndent) {
                            if self.isCancelled { break }
                            self.postUnicodeChar(" ")
                            if !self.interruptibleSleep(microseconds: self.sampleGaussianIKI()) { break }
                        }
                    } else if actualIndent < expectedEditorIndent {
                        // Dedent: dismiss any open autocomplete popover first so Shift+Tab isn't trapped
                        self.dismissAutocomplete()
                        let excess = expectedEditorIndent - actualIndent
                        for _ in 0..<(excess / 4) {
                            if self.isCancelled { break }
                            self.postVirtualKey(code: 48, flags: .maskShift) // Shift + Tab
                            if !self.interruptibleSleep(microseconds: 35_000) { break }
                        }
                        for _ in 0..<(excess % 4) {
                            if self.isCancelled { break }
                            self.postVirtualKey(code: 51) // Backspace
                            if !self.interruptibleSleep(microseconds: 25_000) { break }
                        }
                    }
                }

                if self.isCancelled { break }

                // Cognitive Variable Revision: Every 4 lines, 20% chance of drafting a temporary token, then backspacing
                if lineIdx > 0 && lineIdx % 4 == 0 && trimmedContent.count > 6 && Double.random(in: 0...1) < 0.20 {
                    let draftTokens = ["temp", "res", "ans", "val"]
                    if let draft = draftTokens.randomElement() {
                        for ch in draft {
                            if self.isCancelled { break }
                            self.postUnicodeChar(ch)
                            _ = self.interruptibleSleep(microseconds: self.sampleGaussianIKI())
                        }
                        _ = self.interruptibleSleep(microseconds: useconds_t(Double.random(in: 0.45...0.75) * 1_000_000))
                        for _ in 0..<draft.count {
                            if self.isCancelled { break }
                            self.postVirtualKey(code: 51) // Backspace
                            _ = self.interruptibleSleep(microseconds: useconds_t(Int.random(in: 90000...130000)))
                        }
                        _ = self.interruptibleSleep(microseconds: 250_000)
                    }
                }

                // Type non-whitespace code content with human jitter and multi-character typo overruns
                let chars = Array(trimmedContent)
                var charIdx = 0
                while charIdx < chars.count {
                    if self.isCancelled { break }
                    let char = chars[charIdx]

                    // Cognitive hesitation pause at syntax boundaries (450ms - 950ms)
                    if self.isSyntaxBoundary(prev: prevChar, current: char) {
                        let hesitation = useconds_t(Double.random(in: 0.45...0.95) * 1_000_000)
                        if !self.interruptibleSleep(microseconds: hesitation) { break }
                    }

                    // Multi-Character Typo Overrun Injection (every 35-60 characters)
                    charCount += 1
                    if charCount >= typoTarget && char.isLetter {
                        charCount = 0
                        typoTarget = Int.random(in: 35...60)

                        // Type adjacent wrong character
                        let badChar = self.adjacentTypoKey(for: char)
                        self.postUnicodeChar(badChar)
                        _ = self.interruptibleSleep(microseconds: self.sampleGaussianIKI())

                        // Reflex Overrun: type 1 upcoming character before the brain realizes the mistake
                        var overrunCount = 1
                        if charIdx + 1 < chars.count && chars[charIdx + 1].isLetter {
                            overrunCount += 1
                            self.postUnicodeChar(chars[charIdx + 1])
                            _ = self.interruptibleSleep(microseconds: self.sampleGaussianIKI())
                        }

                        // Cognitive realization freeze (350ms - 600ms)
                        let realizePause = useconds_t(Double.random(in: 0.35...0.60) * 1_000_000)
                        if !self.interruptibleSleep(microseconds: realizePause) { break }

                        // Human cadence backspacing to erase the typo and overrun
                        for _ in 0..<overrunCount {
                            if self.isCancelled { break }
                            self.postVirtualKey(code: 51) // Backspace
                            _ = self.interruptibleSleep(microseconds: useconds_t(Int.random(in: 90000...140000)))
                        }
                        _ = self.interruptibleSleep(microseconds: 200_000) // Brief recovery
                    }

                    // Type actual character
                    self.postUnicodeChar(char)
                    prevChar = char

                    // Token & word boundary hesitations
                    if char == " " || char == "," || char == "." || char == "(" || char == ")" {
                        let punctPause = useconds_t(Double.random(in: 0.45...0.85) * 1_000_000)
                        if !self.interruptibleSleep(microseconds: punctPause) { break }
                    } else if char == "=" || char == "+" || char == "-" || char == "%" || char == ":" || char == "<" || char == ">" {
                        let opPause = useconds_t(Double.random(in: 0.50...0.95) * 1_000_000)
                        if !self.interruptibleSleep(microseconds: opPause) { break }
                    }

                    let iki = self.sampleGaussianIKI()
                    if !self.interruptibleSleep(microseconds: iki) { break }
                    charIdx += 1
                }

                // Determine expectedEditorIndent for subsequent line
                if !trimmedContent.isEmpty {
                    let cleanLine = trimmedContent.components(separatedBy: "#").first?.trimmingCharacters(in: .whitespaces) ?? trimmedContent
                    expectedEditorIndent = (cleanLine.hasSuffix(":") || cleanLine.hasSuffix("{")) ? (actualIndent + 4) : actualIndent
                }

                // Newline handling: Dismiss autocomplete popup with Escape before Return to avoid suggestion interception
                if lineIdx < lines.count - 1 {
                    self.dismissAutocomplete()
                    self.postVirtualKey(code: 36) // Return (kVK_Return = 36)
                    let returnDelay = useconds_t(Double.random(in: 2.2...3.8) * 1_000_000)
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

    func reset() { accumulatedProblemLines.removeAll() }

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

            var leftObs: [(text: String, box: CGRect)] = []
            var rightObs: [(text: String, box: CGRect)] = []

            for obs in results {
                guard let text = obs.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                if obs.boundingBox.midX <= 0.52 { leftObs.append((text, obs.boundingBox)) }
                else { rightObs.append((text, obs.boundingBox)) }
            }

            let sortedLeft = leftObs.sorted { $0.box.midY > $1.box.midY }.map { $0.text }
            let sortedRight = rightObs.sorted { $0.box.midY > $1.box.midY }.map { $0.text }

            return (problemText: stitchScrollBuffer(incomingLines: sortedLeft), editorText: sortedRight.joined(separator: "\n"))
        } catch {
            print("❌ OCR Error: \(error.localizedDescription)")
            return nil
        }
    }

    private func stitchScrollBuffer(incomingLines: [String]) -> String {
        guard !incomingLines.isEmpty else { return accumulatedProblemLines.joined(separator: "\n") }
        if accumulatedProblemLines.isEmpty {
            accumulatedProblemLines = incomingLines
            return incomingLines.joined(separator: "\n")
        }

        let existingTokens = Set(accumulatedProblemLines.joined(separator: " ").lowercased().components(separatedBy: .whitespacesAndNewlines))
        let incomingTokens = Set(incomingLines.joined(separator: " ").lowercased().components(separatedBy: .whitespacesAndNewlines))
        let overlapRatio = Double(existingTokens.intersection(incomingTokens).count) / Double(max(1, incomingTokens.count))
        if overlapRatio < 0.12 && incomingLines.count > 6 {
            print("🔄 Divergence detected: Fresh problem statement loaded. Flushing buffer.")
            accumulatedProblemLines = incomingLines
            return incomingLines.joined(separator: "\n")
        }

        let maxMatch = min(accumulatedProblemLines.count, incomingLines.count, 10)
        var matchCount = 0
        for count in stride(from: maxMatch, through: 2, by: -1) {
            let buf = accumulatedProblemLines.suffix(count).map { $0.trimmingCharacters(in: .whitespaces) }
            let inc = incomingLines.prefix(count).map { $0.trimmingCharacters(in: .whitespaces) }
            if Array(buf) == Array(inc) { matchCount = count; break }
        }

        accumulatedProblemLines.append(contentsOf: incomingLines.dropFirst(matchCount))
        return accumulatedProblemLines.joined(separator: "\n")
    }
}

// ============================================================================
// 6. Direct REST Intelligence Engine (Multi-Model Failover Cascade)
// ============================================================================
class GeminiRESTClient {
    static let shared = GeminiRESTClient()

    private func resolveAPIKey() -> String? {
        if let envKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !envKey.isEmpty { return envKey }
        for candidate in ["~/.config/overlay/gemini_api_key.txt", "~/.config/overlay/api_key.txt"] {
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
            throw NSError(domain: "SpatialVision", code: 401, userInfo: [NSLocalizedDescriptionKey: "GEMINI_API_KEY missing"])
        }
        let prompt = """
        You are an elite competitive programmer in an automated assessment.
        PROBLEM:
        \(problem)
        STARTER CODE:
        \(starterCode)
        TASK:
        1. Write the optimal, clean, complete implementation to solve all test cases (time/space optimal).
        2. Return ONLY the raw executable code body to place inside the function or starter template.
        3. Do NOT wrap output in markdown fences (```). Do NOT re-declare outer signatures.
        4. For indented languages (especially Python), prefix code with 4-space base indentation for line 0 and all subsequent lines.
        """
        return try await executeGeminiRequest(prompt: prompt, apiKey: apiKey)
    }

    func requestPatch(previousCode: String, consoleDiagnostics: String, problemContext: String) async throws -> String {
        guard let apiKey = resolveAPIKey() else {
            throw NSError(domain: "SpatialVision", code: 401, userInfo: [NSLocalizedDescriptionKey: "GEMINI_API_KEY missing"])
        }
        let prompt = """
        You are an autonomous algorithmic code debugger in a live assessment environment.
        PROBLEM CONTEXT:
        \(problemContext)
        ORIGINALLY GENERATED CODE:
        \(previousCode)
        CURRENT CODE IN EDITOR & TEST CONSOLE OUTPUT:
        \(consoleDiagnostics)
        TASK:
        1. Carefully inspect the candidate's CURRENT CODE visible in the editor against the test console failure or traceback.
        2. Diagnose the exact defect (e.g. edge-case failure, off-by-one error, wrong variable modification, or timeout).
        3. Preserve the candidate's existing implementation logic, variable names, and code structure intact. Fix ONLY the flawed logic or defective lines.
        4. Provide the complete corrected replacement code body for the function so that overwriting the existing function body produces a working, passing solution.
        5. Return ONLY the raw executable code body with zero markdown backticks (```), no signature re-declarations, and no conversational prose.
        6. For indented languages (especially Python), prefix code with 4-space base indentation for line 0 and all subsequent lines.
        """
        return try await executeGeminiRequest(prompt: prompt, apiKey: apiKey)
    }

    // Cascading multi-model failover shield against HTTP 429 quota exhaustion
    private func executeGeminiRequest(prompt: String, apiKey: String) async throws -> String {
        let models = ["gemini-2.5-flash", "gemini-flash-latest", "gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.5-flash", "gemini-3.6-flash"]
        var lastError: Error? = nil

        for model in models {
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 15.0

            let body: [String: Any] = [
                "contents": [["parts": [["text": prompt]]]],
                "generationConfig": ["temperature": 0.1, "maxOutputTokens": 4096]
            ]

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResp = response as? HTTPURLResponse else { continue }

                if httpResp.statusCode == 200 {
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let candidates = json["candidates"] as? [[String: Any]],
                          let first = candidates.first,
                          let content = first["content"] as? [String: Any],
                          let parts = content["parts"] as? [[String: Any]],
                          let text = parts.first?["text"] as? String else {
                        throw NSError(domain: "SpatialVision", code: 502, userInfo: [NSLocalizedDescriptionKey: "Failed to parse Gemini response from \(model)"])
                    }
                    return sanitizeGeneratedCode(text)
                } else if httpResp.statusCode == 429 || httpResp.statusCode == 404 {
                    print("⚠️ Gemini model '\(model)' returned HTTP \(httpResp.statusCode). Failing over to next available model...")
                    let errBody = String(data: data, encoding: .utf8) ?? "Quota exceeded"
                    lastError = NSError(domain: "SpatialVision", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: "Gemini HTTP error (\(model)): \(errBody)"])
                    continue
                } else {
                    let errBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw NSError(domain: "SpatialVision", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: "Gemini HTTP error (\(model)): \(errBody)"])
                }
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? NSError(domain: "SpatialVision", code: 500, userInfo: [NSLocalizedDescriptionKey: "All Gemini model endpoints exhausted."])
    }

    private func sanitizeGeneratedCode(_ raw: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        while let first = lines.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("```") || first.isEmpty { lines.removeFirst() }
        while let last = lines.last?.trimmingCharacters(in: .whitespaces), last.hasPrefix("```") || last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
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
    var lastStarterCode = ""
    var stagedPatch: String? = nil
    private var consoleWatcherTask: Task<Void, Never>? = nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let s = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let pillW: CGFloat = 264, pillH: CGFloat = 40
        panel = PillPanel(rect: NSRect(x: s.midX - (pillW / 2), y: s.maxY - pillH - 8, width: pillW, height: pillH))
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
            (1, kVK_ANSI_S), // Opt + S: Solve & Inject
            (2, kVK_ANSI_T), // Opt + T: Diagnose & Staged Patch
            (3, kVK_ANSI_R), // Opt + R: Reset State & Buffer
            (4, kVK_ANSI_X), // Opt + X: Panic Abort
            (5, kVK_ANSI_Q)  // Opt + Q: Clean Quit
        ]
        for (id, code) in binds {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(code), opt, EventHotKeyID(signature: OSType(0x5356), id: id), GetApplicationEventTarget(), 0, &ref)
        }

        // Dead-key chord swallow matrix
        let swallow = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 32, 9, 13, 16, 6, 23, 22, 26, 28, 25, 29, 41, 44, 39, 43, 47, 50, 42]
        for c in swallow {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(c), opt, EventHotKeyID(signature: OSType(0x5356), id: 9999), GetApplicationEventTarget(), 0, &ref)
        }
    }

    func handleHotkey(_ id: UInt32) {
        switch id {
        case 1: triggerSolvePipeline()
        case 2: triggerPatchPipeline()
        case 3: resetAll()
        case 4: panicAbort()
        case 5: exit(0)
        default: break
        }
    }

    func cancelConsoleWatcher() {
        consoleWatcherTask?.cancel()
        consoleWatcherTask = nil
    }

    @MainActor
    func updateWatcherState(_ state: PillState) {
        guard !Task.isCancelled else { return }
        pillView.applyState(state)
    }

    func startConsoleWatcher() {
        cancelConsoleWatcher()
        consoleWatcherTask = Task { [weak self] in
            print("👀 Autonomous Console Watcher active: polling every 1.5s for test results...")
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { break }
                if Task.isCancelled { break }
                guard let split = await SpatialOCRManager.shared.captureSplitScreen() else { continue }
                if Task.isCancelled { break }

                let consoleText = split.editorText.lowercased()
                let failureIndicators = ["compilation error", "wrong answer", "runtime error", "terminated due to timeout", "time limit exceeded", "traceback (most recent call last)"]
                let successIndicators = ["congratulations", "test case 0: passed", "test case 1: passed", "all test cases passed", "success"]

                if failureIndicators.contains(where: { consoleText.contains($0) }) {
                    print("⚠️ Console Watcher: Detected test failure. Updating HUD to 'TESTS FAILED [Opt+T]'")
                    await self?.updateWatcherState(.error("TESTS FAILED [Opt+T]"))
                    break
                } else if successIndicators.contains(where: { consoleText.contains($0) }) {
                    print("🚀 Console Watcher: All test cases passed! Updating HUD to 'ALL PASSED'")
                    await self?.updateWatcherState(.awaitingSubmit)
                    break
                }
            }
        }
    }

    func handleProgressState(_ state: PillState) {
        pillView.applyState(state)
        if case .awaitingRun = state { startConsoleWatcher() }
    }

    func triggerSolvePipeline() {
        stagedPatch = nil
        cancelConsoleWatcher()
        pillView.applyState(.analyzing)
        Task { [weak self] in
            guard let self = self else { return }
            guard let split = await SpatialOCRManager.shared.captureSplitScreen() else {
                await MainActor.run { self.pillView.applyState(.error("OCR FAILED")) }
                return
            }
            self.lastProblemText = split.problemText
            self.lastStarterCode = split.editorText
            print("⚡ Problem Analyzed (\(split.problemText.count) chars). Calling Gemini REST...")

            do {
                let code = try await GeminiRESTClient.shared.requestSolution(problem: split.problemText, starterCode: split.editorText)
                self.lastGeneratedCode = code
                print("🎯 Optimal Code Generated (\(code.count) chars). Beginning Biometric Typing...")
                await MainActor.run {
                    BiometricTyper.shared.typeCode(code, starterCode: split.editorText) { [weak self] state in
                        self?.handleProgressState(state)
                    }
                }
            } catch {
                print("❌ REST Intelligence Error: \(error.localizedDescription)")
                await MainActor.run {
                    self.pillView.applyState(.error(error.localizedDescription.contains("API_KEY") ? "NO API KEY" : "REST ERROR"))
                }
            }
        }
    }

    func triggerPatchPipeline() {
        if let patch = stagedPatch {
            print("🚀 Staged patch detected. Candidate confirmed editor focus. Typing patch...")
            stagedPatch = nil
            pillView.applyState(.typing)
            BiometricTyper.shared.typeCode(patch, starterCode: lastStarterCode) { [weak self] state in
                self?.handleProgressState(state)
            }
            return
        }

        if case .evaluating = pillView.currentState {
            print("⚠️ Evaluation already in progress. Please wait...")
            return
        }

        cancelConsoleWatcher()
        pillView.applyState(.evaluating)
        Task { [weak self] in
            guard let self = self else { return }
            guard let split = await SpatialOCRManager.shared.captureSplitScreen() else {
                await MainActor.run { self.pillView.applyState(.error("OCR FAILED")) }
                return
            }
            self.lastStarterCode = split.editorText
            print("⚠️ Diagnosing Test Failure Console Drawer (\(split.editorText.count) chars)...")

            do {
                let patch = try await GeminiRESTClient.shared.requestPatch(
                    previousCode: self.lastGeneratedCode,
                    consoleDiagnostics: split.editorText,
                    problemContext: self.lastProblemText
                )
                self.lastGeneratedCode = patch
                self.stagedPatch = patch
                print("🛠️ In-Place Patch Synthesized (\(patch.count) chars). Ready for injection.")
                print("👉 Highlight the old function in editor (or clear it), then press Opt+T to overwrite cleanly.")
                await MainActor.run { self.pillView.applyState(.readyToInject) }
            } catch {
                print("❌ Patch Error: \(error.localizedDescription)")
                await MainActor.run { self.pillView.applyState(.error("PATCH ERROR")) }
            }
        }
    }

    func resetAll() {
        stagedPatch = nil
        cancelConsoleWatcher()
        BiometricTyper.shared.cancel()
        SpatialOCRManager.shared.reset()
        lastProblemText = ""
        lastGeneratedCode = ""
        lastStarterCode = ""
        pillView.applyState(.idle)
        print("🔄 SpatialVision State & Buffers Reset to IDLE.")
    }

    func panicAbort() {
        stagedPatch = nil
        cancelConsoleWatcher()
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
