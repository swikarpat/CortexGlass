import Cocoa
import WebKit
import Carbon
import Vision
import ScreenCaptureKit
import CoreMedia
import CoreGraphics

// ============================================================================
// 1. Process Guard & Single-Instance Lock
// ============================================================================
let lock = open("/tmp/com.swikar.spatialvision.lock", O_CREAT | O_WRONLY, 0o600)
if lock == -1 || flock(lock, LOCK_EX | LOCK_NB) != 0 { exit(0) }

// ============================================================================
// 2. State Machine Definition
// ============================================================================
enum PillState {
    case idle, analyzing, preparing, typing, done, evaluating, diagnosticReady, error(String)

    var meta: (badge: String, sub: String, icon: String, color: NSColor) {
        let amber = NSColor(red: 0.98, green: 0.65, blue: 0.12, alpha: 0.95)
        let cyan = NSColor(red: 0.15, green: 0.85, blue: 0.95, alpha: 1.0)
        switch self {
        case .idle:            return ("READY", "[Opt+S to Solve]", "●", NSColor(white: 0.45, alpha: 0.85))
        case .analyzing:       return ("ANALYZING", "[Vision OCR + LLM]", "⚡", amber)
        case .preparing:       return ("PREPARING...", "[Deliberating 4s...]", "🤔", amber)
        case .typing:          return ("TYPING...", "[DO NOT TOUCH KB/MOUSE]", "⌨️", NSColor(red: 0.15, green: 0.78, blue: 0.98, alpha: 0.95))
        case .done:            return ("DONE - RUN TESTS", "[Click Run & Submit manually]", "🚀", NSColor(red: 0.05, green: 0.92, blue: 0.45, alpha: 1.0))
        case .evaluating:      return ("DIAGNOSING", "[Analyzing Test Output...]", "⚠️", amber)
        case .diagnosticReady: return ("FIX READY", "[Opt+Z to Hide]", "👉", cyan)
        case .error(let msg):  return (msg.isEmpty ? "ERROR" : msg, "[Opt+R to Reset]", "❌", NSColor(red: 0.95, green: 0.15, blue: 0.15, alpha: 1.0))
        }
    }
}

// ============================================================================
// 3. Undetectable Micro-HUD Pill View & Panel
// ============================================================================
class PillContentView: NSView {
    private let iconLabel = NSTextField(labelWithString: "●")
    private let titleLabel = NSTextField(labelWithString: "READY")
    private let hintLabel = NSTextField(labelWithString: "[Opt+S to Solve]")
    var currentState: PillState = .idle

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 20; layer?.masksToBounds = true; layer?.borderWidth = 1.8
        layer?.backgroundColor = NSColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 0.92).cgColor
        for (lbl, f, r) in [(iconLabel, NSFont.systemFont(ofSize: 13, weight: .bold), NSRect(x: 10, y: 11, width: 22, height: 20)),
                            (titleLabel, NSFont.monospacedSystemFont(ofSize: 11, weight: .heavy), NSRect(x: 34, y: 20, width: 220, height: 16)),
                            (hintLabel, NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium), NSRect(x: 34, y: 6, width: 220, height: 14))] {
            lbl.font = f; lbl.frame = r; addSubview(lbl)
        }
        iconLabel.alignment = .center; titleLabel.textColor = .white; hintLabel.textColor = NSColor(white: 0.72, alpha: 0.9)
        applyState(.idle)
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyState(_ state: PillState) {
        currentState = state
        let m = state.meta
        iconLabel.stringValue = m.icon; titleLabel.stringValue = m.badge
        titleLabel.textColor = (m.badge == "READY") ? NSColor(white: 0.85, alpha: 1) : m.color
        hintLabel.stringValue = m.sub; layer?.borderColor = m.color.cgColor
    }
}

