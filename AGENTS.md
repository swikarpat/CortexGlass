# CortexGlass Master Blueprint & Agent Memory Store

> **CRITICAL DIRECTIVE FOR ALL AI AGENTS**:
> This document is the **single source of truth** and **persistent memory** for the CortexGlass codebase.
> Whenever you (the AI assistant) introduce new capabilities, refactor Swift engines, modify Carbon hotkeys, or update cognitive prompt routing, **you are strictly required to update this file in the same turn**.
> Before responding to architectural inquiries, cross-verify this document against the physical workspace (`SpatialHUD.swift`, `SpatialVision.swift`, `readme.md`) to ensure zero hallucinations.

---

## 1. System Design & Architecture Overview

CortexGlass is an ultra-low-latency, privacy-hardened **macOS Background Daemon and Headless Heads-Up Display (HUD)** engineered for seamless on-device computer vision, hardware-compositor window virtualization, and contextual multimodal Large Language Model (LLM) inference.

It establishes an air-gapped bridge between low-level macOS system frameworks (`ScreenCaptureKit`, `Carbon HIToolbox`, `Quartz WindowServer`) and on-device Apple Neural Engine (ANE) machine learning pipelines. The system captures, transcribes, and synthesizes live technical telemetry without triggering DOM focus violations, browser events, or window-capture hooks.

### High-Level System Topology

