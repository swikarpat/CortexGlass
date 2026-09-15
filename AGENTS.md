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
 │ On-Device Neural Vision Engine       │    │ Continuous Audio & Whisper ANE Engine│
 │ • Apple Vision (VNRecognizeTextRequest)│  │ • 16kHz rolling PCM buffer (RMS VAD) │
 │ • Apple Neural Engine (ANE) / UMA    │    │ • whisper.cpp on 8 M5 Performance Cores
 │ • Overlap scroll-stitching heuristics│    │ • Turn-completion gate (0.9s pause)  │
 └──────────────────┬───────────────────┘    └──────────────────┬───────────────────┘
                    │                                           │
                    │ Contextual Screen OCR Snapshot            │ Transcribed Spoken Utterance
                    └─────────────────────┬─────────────────────┘
                                          │
                                          ▼
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │ Auto-Adaptive Cognitive Routing & Dual-Tier LLM Synthesis                       │
 │ • Algorithmic Engineering (DSA): Big-O verbal talking points + Python 3 patch   │
 │ • Distributed System Design: Monospace ASCII topology & latency/throughput SLAs │
 │ • Domain Retrospectives: Production metrics (M+ wire fraud, 50k+ TPS)        │
 └────────────────────────────────────────┬────────────────────────────────────────┘
                                          │
                                          ▼
 ┌─────────────────────────────────────────────────────────────────────────────────┐
 │ Sandboxed WebKit Neural Runtime Container                                       │
 │ • Direct binding to active contenteditable DOM nodes                            │
 │ • Anti-fingerprinting protections (strips navigator.webdriver)                  │
 │ • Carbon HIToolbox: Hardware hotkey interception & dead-key suppression matrix  │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Core Polyglot Component Map

| Component | Path | Language / Runtime | Execution Mode | Core Responsibilities |
| :--- | :--- | :--- | :--- | :--- |
| **Multimodal Ambient Engine** | `SpatialHUD.swift` | Swift 5.10+ / Cocoa / WebKit | Native Mach-O Daemon | System audio streaming, Whisper ANE speech transcription, RMS turn-completion gate, controlled OCR snapshots, and adaptive cognitive classifier. |
| **On-Device Vision Engine** | `SpatialVision.swift` | Swift 5.10+ / Vision / ScreenCaptureKit | Native Mach-O Daemon | Zero-copy Retina display buffer capture, Apple Vision neural OCR, multi-frame overlap scroll-stitching, and algorithmic code synthesis. |
| **Stealth Compositor HUD** | Embedded in `SpatialHUD.swift` | AppKit / CoreGraphics | GPU Layer | Floating headless `NSPanel` with `sharingType = .none`; transparent to Zoom, Google Meet, Teams, and browser `getDisplayMedia`. |
| **Kernel Event Interceptor** | Carbon APIs (`HIToolbox`) | C / Swift Bridge | OS Event Broker | Global hotkey interception at the kernel layer with active suppression of stray dead-key symbol leaks. |
| **Domain Telemetry Store** | `ContextVault.txt` (or embedded) | Text / Markdown | In-Memory | Grounded production metrics and domain retrospectives for technical interview recitation. |

---

## 3. Essential Hotkey Map & Operational Modes

The system suppresses stray `Option + Key` combinations at the OS level to eliminate accidental character leaks (`®`, `´`, `π`, `å`, `œ`, `≈`) into external code editors (e.g., CoderPad), while preserving native word-jumping (`Option + Left/Right`):

| Hotkey | Target Function | Behavior |
| :--- | :--- | :--- |
| **Option + O** | Manual Screen OCR Snapshot | Captures retina display buffer, executes Apple Vision OCR, and fuses text into cognitive prompt. |
| **Option + Z** | Stealth HUD Visibility Toggle | Instantly toggles the headless HUD between fully visible and 100% alpha-transparent. |
| **Option + I** | Interactive Click-Through Toggle | Toggles `ignoresMouseEvents`, allowing the user to click, scroll, or select text within the HUD. |
| **Option + R** | Silent DOM & Memory Reset | Flushes LLM context buffers, clears active DOM input areas, and resets audio turn counters. |

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

### ADR-004: Anti-Thrashing Controlled OCR Snapshots vs. Autonomous Screen Polling
* **Status**: Accepted & Implemented
* **Decision**: Disable continuous autonomous screen diffing loops. Trigger OCR exclusively on: (1) remote audio question completion (`silenceDuration >= 0.9s`), or (2) manual user hotkey (`Option + O`).
* **Engineering Rationale**: Autonomous diffing loops detect every single typed character in CoderPad, generating continuous UI thrashing, premature prompt submissions, and disruptive context refreshes while the user is actively coding.

### ADR-005: Algorithmic Anchoring Mandate
* **Status**: Accepted & Implemented
* **Decision**: Generative synthesis must anchor to and preserve the candidate's existing algorithmic strategy, data structures, and naming conventions in CoderPad.
* **Engineering Rationale**: Generic LLM responses frequently rewrite solutions using entirely different paradigms (e.g., swapping a Trie for a Hash Map mid-interview), creating cognitive disorientation for both the candidate and interviewer.

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