class PillPanel: NSPanel {
    init(rect: NSRect) {
        super.init(contentRect: rect, styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        sharingType = .none; level = .floating; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false; backgroundColor = .clear; ignoresMouseEvents = true; hasShadow = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// ============================================================================
// 4. Undetectable Hardware-Level Spatial Panel (Diagnostics Window)
// ============================================================================
class SpatialPanel: NSPanel {
    var isInteractive = false

    init(rect: NSRect) {
        super.init(contentRect: rect, styleMask: [.nonactivatingPanel, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        sharingType = .none; level = .floating; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false; backgroundColor = .clear; ignoresMouseEvents = true; isMovableByWindowBackground = true
        contentView?.wantsLayer = true; contentView?.layer?.cornerRadius = 14; contentView?.layer?.masksToBounds = true
        contentView?.layer?.borderWidth = 2.0
        contentView?.layer?.borderColor = NSColor(red: 0.15, green: 0.85, blue: 0.95, alpha: 0.85).cgColor
        contentView?.layer?.backgroundColor = NSColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 0.95).cgColor
    }
    override var canBecomeKey: Bool { isInteractive }
    override var canBecomeMain: Bool { isInteractive }
}

// ============================================================================
// 5. Biometric Typer (Authentic Human Cognitive Simulation & Pure Arrow Navigation)
// ============================================================================
struct IntentionalMistake {
    let flawedLine: String
    let mistakeCharsToBackspace: Int
    let correctionToType: String
}

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

    func interruptibleSleep(microseconds: useconds_t) -> Bool {
        var remaining = microseconds
        while remaining > 0 {
            if isCancelled { return false }
            let step = min(remaining, 15_000)
            usleep(step); remaining -= step
        }
        return !isCancelled
    }

    func sleepSec(_ r: ClosedRange<Double>) -> Bool { interruptibleSleep(microseconds: useconds_t(Double.random(in: r) * 1_000_000)) }
    func sleepMs(_ r: ClosedRange<Int>) -> Bool { interruptibleSleep(microseconds: useconds_t(Int.random(in: r) * 1_000)) }
    func sleepUsec(_ u: useconds_t) -> Bool { interruptibleSleep(microseconds: u) }

    private func notifyProgress(_ state: PillState, callback: @escaping (PillState) -> Void) {
        DispatchQueue.main.async { callback(state) }
    }

    func sampleGaussianIKI() -> useconds_t {
        let u1 = max(1e-6, Double.random(in: 0.0...1.0)), u2 = Double.random(in: 0.0...1.0)
        let z = sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
        return useconds_t(max(150.0, min(480.0, 290.0 + z * 75.0)) * 1000.0)
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

    func postKey(code: CGKeyCode = 0, flags: CGEventFlags = [], char: Character? = nil, us: ClosedRange<Int> = 14000...25000) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return }
        down.flags = flags; up.flags = []
        if let char = char {
            var u = Array(String(char).utf16)
            down.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
            up.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
        }
        down.post(tap: .cghidEventTap); _ = interruptibleSleep(microseconds: useconds_t(Int.random(in: us)))
        up.post(tap: .cghidEventTap)
    }

    func postUnicodeChar(_ char: Character) { postKey(char: char, us: 14000...24000) }
    func postVirtualKey(code: CGKeyCode, flags: CGEventFlags = []) { postKey(code: code, flags: flags, us: 14000...25000) }

    func backspace(count: Int) {
        for _ in 0..<count {
            if isCancelled { break }
            postVirtualKey(code: 51); _ = sleepMs(80...125)
        }
    }

    func arrowKey(code: CGKeyCode, count: Int) {
        dismissAutocomplete()
        for _ in 0..<count {
            if isCancelled { break }
            postVirtualKey(code: code); _ = sleepMs(170...250)
        }
    }

    func horizontalArrow(delta: Int) {
        for _ in 0..<abs(delta) {
            if isCancelled { break }
            postVirtualKey(code: delta > 0 ? 124 : 123); _ = sleepMs(25...40)
        }
    }

    func rightArrow(count: Int) { horizontalArrow(delta: count) }
    func leftArrow(count: Int) { horizontalArrow(delta: -count) }

    func typeString(_ str: String) {
        for ch in str {
            if isCancelled { break }
            postUnicodeChar(ch); _ = sleepUsec(sampleGaussianIKI())
        }
    }

    func typeSpaces(_ count: Int) {
        for _ in 0..<count {
            if isCancelled { break }
            postUnicodeChar(" "); _ = sleepUsec(sampleGaussianIKI())
        }
    }

    func dismissAutocomplete(count: Int = 1) {
        for _ in 0..<count { postVirtualKey(code: 53); _ = sleepMs(25...40) }
    }

    private func countLeadingSpaces(_ line: String) -> Int {
        line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    private func isPythonOrFunctionContext(code: String, starterCode: String) -> Bool {
        let combined = (starterCode + "\n" + code).lowercased()
        return combined.contains("def ") || combined.contains("class solution") || combined.contains("):") ||
               combined.contains("->") || combined.contains("python") || combined.contains("self.") || combined.contains("range(")
    }

    func generateIntentionalMistake(for line: String) -> IntentionalMistake? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else { return nil }

        let containsRules: [(String, String, Int, String)] = [
            ("+ 1):", "):", 2, "+ 1):"), ("+ 1)", ")", 1, "+ 1)"), ("set()", "[]", 2, "set()")
        ]
        for (tgt, rep, bs, corr) in containsRules where line.contains(tgt) {
            return IntentionalMistake(flawedLine: line.replacingOccurrences(of: tgt, with: rep), mistakeCharsToBackspace: bs, correctionToType: corr)
        }

        let suffixRules: [(String, Int, String, Int, String)] = [
            ("[]", 2, "0", 1, "[]"), ("{}", 2, "[]", 2, "{}"), ("= 0", 1, "1", 1, "0"), ("= 1", 1, "0", 1, "1"),
            ("True", 4, "False", 5, "True"), ("False", 5, "True", 4, "False"), (")", 1, "", 0, ")")
        ]
        for (sfx, drop, add, bs, corr) in suffixRules where line.hasSuffix(sfx) {
            return IntentionalMistake(flawedLine: String(line.dropLast(drop)) + add, mistakeCharsToBackspace: bs, correctionToType: corr)
        }

        return !trimmed.hasSuffix(":") ? IntentionalMistake(flawedLine: line + " - 1", mistakeCharsToBackspace: 4, correctionToType: "") : nil
    }

    private func calculateRetroStopTarget(trimmedContent: String) -> Int {
        let chars = Array(trimmedContent)
        guard chars.count >= 3 else { return -1 }
        let dangerSet: Set<Character> = ["(", "[", "{", "\"", "'"]
        let firstDangerIdx = chars.firstIndex(where: { dangerSet.contains($0) }) ?? chars.count
        guard firstDangerIdx >= 2 else { return -1 }
        return chars[..<firstDangerIdx].firstIndex(of: " ") ?? (firstDangerIdx - 1)
    }

    private func performRetroFix(lineIdx: Int, line1Idx: Int, actualIndent: Int, charIdx: Int, mistake m: IntentionalMistake) {
        _ = sleepMs(1800...1800)
        dismissAutocomplete(count: 2)
        let jumpCount = lineIdx - line1Idx
        arrowKey(code: 126, count: jumpCount)

        let line1InitialLen = m.flawedLine.count
        let line5Col = actualIndent + (charIdx + 1)
        horizontalArrow(delta: line1InitialLen - min(line5Col, line1InitialLen))

        _ = sleepMs(350...500)
        if m.mistakeCharsToBackspace > 0 { backspace(count: m.mistakeCharsToBackspace) }
        _ = sleepMs(300...450)
        if !m.correctionToType.isEmpty { typeString(m.correctionToType) }

        _ = sleepMs(700...700)
        dismissAutocomplete(count: 2)
        arrowKey(code: 125, count: jumpCount)

        let line1FinalLen = line1InitialLen - m.mistakeCharsToBackspace + m.correctionToType.count
        horizontalArrow(delta: line5Col - min(line1FinalLen, line5Col))
        _ = sleepMs(500...500)
    }

    func typeCode(_ code: String, starterCode: String = "", onProgress: @escaping (PillState) -> Void) {
        isCancelled = false
        workQueue.async {
            self.notifyProgress(.preparing, callback: onProgress)
            if !self.sleepSec(3.5...5.0) { self.notifyProgress(.idle, callback: onProgress); return }
            self.notifyProgress(.typing, callback: onProgress)

            let isPythonOrFunc = self.isPythonOrFunctionContext(code: code, starterCode: starterCode)
            var codeLines = code.components(separatedBy: "\n")

            if isPythonOrFunc, let firstIdx = codeLines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), self.countLeadingSpaces(codeLines[firstIdx]) == 0 {
                let hasIndented = codeLines.dropFirst(firstIdx + 1).contains(where: { self.countLeadingSpaces($0) >= 4 && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                if hasIndented { codeLines[firstIdx] = "    " + codeLines[firstIdx] }
                else { for i in 0..<codeLines.count where !codeLines[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { codeLines[i] = "    " + codeLines[i] } }
            }

            let substantiveIndices = codeLines.indices.filter { codeLines[$0].trimmingCharacters(in: .whitespaces).count >= 4 }
            let hasMultiLineScript = substantiveIndices.count >= 4
            let line1Idx = hasMultiLineScript ? substantiveIndices[0] : -1
            let line2Idx = hasMultiLineScript ? substantiveIndices[1] : -1
            let retroTriggerLineIdx = hasMultiLineScript ? substantiveIndices[min(4, substantiveIndices.count - 1)] : -1

            let line1Mistake = (line1Idx >= 0) ? self.generateIntentionalMistake(for: codeLines[line1Idx]) : nil
            var charCount = 0, typoTarget = Int.random(in: 35...60), prevChar: Character? = nil
            var expectedEditorIndent = 0, hasCorrectedLine1 = false

            for (lineIdx, line) in codeLines.enumerated() {
                if self.isCancelled { break }

                if lineIdx > 0 && (lineIdx % 2 == 0 || lineIdx % 3 == 0) && Double.random(in: 0...1) < 0.25, !self.sleepSec(4.5...7.0) { break }
                if lineIdx > 0 && !self.sleepSec(0.60...1.20) { break }

                let activeLineToType = (lineIdx == line1Idx && line1Mistake != nil) ? line1Mistake!.flawedLine : line
                let actualIndent = self.countLeadingSpaces(activeLineToType)
                let trimmedContent = activeLineToType.trimmingCharacters(in: .whitespacesAndNewlines)

                if !trimmedContent.isEmpty {
                    if lineIdx == 0 {
                        self.typeSpaces((isPythonOrFunc && actualIndent == 0) ? 4 : actualIndent)
                    } else if actualIndent > expectedEditorIndent {
                        self.typeSpaces(actualIndent - expectedEditorIndent)
                    } else if actualIndent < expectedEditorIndent {
                        self.dismissAutocomplete()
                        let excess = expectedEditorIndent - actualIndent
                        for _ in 0..<(excess / 4) {
                            if self.isCancelled { break }
                            self.postVirtualKey(code: 48, flags: .maskShift); _ = self.sleepMs(35...35)
                        }
                        self.backspace(count: excess % 4)
                    }
                }

                if self.isCancelled { break }

                if lineIdx == line2Idx {
                    let futurePool = codeLines.dropFirst(line2Idx + 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 8 }
                    if let futureSnippet = futurePool.first {
                        let fragLen = min(futureSnippet.count, Int.random(in: 12...16))
                        let falseStart = String(futureSnippet.prefix(fragLen))
                        self.typeString(falseStart); _ = self.sleepMs(800...800)
                        self.backspace(count: falseStart.count); _ = self.sleepMs(350...350)
                    }
                }

                let chars = Array(trimmedContent)
                var charIdx = 0
                let partialStopTarget = (lineIdx == retroTriggerLineIdx && line1Mistake != nil) ? self.calculateRetroStopTarget(trimmedContent: trimmedContent) : -1

                while charIdx < chars.count {
                    if self.isCancelled { break }
                    let char = chars[charIdx]

                    if let p = prevChar, (p == ":" || p == "{" || p == ";"), !self.sleepSec(0.45...0.95) { break }

                    charCount += 1
                    if charCount >= typoTarget && char.isLetter {
                        charCount = 0; typoTarget = Int.random(in: 35...60)
                        self.postUnicodeChar(self.adjacentTypoKey(for: char)); _ = self.sleepUsec(self.sampleGaussianIKI())

                        var overrun = 1
                        if charIdx + 1 < chars.count && chars[charIdx + 1].isLetter {
                            overrun += 1; self.postUnicodeChar(chars[charIdx + 1]); _ = self.sleepUsec(self.sampleGaussianIKI())
                        }
                        if !self.sleepSec(0.35...0.60) { break }
                        self.backspace(count: overrun); _ = self.sleepMs(200...200)
                    }

                    self.postUnicodeChar(char)
                    prevChar = char

                    if lineIdx == retroTriggerLineIdx && !hasCorrectedLine1 && charIdx == partialStopTarget, let m = line1Mistake {
                        hasCorrectedLine1 = true
                        self.performRetroFix(lineIdx: lineIdx, line1Idx: line1Idx, actualIndent: actualIndent, charIdx: charIdx, mistake: m)
                    }

                    if " ,.()".contains(char), !self.sleepSec(0.45...0.85) { break }
                    else if "=+-:%<>".contains(char), !self.sleepSec(0.50...0.95) { break }

                    if !self.sleepUsec(self.sampleGaussianIKI()) { break }
                    charIdx += 1
                }

                if !trimmedContent.isEmpty {
                    let clean = trimmedContent.components(separatedBy: "#").first?.trimmingCharacters(in: .whitespaces) ?? trimmedContent
                    expectedEditorIndent = (clean.hasSuffix(":") || clean.hasSuffix("{")) ? (actualIndent + 4) : actualIndent
                }

                if lineIdx < codeLines.count - 1 {
                    self.dismissAutocomplete()
                    self.postVirtualKey(code: 36)
                    if !self.sleepSec(2.2...3.5) { break }
                    prevChar = "\n"
                }
            }

            self.notifyProgress(self.isCancelled ? .idle : .done, callback: onProgress)
        }
    }
}

// ============================================================================
// 6. Spatial Split-Pane OCR & Sliding Overlap Deduplicator
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
            config.width = Int(display.width); config.height = Int(display.height); config.showsCursor = false
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = false; request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            guard let results = request.results, !results.isEmpty else { return nil }

            var leftObs: [(text: String, box: CGRect)] = [], rightObs: [(text: String, box: CGRect)] = []
            for obs in results {
                guard let text = obs.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                if obs.boundingBox.midX <= 0.52 { leftObs.append((text, obs.boundingBox)) }
                else { rightObs.append((text, obs.boundingBox)) }
            }

            let sortLines = { (obs: [(text: String, box: CGRect)]) in obs.sorted { $0.box.midY > $1.box.midY }.map { $0.text } }
            return (problemText: stitchScrollBuffer(incomingLines: sortLines(leftObs)), editorText: sortLines(rightObs).joined(separator: "\n"))
        } catch {
            print("❌ OCR Error: \(error.localizedDescription)")
            return nil
        }
    }

    private func stitchScrollBuffer(incomingLines: [String]) -> String {
        guard !incomingLines.isEmpty else { return accumulatedProblemLines.joined(separator: "\n") }
        if accumulatedProblemLines.isEmpty { accumulatedProblemLines = incomingLines; return incomingLines.joined(separator: "\n") }

        let existing = Set(accumulatedProblemLines.joined(separator: " ").lowercased().components(separatedBy: .whitespacesAndNewlines))
        let incoming = Set(incomingLines.joined(separator: " ").lowercased().components(separatedBy: .whitespacesAndNewlines))
        let ratio = Double(existing.intersection(incoming).count) / Double(max(1, incoming.count))
        if ratio < 0.12 && incomingLines.count > 6 {
            print("🔄 Divergence detected: Fresh problem statement loaded. Flushing buffer.")
            accumulatedProblemLines = incomingLines; return incomingLines.joined(separator: "\n")
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
// 7. Direct REST Intelligence Engine (Multi-Model Failover Cascade)
// ============================================================================
class GeminiRESTClient {
    static let shared = GeminiRESTClient()

    private func resolveAPIKey() -> String? {
        if let envKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !envKey.isEmpty { return envKey }
        for p in ["~/.config/overlay/gemini_api_key.txt", "~/.config/overlay/api_key.txt"] {
            if let k = try? String(contentsOfFile: NSString(string: p).expandingTildeInPath, encoding: .utf8) {
                let cleaned = k.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    func requestSolution(problem: String, starterCode: String) async throws -> String {
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
        return try await executeGeminiRequest(prompt: prompt)
    }

    func requestDiagnosticAssistance(problem: String, currentCode: String, testConsoleOutput: String) async throws -> String {
        let prompt = """
        You are an expert competitive programming debugger.
        Analyze the problem, the candidate's current code, and the test failure console output.
        PROBLEM:
        \(problem)

        CURRENT CANDIDATE CODE:
        \(currentCode)

        TEST FAILURE / CONSOLE OUTPUT:
        \(testConsoleOutput)

        TASK:
        Provide:
        1. BUG DIAGNOSIS: 1-2 concise bullet points identifying the exact flaw (off-by-one, type mismatch, edge case).
        2. COMPLETE CORRECTED CODE: Pure production code snippet ready to be applied.
        3. EXPLANATION: 1 sentence on why this fix resolves the failed test case.
        4. EDGE CASES: 1-2 key edge cases to watch out for.

        OUTPUT FORMAT:
        Format cleanly with HTML/CSS dark mode styling for direct rendering in WKWebView.
        Use modern dark theme styling (background: #0d1117, cards: #161b22, border: #30363d, text: #e6edf3, accent: #38bdf8, code: #a5d6ff).
        Do NOT wrap the output in outer markdown backticks (```html ... ```). Return ONLY the HTML content.
        """
        return try await executeGeminiRequest(prompt: prompt, isRawHTML: true)
    }

    func formatDiagnosticHTML(_ raw: String) -> String {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```html") { body = String(body.dropFirst(7)) }
        else if body.hasPrefix("```") { body = String(body.dropFirst(3)) }
        if body.hasSuffix("```") { body = String(body.dropLast(3)) }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.lowercased().contains("<html") && body.lowercased().contains("</html>") { return body }

        let css = ":root{--bg:#0d1117;--card:#161b22;--border:#30363d;--text:#e6edf3;--text-muted:#8b949e;--accent:#38bdf8;--success:#34d399;--danger:#f87171;--code-bg:#1c2128}" +
            "body{background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,sans-serif;font-size:13px;line-height:1.55;margin:0;padding:16px;user-select:text;-webkit-user-select:text}" +
            "h1,h2,h3,h4{color:var(--accent);margin:14px 0 8px;font-weight:600;font-size:14px;text-transform:uppercase;letter-spacing:0.5px}" +
            ".header-badge{display:inline-block;background:rgba(56,189,248,0.15);color:var(--accent);border:1px solid rgba(56,189,248,0.4);padding:3px 8px;border-radius:6px;font-size:11px;font-weight:700;margin-bottom:12px}" +
            ".card{background:var(--card);border:1px solid var(--border);border-radius:8px;padding:12px 14px;margin-bottom:14px}" +
            "ul,ol{margin:0;padding-left:20px}li{margin-bottom:6px}" +
            "pre{background:var(--code-bg);border:1px solid var(--border);border-radius:6px;padding:12px;overflow-x:auto;font-family:'SF Mono',Menlo,monospace;font-size:12px;line-height:1.45;color:#a5d6ff;margin:8px 0}" +
            "code{font-family:'SF Mono',Menlo,monospace;font-size:12px}p{margin:6px 0}::-webkit-scrollbar{width:6px;height:6px}::-webkit-scrollbar-thumb{background:#30363d;border-radius:3px}"

        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>\(css)</style></head><body><div class=\"header-badge\">LIVE DIAGNOSTIC HUD</div>\(body)</body></html>"
    }

    private func executeGeminiRequest(prompt: String, isRawHTML: Bool = false) async throws -> String {
        guard let apiKey = resolveAPIKey() else {
            throw NSError(domain: "SpatialVision", code: 401, userInfo: [NSLocalizedDescriptionKey: "GEMINI_API_KEY missing"])
        }
        let models = ["gemini-2.5-flash", "gemini-flash-latest", "gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.5-flash", "gemini-3.6-flash"]
        var lastError: Error? = nil

        for model in models {
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.timeoutInterval = 15.0
            let body: [String: Any] = ["contents": [["parts": [["text": prompt]]]], "generationConfig": ["temperature": 0.1, "maxOutputTokens": 4096]]

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResp = response as? HTTPURLResponse else { continue }

                if httpResp.statusCode == 200 {
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let candidates = json["candidates"] as? [[String: Any]],
                          let content = candidates.first?["content"] as? [String: Any],
                          let parts = content["parts"] as? [[String: Any]],
                          let text = parts.first?["text"] as? String else {
                        throw NSError(domain: "SpatialVision", code: 502, userInfo: [NSLocalizedDescriptionKey: "Parse failure on \(model)"])
                    }
                    return isRawHTML ? text : sanitizeGeneratedCode(text)
                }
                let errBody = String(data: data, encoding: .utf8) ?? "HTTP \(httpResp.statusCode)"
                let err = NSError(domain: "SpatialVision", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: "Gemini HTTP error (\(model)): \(errBody)"])
                if httpResp.statusCode == 429 || httpResp.statusCode == 404 {
                    print("⚠️ Gemini model '\(model)' returned HTTP \(httpResp.statusCode). Failing over to next model...")
                    lastError = err
                } else { throw err }
            } catch { lastError = error }
        }
        throw lastError ?? NSError(domain: "SpatialVision", code: 500, userInfo: [NSLocalizedDescriptionKey: "All Gemini models exhausted."])
    }

    private func sanitizeGeneratedCode(_ raw: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        while let first = lines.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("```") || first.isEmpty { lines.removeFirst() }
        while let last = lines.last?.trimmingCharacters(in: .whitespaces), last.hasPrefix("```") || last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

// ============================================================================
// 8. Global Hotkeys & Application Controller
// ============================================================================
class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: PillPanel!
    var pillView: PillContentView!
    var diagnosticPanel: SpatialPanel!
    var diagnosticWebView: WKWebView!
    var lastProblemText = "", lastGeneratedCode = "", lastStarterCode = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let s = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let pillW: CGFloat = 264, pillH: CGFloat = 40
        panel = PillPanel(rect: NSRect(x: s.midX - (pillW / 2), y: s.maxY - pillH - 8, width: pillW, height: pillH))
        pillView = PillContentView(frame: NSRect(x: 0, y: 0, width: pillW, height: pillH))
        panel.contentView = pillView; panel.orderFront(nil)

        let diagW: CGFloat = 480, diagH: CGFloat = 600
        diagnosticPanel = SpatialPanel(rect: NSRect(x: s.maxX - diagW - 24, y: s.midY - (diagH / 2), width: diagW, height: diagH))
        diagnosticPanel.alphaValue = 0.0

        diagnosticWebView = WKWebView(frame: diagnosticPanel.contentView!.bounds, configuration: WKWebViewConfiguration())
        diagnosticWebView.autoresizingMask = [.width, .height]
        diagnosticWebView.setValue(false, forKey: "drawsBackground")
        diagnosticPanel.contentView?.addSubview(diagnosticWebView)
        diagnosticPanel.orderFront(nil)

        setupHotkeys()
        print("🚀 SpatialVision Online: Micro-HUD & Undetectable Diagnostic Window Ready. Hotkeys Ready.")
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
        func regHK(_ code: Int, _ id: UInt32) {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(code), opt, EventHotKeyID(signature: OSType(0x5356), id: id), GetApplicationEventTarget(), 0, &ref)
        }

        let binds: [Int] = [kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_Z, kVK_ANSI_I, kVK_ANSI_R, kVK_ANSI_X, kVK_ANSI_Q]
        for (i, code) in binds.enumerated() { regHK(code, UInt32(i + 1)) }
        let candidateSwallows = [0...9, 11...32, 34...35, 37...47, 50...50].flatMap { $0 }
        let activeSet = Set(binds)
        for c in candidateSwallows where !activeSet.contains(c) { regHK(c, 9999) }
    }

    func handleHotkey(_ id: UInt32) {
        switch id {
        case 1: triggerSolvePipeline()
        case 2: triggerDiagnosticPipeline()
        case 3: toggleOverlayVisibility()
        case 4: toggleOverlayInteractivity()
        case 5: resetAll()
        case 6: panicAbort()
        case 7: exit(0)
        default: break
        }
    }

    func handleProgressState(_ state: PillState) { pillView.applyState(state) }

    private func captureScreenOrReportError() async -> (problemText: String, editorText: String)? {
        guard let split = await SpatialOCRManager.shared.captureSplitScreen() else {
            await MainActor.run { self.pillView.applyState(.error("OCR FAILED")) }
            return nil
        }
        return split
    }

    func triggerSolvePipeline() {
        pillView.applyState(.analyzing)
        Task { [weak self] in
            guard let self = self, let split = await self.captureScreenOrReportError() else { return }
            self.lastProblemText = split.problemText; self.lastStarterCode = split.editorText
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

    func triggerDiagnosticPipeline() {
        if case .evaluating = pillView.currentState {
            print("⚠️ Diagnostic evaluation already in progress. Please wait..."); return
        }
        pillView.applyState(.evaluating)

        Task { [weak self] in
            guard let self = self, let split = await self.captureScreenOrReportError() else { return }
            self.lastStarterCode = split.editorText
            print("🔍 Diagnosing Test Console Drawer (\(split.editorText.count) chars)...")

            do {
                let diagnosticHTML = try await GeminiRESTClient.shared.requestDiagnosticAssistance(
                    problem: self.lastProblemText.isEmpty ? split.problemText : self.lastProblemText,
                    currentCode: self.lastGeneratedCode.isEmpty ? split.editorText : self.lastGeneratedCode,
                    testConsoleOutput: split.editorText
                )
                let formattedHTML = GeminiRESTClient.shared.formatDiagnosticHTML(diagnosticHTML)

                await MainActor.run {
                    self.diagnosticWebView.loadHTMLString(formattedHTML, baseURL: nil)
                    self.diagnosticPanel.alphaValue = 1.0
                    self.diagnosticPanel.orderFront(nil)
                    self.pillView.applyState(.diagnosticReady)
                    print("✨ Diagnostic Analysis Rendered to Spatial HUD.")
                }
            } catch {
                print("❌ Diagnostic Error: \(error.localizedDescription)")
                await MainActor.run { self.pillView.applyState(.error("DIAG ERROR")) }
            }
        }
    }

    func toggleOverlayVisibility() {
        let isVisible = diagnosticPanel.alphaValue > 0.05
        diagnosticPanel.alphaValue = isVisible ? 0.0 : 1.0
        if !isVisible { diagnosticPanel.orderFront(nil) }
        print("👁️ Spatial HUD Visibility: \(!isVisible ? "VISIBLE" : "HIDDEN")")
    }

    func toggleOverlayInteractivity() {
        diagnosticPanel.isInteractive.toggle()
        diagnosticPanel.ignoresMouseEvents = !diagnosticPanel.isInteractive
        if diagnosticPanel.isInteractive {
            NSApp.activate(ignoringOtherApps: true)
            diagnosticPanel.makeKeyAndOrderFront(nil)
            diagnosticPanel.contentView?.layer?.borderColor = NSColor.white.cgColor
            diagnosticPanel.contentView?.layer?.borderWidth = 2.5
        } else {
            diagnosticPanel.resignKey()
            diagnosticPanel.contentView?.layer?.borderColor = NSColor(red: 0.15, green: 0.85, blue: 0.95, alpha: 0.85).cgColor
            diagnosticPanel.contentView?.layer?.borderWidth = 2.0
        }
        print("🖱️ Spatial HUD Interactivity: \(diagnosticPanel.isInteractive ? "ENABLED (Clicks Accepted)" : "DISABLED (Pass-Through)")")
    }

    private func hideDiagnosticOverlay() {
        diagnosticPanel.alphaValue = 0.0
        diagnosticPanel.isInteractive = false
        diagnosticPanel.ignoresMouseEvents = true
        diagnosticPanel.contentView?.layer?.borderColor = NSColor(red: 0.15, green: 0.85, blue: 0.95, alpha: 0.85).cgColor
        diagnosticPanel.contentView?.layer?.borderWidth = 2.0
        pillView.applyState(.idle)
    }

    func resetAll() {
        BiometricTyper.shared.cancel()
        SpatialOCRManager.shared.reset()
        lastProblemText = ""; lastGeneratedCode = ""; lastStarterCode = ""
        hideDiagnosticOverlay()
        print("🔄 SpatialVision State, Buffers & Overlay Reset to IDLE.")
    }

    func panicAbort() {
        BiometricTyper.shared.cancel()
        hideDiagnosticOverlay()
        print("🛑 PANIC ABORT TRIGGERED: Typing halted instantly and overlay hidden.")
    }
}

// ============================================================================
// 9. Application Entry Point
// ============================================================================
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