```
  ┌────────────────────────────────────────────────────────────────────────┐
  │   Display Server / Hardware Window Compositor (macOS Quartz)          │
  │   • NSPanel: sharingType = .none (Completely invisible to WebRTC/Zoom) │
  │   • nonactivatingPanel + ignoresMouseEvents = true (Zero DOM blur)    │
  └───────────────────┬────────────────────────────────┬───────────────────┘
                      │                                │
      ScreenCaptureKit│ (60fps GPU Framebuffer)        │ ScreenCaptureKit (System Audio Tap)
                      ▼                                ▼
 ┌──────────────────────────────────────┐    ┌──────────────────────────────────────┐
 │ On-Device Neural Vision Engine       │    │ Deterministic Session Audio Engine   │
 │ • Apple Vision (VNRecognizeTextRequest)│  │ • 5s rolling pre-roll buffer (80k)   │
 │ • Apple Neural Engine (ANE) / UMA    │    │ • Manual Start (Opt+S) / Stop (Opt+CR)│
 │ • Overlap scroll-stitching heuristics│    │ • whisper.cpp on 8 M5 Perf Cores     │
 └──────────────────┬───────────────────┘    └──────────────────┬───────────────────┘
                    │                                           │
                    │ Contextual Screen OCR Snapshot            │ Transcribed Spoken Utterance
                    └─────────────────────┬─────────────────────┘
                                          │
                                          ▼
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │ Auto-Adaptive Cognitive Routing & Dual-Tier LLM Synthesis                       │
 │ • Multi-turn amendment framing (solveCount > 0): targeted patches without rewrite│
 │ • Algorithmic Engineering (DSA): Big-O verbal talking points + Python 3 patch   │
 │ • Distributed System Design: Monospace ASCII topology & latency/throughput SLAs │
 │ • Domain Retrospectives: Production metrics (M+ wire fraud, 50k+ TPS)        │
 └────────────────────────────────────────┬────────────────────────────────────────┘
                                          │
                                          ▼
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │ Sandboxed WebKit Neural Runtime Container                                       │
 │ • Direct binding to active contenteditable DOM nodes                            │
 │ • Auto-invalidation of active generation via button[aria-label*="Stop"] on Opt+S│
 │ • Anti-fingerprinting protections (strips navigator.webdriver)                  │
 │ • Carbon HIToolbox: Hardware hotkey interception & dead-key suppression matrix  │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Core Polyglot Component Map

| Component | Path | Language / Runtime | Execution Mode | Core Responsibilities |
| :--- | :--- | :--- | :--- | :--- |
| **Multimodal Ambient Engine** | `SpatialHUD.swift` | Swift 5.10+ / Cocoa / WebKit | Native Mach-O Daemon | System audio streaming, 5s rolling pre-roll buffer, manual session capture state machine (Opt+S start, Opt+Return stop & solve), DOM generation invalidation, Whisper ANE transcription, controlled OCR snapshots, selective ContextVault injection (ultra-lean ~200 token prompt in Coding, vault isolated to Behavioral/Past Project), multi-turn amendment framing (`solveCount`), explicit numeric hotkey mode routing (Opt+1..4), and clean quit (Opt+O). |
| **On-Device Vision Engine & Diagnostic HUD** | `SpatialVision.swift` | Swift 5.10+ / Vision / ScreenCaptureKit / AppKit | Native Mach-O Daemon | Unified full-desktop OCR (top-to-bottom candidate sorting, scroll stitching), zero-focus remote HUD navigation (JS-injected scrolling, in-place scaling, opacity adjustment), opt-in mouse interactivity (`Option + I`), 13-key Carbon suppression matrix, BiometricTyper human simulation, and Gemini REST diagnostic failover. |
| **Stealth Compositor HUD** | Embedded in `SpatialHUD.swift` & `SpatialVision.swift` | AppKit / CoreGraphics | GPU Layer | Floating headless `NSPanel` with `sharingType = .none`; transparent to Zoom, Google Meet, Teams, and browser `getDisplayMedia`. |
| **Kernel Event Interceptor** | Carbon APIs (`HIToolbox`) | C / Swift Bridge | OS Event Broker | Global hotkey interception at the kernel layer with active suppression of stray dead-key symbol leaks while preserving native cursor word jumping. |
| **Domain Telemetry Store** | `ContextVault.txt` (or embedded) | Text / Markdown | In-Memory | Grounded production metrics and domain retrospectives for technical interview recitation. |

---

## 3. Essential Hotkey Maps & Operational Modes

The system suppresses stray `Option + Key` combinations at the OS level to eliminate accidental character leaks (`®`, `´`, `π`, `å`, `œ`, `≈`) into external code editors (e.g., CoderPad), while preserving native cursor jumping (`Option + Left/Right Arrow`):

### SpatialHUD Ambient Daemon Hotkeys

| Hotkey | Target Function | Behavior |
| :--- | :--- | :--- |
| **Option + S** | Start Session Recording | Engages manual audio sample accumulation and caches baseline screen OCR. HUD border turns Vivid Amber/Red. |
| **Option + Return** | Stop Session & Solve | Halts accumulation, runs background Whisper ANE transcription and final screen OCR in parallel, submits prompt to Gemini. Single-shot direct OCR if not recording. |
| **Option + 1** | Switch to Coding / DSA | Locks mode to **Data Structures & Algorithms** [Strict Default]. Electric Cyan border. |
| **Option + 2** | Switch to System Design | Locks mode to **System Design (ASCII & Scaled Architecture)**. Neon Violet border. |
| **Option + 3** | Switch to Behavioral | Locks mode to **Leadership & Behavioral (STAR Method)**. Rose Red border. |
| **Option + 4** | Switch to Past Project | Locks mode to **Past Project Retrospective & System Architecture**. Amber Gold border. |
| **Option + O** | Clean Quit Application | Cleanly stops capture, unlocks `/tmp/com.swikar.spatialhud.lock`, and terminates (`exit(0)`). |
| **Option + Z** | Stealth HUD Visibility Toggle | Instantly toggles the headless HUD between fully visible and 100% alpha-transparent. |
| **Option + I** | Interactive Click-Through Toggle | Toggles `ignoresMouseEvents`, allowing the user to click, scroll, or select text within the HUD. |
| **Option + R** | Silent DOM & Memory Reset | Flushes LLM context buffers, clears active DOM input areas, and purges audio/screen session buffers. |

### SpatialVision Diagnostic HUD & Autonomous Typer Hotkeys

| Hotkey | Purpose | Focus Impact on Browser | Behavior |
| :--- | :--- | :--- | :--- |
| **`Option + S`** | Solve & Autonomously Type | **Zero** | Unified full-desktop OCR -> Gemini REST code generation -> Human BiometricTyper HID typing. |
| **`Option + T`** | Full-Screen OCR & Diagnose Drawer | **Zero** | Captures full desktop -> Diagnoses test failures/console output -> Renders dark-mode HTML in HUD. |
| **`Option + Z`** | Stealth Visibility Toggle | **Zero** | In-place visual toggle (`0.0` $\leftrightarrow$ `currentOpacity`); never steals focus. |
| **`Option + -`** | Decrease Opacity (-0.10) | **Zero** | Lowers HUD window opacity in-place down to minimum 20% stealth threshold. |
| **`Option + =`** | Increase Opacity (+0.10) | **Zero** | Increases HUD window opacity in-place up to 100% maximum. |
| **`Option + [`** | Shrink Diagnostic HUD (0.90x) | **Zero** | In-place scale down anchored to top/right margins (min 340x380px) via `setFrame`. |
| **`Option + ]`** | Expand Diagnostic HUD (1.10x) | **Zero** | In-place scale up anchored to top/right margins (max 75% W, 92% H) via `setFrame`. |
| **`Option + Down`** | Remote Scroll Down (+350px) | **Zero** | Injects `window.scrollBy({top: 350, behavior: 'smooth'})` directly into `WKWebView`. |
| **`Option + Up`** | Remote Scroll Up (-350px) | **Zero** | Injects `window.scrollBy({top: -350, behavior: 'smooth'})` directly into `WKWebView`. |
| **`Option + I`** | Toggle Mouse Interactivity | **Focus Shifted** | Opt-in click-through toggle. Activates panel and sets white border when enabled. |
| **`Option + R`** | Reset Session & Buffers | **Zero** | Cancels BiometricTyper, flushes OCR scroll buffer, clears problem state, resets HUD to IDLE. |
| **`Option + X`** | Panic Abort (<15ms) | **Zero** | Immediately halts BiometricTyper typing loop and hides diagnostic overlay. |
| **`Option + Q`** | Clean Quit | **Zero** | Cancels typer, hides overlay, unlocks `/tmp/com.swikar.spatialvision.lock`, and terminates (`exit(0)`). |

---

## 4. Architectural Decision Records (ADRs)

### ADR-001: Compositor-Level Hardware Stealth (sharingType = .none) vs. Software Window Masking
* **Status**: Accepted & Implemented
* **Decision**: Configure the HUD panel with Cocoa `NSWindow.sharingType = .none` and `NSWindow.CollectionBehavior.transient`.
* **Engineering Rationale**: Software overlay techniques that hide or minimize windows are detectable via OS window lists or screen-sharing APIs. Setting `sharingType = .none` instructs the macOS Quartz WindowServer to exclude the window's backing surface from all screen capture APIs entirely. The HUD remains completely invisible to WebRTC browser streams (`navigator.mediaDevices.getDisplayMedia`), Zoom, Teams, and native recorders.

### ADR-002: Carbon Low-Level Hotkeys (HIToolbox) vs. Cocoa Event Monitors
* **Status**: Accepted & Implemented
* **Decision**: Register global hotkeys using Carbon `RegisterEventHotKey` with an active suppression matrix.
* **Engineering Rationale**: Standard Cocoa `NSEvent.addGlobalMonitorForEvents` does not intercept or consume keys—it only observes them after they propagate, allowing unwanted dead-key symbols (`®`, `π`) to leak into active text editors. Carbon hotkeys intercept events at the system event-broker layer before frontmost applications see them, enabling total dead-key swallowing.

### ADR-003: On-Device Apple Neural Engine (ANE) OCR & Whisper vs. Cloud Multimodal APIs
* **Status**: Accepted & Implemented
* **Decision**: Execute all speech-to-text (Whisper `ggml-base.en`) and screen OCR (Apple `Vision`) locally on the Apple Silicon Neural Engine (ANE).
* **Engineering Rationale**: Streaming high-resolution screen frames and continuous audio to cloud endpoints introduces 1.5–4.0s of network latency, risks packet drops, and leaks confidential code. Local ANE execution transcribes speech in < 200 ms and parses screen syntax in < 100 ms with zero internet dependency.

### ADR-004: Anti-Thrashing Controlled OCR Snapshots & Deterministic Manual Session Capture vs. Autonomous VAD
* **Status**: Accepted & Implemented
* **Decision**: Eliminate automatic 0.9s VAD silence triggers and continuous 18s speech sliding buffers. Introduce deterministic manual Session Capture Engine: Start Recording (`Option + S`) -> Stop & Solve (`Option + Return`), with direct single-shot screen OCR fallback when not recording.
* **Engineering Rationale**: Continuous autonomous diffing loops and aggressive 0.9s VAD turn triggers caused premature prompt submissions during natural interview conversational pauses and typing. Explicit start/stop controls ensure that complete multi-minute problem formulations are captured and solved in one shot, with simultaneous Whisper CLI transcription and Apple Vision OCR execution.

### ADR-005: Algorithmic Anchoring Mandate
* **Status**: Accepted & Implemented
* **Decision**: Generative synthesis must anchor to and preserve the candidate's existing algorithmic strategy, data structures, and naming conventions in CoderPad.
* **Engineering Rationale**: Generic LLM responses frequently rewrite solutions using entirely different paradigms (e.g., swapping a Trie for a Hash Map mid-interview), creating cognitive disorientation for both the candidate and interviewer.

### ADR-006: Explicit Numeric Hotkey-Driven Interview Mode Switching vs. Autonomous Cognitive Auto-Switching
* **Status**: Accepted & Implemented
* **Decision**: Initialize `currentMode = .coding` strictly by default. Disable runtime automatic mode reassignment inside `classifyContext()`. Mode switching is exclusively driven by explicit numeric hotkeys (`Option + 1`, `Option + 2`, `Option + 3`, `Option + 4`).
* **Engineering Rationale**: Spoken interview dialogue frequently introduces references to distributed systems or past projects during coding challenges (or vice versa). Automated classifier re-routing causes abrupt format mutations and border color flashing mid-round. Locking Coding by default and requiring explicit numeric hotkeys guarantees deterministic prompt synthesis tailored to the active interview format.

### ADR-007: 5-Second Rolling Audio Pre-Roll Buffer & Multi-Turn Context-Aware Synthesis
* **Status**: Accepted & Implemented
* **Decision**: Maintain a continuous 5-second rolling circular buffer (`preRollBuffer`, 80,000 floats at 16kHz) during idle listening. When recording is triggered (`Option + S`), prepend `preRollBuffer` into `audioSamples` to capture opening question words, and invalidate any running Gemini DOM generation (`button[aria-label*="Stop"]`). Track session round iterations (`solveCount`); when `solveCount > 0`, frame synthesis specifically for multi-turn follow-up amendments (patching code, answering trade-offs without rewriting unchanged solutions).
* **Engineering Rationale**: Interviewers often begin speaking several seconds before a candidate engages recording; prepending 5 seconds of pre-roll ensures zero truncated opening words. Furthermore, technical rounds frequently involve iterative amendments rather than net-new problems; explicit multi-turn follow-up prompting prevents the LLM from redundantly rewriting full boilerplate code, producing concise patches instead.

### ADR-008: Unified Full-Desktop OCR & Zero-Focus Remote HUD Navigation
* **Status**: Accepted & Implemented
* **Decision**: Eliminate split-pane coordinate bounding heuristics (`midX <= 0.52`). Ingest the complete Retina desktop display, sort all OCR text observations strictly top-to-bottom by bounding box coordinate (`$0.box.midY > $1.box.midY`), and deduplicate via continuous scroll-stitching. Implement zero-focus remote window controls: in-place scaling (`Option + [` / `]`), in-place opacity adjustment (`Option + -` / `=`), and non-activating remote JavaScript scrolling (`Option + Down` / `Up`). Retain manual mouse interactivity (`Option + I`) as an explicit opt-in state, preserving `ignoresMouseEvents = true` by default.
* **Engineering Rationale**: Arbitrary horizontal screen-splitting breaks when candidates resize browser splitters, use non-50/50 layouts, or open bottom/side test console drawers. Full-desktop top-to-bottom OCR provides complete problem and editor telemetry regardless of layout. Browser proctoring engines (HackerRank, CoderPad) listen for `window.onblur` to flag candidates; non-activating remote JS scrolling and AppKit `setFrame` (without `makeKeyAndOrderFront`) ensure zero focus theft while maintaining complete candidate control over HUD visibility and diagnostics.

### ADR-009: Selective Context Injection & Ultra-Lean Coding Prompt Synthesis
* **Status**: Accepted & Implemented
* **Decision**: Decouple and exclude `ContextVault.md` during Coding rounds (`currentMode == .coding`), reserving ground-truth vault injection strictly for Behavioral (`.behavioral`) and Past Project Retrospectives (`.projectDeepDive`). In `.coding` mode, completely strip `baseInstructions` and `ContextVault.md`, deploying an ultra-lean prompt (~200 tokens vs ~4,500 tokens) with a dedicated lean follow-up template when `solveCount > 0`.
* **Engineering Rationale**: Unconditionally injecting career telemetry, enterprise microservice architecture history (Kafka, RocksDB, Neo4j, fraud systems), and verbose architectural instructions into coding challenges caused massive prompt bloat (~4,500 tokens), sub-second latency degradation, and context-bleed hallucinations where the LLM generated distributed systems commentary instead of clean Python algorithms. Stripping the vault drops latency significantly, enabling Gemini to stream solutions in under a second with laser focus on the CoderPad buffer.

---

## 5. Build & Compilation Commands

* **Compile Multimodal Ambient Engine**:
  `swiftc -O SpatialHUD.swift -o SpatialHUD`
* **Compile On-Device Neural Vision Engine**:
  `swiftc -O SpatialVision.swift -o SpatialVision`
* **Launch SpatialHUD Daemon**:
  `./SpatialHUD`
* **Launch SpatialVision Daemon**:
  `./SpatialVision`
