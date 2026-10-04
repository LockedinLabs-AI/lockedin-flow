#if LOCKEDIN_INTERNAL_DIAGNOSTICS
    import AudioCapture
    import AppKit
    import ApplicationServices
    import FluidAudio
    import Foundation
    import InsertionEngine
    import SpeechEngine
    import SwiftUI
    import VoiceCore

    /// Headless verification modes, invoked as:
    ///   lockedin-flow --selftest-stt <audio.wav>   → transcribe a file, print transcript, exit
    ///   lockedin-flow --selftest-stt-soak <audio.wav> <runs> → reuse one model process, exit
    ///   lockedin-flow --selftest-stt-unified <audio.wav> → test the English model, exit
    ///   lockedin-flow --selftest-vad <audio.wav>   → detect speech bounds, print metadata, exit
    ///   lockedin-flow --selftest-live-capture <seconds> [voice-focus] → capture real mic, transcribe, exit
    ///   lockedin-flow --selftest-capture-preflight [runs] → repeatedly verify the focused field without recording or writing
    ///   lockedin-flow --insert-text "text" [--insert-diagnostics] [--insert-from-home] → insert into the current frontmost app, exit
    ///   lockedin-flow --render-marketing-preview <directory> → render sanitized production UI, exit
    /// These let CI scripts and developers verify STT and insertion without a microphone.
    enum SelfTest {
        static func runIfRequested() {
            let args = CommandLine.arguments

            if let index = args.firstIndex(of: "--render-marketing-preview"),
                args.count > index + 1
            {
                let outputDirectory = URL(fileURLWithPath: args[index + 1])
                Task { @MainActor in
                    do {
                        try renderMarketingPreview(directory: outputDirectory)
                        exit(0)
                    } catch {
                        print("MARKETING-PREVIEW-ERROR:\(error.localizedDescription)")
                        exit(1)
                    }
                }
                RunLoop.main.run()
            }

            if let index = args.firstIndex(of: "--selftest-stt"), args.count > index + 1 {
                let path = args[index + 1]
                // Hard-prove offline operation: FluidAudio refuses every network fetch
                // when this flag is set, so a successful transcription is offline by
                // construction (models must already be explicitly provisioned).
                ModelHub.offlineMode = true
                let semaphore = DispatchSemaphore(value: 0)
                var code: Int32 = 0
                Task {
                    do {
                        let samples = try AudioFileLoader.load16kMono(
                            url: URL(fileURLWithPath: path))
                        print("SAMPLES:\(samples.count)")
                        let stt = ParakeetSTT()
                        try await stt.prepare()
                        let text = try await stt.transcribe(samples)
                        print("TRANSCRIPT:\n\(text)")
                    } catch {
                        print("SELFTEST-ERROR:\(error.localizedDescription)")
                        code = 1
                    }
                    semaphore.signal()
                }
                semaphore.wait()
                exit(code)
            }

            if let index = args.firstIndex(of: "--selftest-stt-soak") {
                guard args.count > index + 2,
                    let runs = Int(args[index + 2]),
                    runs > 0
                else {
                    print("SELFTEST-ERROR:usage: --selftest-stt-soak <audio.wav> <positive-runs>")
                    exit(2)
                }

                let path = args[index + 1]
                ModelHub.offlineMode = true
                let semaphore = DispatchSemaphore(value: 0)
                var code: Int32 = 0
                Task {
                    do {
                        let samples = try AudioFileLoader.load16kMono(
                            url: URL(fileURLWithPath: path))
                        let stt = ParakeetSTT()
                        try await stt.prepare()

                        // One model instance and one process are deliberately reused.
                        // Measuring after each inference exposes persistent growth that
                        // fresh-process invocations cannot detect.
                        for run in 1...runs {
                            let text = try await stt.transcribe(samples)
                            let transcript =
                                text
                                .components(separatedBy: .whitespacesAndNewlines)
                                .filter { !$0.isEmpty }
                                .joined(separator: " ")
                            let rssKB = residentSetSizeKB().map(String.init) ?? "unknown"
                            print("SOAK-RUN:\(run):RSS-KB:\(rssKB):TRANSCRIPT:\(transcript)")
                        }
                    } catch {
                        print("SELFTEST-ERROR:\(error.localizedDescription)")
                        code = 1
                    }
                    semaphore.signal()
                }
                semaphore.wait()
                exit(code)
            }

            if let index = args.firstIndex(of: "--selftest-stt-unified"), args.count > index + 1 {
                let path = args[index + 1]
                let semaphore = DispatchSemaphore(value: 0)
                var code: Int32 = 0
                Task {
                    do {
                        let samples = try AudioFileLoader.load16kMono(
                            url: URL(fileURLWithPath: path))
                        print("SAMPLES:\(samples.count)")
                        let stt = ParakeetUnifiedSTT()
                        try await stt.prepare()
                        let text = try await stt.transcribe(samples)
                        print("TRANSCRIPT:\n\(text)")
                    } catch {
                        print("SELFTEST-ERROR:\(error.localizedDescription)")
                        code = 1
                    }
                    semaphore.signal()
                }
                semaphore.wait()
                exit(code)
            }

            if let index = args.firstIndex(of: "--selftest-vad"), args.count > index + 1 {
                let path = args[index + 1]
                let semaphore = DispatchSemaphore(value: 0)
                var code: Int32 = 0
                Task {
                    do {
                        let samples = try AudioFileLoader.load16kMono(
                            url: URL(fileURLWithPath: path))
                        let detector = SileroSpeechActivityDetector()
                        try await detector.prepare()
                        if let bounds = try await detector.speechBounds(in: samples) {
                            print(
                                "VAD:SPEECH start=\(bounds.lowerBound) end=\(bounds.upperBound) total=\(samples.count)"
                            )
                        } else {
                            print("VAD:NO-SPEECH total=\(samples.count)")
                        }
                    } catch {
                        print("SELFTEST-ERROR:\(error.localizedDescription)")
                        code = 1
                    }
                    semaphore.signal()
                }
                semaphore.wait()
                exit(code)
            }

            if let index = args.firstIndex(of: "--selftest-live-capture") {
                guard args.count > index + 1,
                    let seconds = Double(args[index + 1]),
                    (1...30).contains(seconds)
                else {
                    print(
                        "SELFTEST-ERROR:usage: --selftest-live-capture <1...30 seconds> [voice-focus]"
                    )
                    exit(2)
                }
                let useVoiceFocus =
                    args.count > index + 2
                    && args[index + 2] == "voice-focus"

                ModelHub.offlineMode = true
                Task { @MainActor in
                    let capture = AudioCaptureManager(
                        voiceProcessing: useVoiceFocus ? .automatic : .disabled
                    )
                    defer {
                        capture.cancel()
                    }
                    do {
                        guard await AudioCaptureManager.microphoneAuthorized() else {
                            throw AudioCaptureError.microphoneDenied
                        }
                        try capture.start()
                        let startedWithVoiceFocus = capture.isVoiceProcessingActive
                        let deadline = Date().addingTimeInterval(seconds)
                        var recoveredToStandard = false
                        while Date() < deadline {
                            try await Task.sleep(nanoseconds: 250_000_000)
                            if try capture.recoverSilentVoiceProcessingIfNeeded() {
                                recoveredToStandard = true
                            }
                        }
                        let result = capture.stopWithResult()
                        if let terminalError = result.terminalError {
                            throw terminalError
                        }
                        let samples = result.samples
                        let rms =
                            samples.isEmpty
                            ? 0
                            : sqrt(
                                samples.reduce(0) { $0 + Double($1 * $1) } / Double(samples.count))
                        print(
                            "LIVE-CAPTURE:samples=\(samples.count):rms=\(String(format: "%.6f", rms))"
                                + ":voice-focus-started=\(startedWithVoiceFocus)"
                                + ":recovered-to-standard=\(recoveredToStandard)"
                        )
                        guard !samples.isEmpty, !AudioCaptureManager.isSilentCapture(samples) else {
                            throw AudioCaptureError.engineFailed(
                                "live capture contained no microphone signal")
                        }

                        let stt = ParakeetSTT()
                        try await stt.prepare()
                        let text = try await stt.transcribe(samples)
                        guard !text.isEmpty else {
                            throw AudioCaptureError.engineFailed(
                                "live capture contained no recognized speech")
                        }
                        print("LIVE-TRANSCRIPT:\n\(text)")
                        exit(0)
                    } catch {
                        print("SELFTEST-ERROR:\(error.localizedDescription)")
                        exit(1)
                    }
                }
                // Voice-processing graph changes deliver configuration work on the
                // main run loop. Keeping it alive makes this hardware gate match
                // the production app instead of starving the recovery callback.
                RunLoop.main.run()
            }

            if let index = args.firstIndex(of: "--selftest-capture-preflight") {
                let runs: Int
                if args.count > index + 1 {
                    guard let requestedRuns = Int(args[index + 1]),
                        (1...100).contains(requestedRuns)
                    else {
                        print("SELFTEST-ERROR:usage: --selftest-capture-preflight [1...100 runs]")
                        exit(2)
                    }
                    runs = requestedRuns
                } else {
                    runs = 1
                }

                guard TextInserter.isTrusted(prompt: true) else {
                    print("PREFLIGHT-ERROR:accessibility not trusted")
                    exit(1)
                }
                guard let pid = FrontmostTracker.currentlyFrontmostPID(),
                    let targetApp = NSRunningApplication(processIdentifier: pid),
                    let bundleID = targetApp.bundleIdentifier
                else {
                    print("PREFLIGHT-ERROR:no frontmost application")
                    exit(1)
                }

                FrontmostTracker.shared.noteActivation(
                    pid: pid,
                    bundleID: bundleID,
                    appName: targetApp.localizedName,
                    isSelf: false
                )
                guard let focusLock = FrontmostTracker.shared.focusLock() else {
                    print("PREFLIGHT-ERROR:no target lock")
                    exit(1)
                }

                Task { @MainActor in
                    do {
                        let inserter = TextInserter()
                        for _ in 0..<runs {
                            _ =
                                try await inserter
                                .captureTargetRecoveringFromSameApplicationFieldDrift(focusLock)
                        }
                        print("PREFLIGHT-OK:runs=\(runs):bundle=\(bundleID)")
                        exit(0)
                    } catch {
                        print("PREFLIGHT-ERROR:\(error.localizedDescription)")
                        exit(1)
                    }
                }
                RunLoop.main.run()
            }

            if let index = args.firstIndex(of: "--insert-text"), args.count > index + 1 {
                let text = args[index + 1]
                guard TextInserter.isTrusted(prompt: true) else {
                    print("INSERT-ERROR:accessibility not trusted")
                    exit(1)
                }
                guard let pid = FrontmostTracker.currentlyFrontmostPID() else {
                    print("INSERT-ERROR:no frontmost application")
                    exit(1)
                }
                if args.contains("--insert-diagnostics") {
                    print(insertionTargetDiagnostics(pid: pid))
                }
                if args.contains("--insert-from-home") {
                    Task { @MainActor in
                        do {
                            let result = try await insertAfterHomeActivation(text, targetPID: pid)
                            print("INSERTED:\(result.method.rawValue)")
                            exit(0)
                        } catch {
                            print("INSERT-ERROR:\(error.localizedDescription)")
                            exit(1)
                        }
                    }
                    RunLoop.main.run()
                }
                let inserter = TextInserter()
                do {
                    let result = try inserter.insert(text, into: pid)
                    print("INSERTED:\(result.method.rawValue)")
                    exit(0)
                } catch {
                    print("INSERT-ERROR:\(error.localizedDescription)")
                    exit(1)
                }
            }
        }

        /// Exercises the same focus transition as clicking the normal activating
        /// Home window: freeze the production ordinary logical target, bring
        /// LockedIn Flow forward, then restore and deliver through the same async
        /// transport used by normal dictation.
        @MainActor
        private static func insertAfterHomeActivation(
            _ text: String,
            targetPID: pid_t
        ) async throws -> InsertionResult {
            guard let targetApp = NSRunningApplication(processIdentifier: targetPID),
                let bundleID = targetApp.bundleIdentifier
            else {
                throw InsertionError.noTargetApplication
            }
            FrontmostTracker.shared.noteActivation(
                pid: targetPID,
                bundleID: bundleID,
                appName: targetApp.localizedName,
                isSelf: false
            )
            guard let focusLock = FrontmostTracker.shared.focusLock() else {
                throw InsertionError.noTargetApplication
            }
            print(
                "HOME-UAT: captured target=\(focusLock.processIdentifier) "
                    + "generation=\(focusLock.activationGeneration) "
                    + "frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)"
            )

            let inserter = TextInserter()
            let target = try await inserter.prepareTargetForOrdinaryCapture(
                focusLock
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.title = "LockedIn Flow Home insertion UAT"
            window.contentView = NSHostingView(
                rootView: Text("Returning verified text to the original field…")
                    .padding(24)
            )
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            let ownPID = ProcessInfo.processInfo.processIdentifier
            for attempt in 0..<20 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID {
                    print(
                        "HOME-UAT: own-frontmost attempt=\(attempt) "
                            + "generation=\(FrontmostTracker.shared.currentActivationGeneration())"
                    )
                    break
                }
                guard attempt < 19 else {
                    window.close()
                    throw InsertionError.focusChanged
                }
                try await Task.sleep(nanoseconds: 25_000_000)
            }

            defer { window.close() }
            let restoredTarget: CapturedInsertionTarget
            do {
                restoredTarget = try await inserter.restoreFocusForOrdinaryDictation(
                    to: target
                )
            } catch {
                print(
                    "HOME-UAT: restore-failed frontmost="
                        + "\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1) "
                        + "generation=\(FrontmostTracker.shared.currentActivationGeneration()) "
                        + "expected-generation=\(focusLock.activationGeneration)"
                )
                throw error
            }
            print(
                "HOME-UAT: restored frontmost="
                    + "\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1) "
                    + "generation=\(FrontmostTracker.shared.currentActivationGeneration())"
            )
            return try await inserter.insertOrdinary(text, into: restoredTarget)
        }

        /// Emits only target identity and Accessibility status codes. It never reads
        /// or prints field values, selected text, clipboard contents, or transcript
        /// text, and the entire diagnostic surface is absent from release builds.
        private static func insertionTargetDiagnostics(pid: pid_t) -> String {
            let target = NSRunningApplication(processIdentifier: pid)
            let bundleID = target?.bundleIdentifier ?? "unavailable"
            let frontmostBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1

            let application = AXUIElementCreateApplication(pid)
            var applicationFocusedElement: CFTypeRef?
            let applicationFocusStatus = AXUIElementCopyAttributeValue(
                application,
                kAXFocusedUIElementAttribute as CFString,
                &applicationFocusedElement
            )

            let system = AXUIElementCreateSystemWide()
            var systemFocusedApplication: CFTypeRef?
            let systemApplicationStatus = AXUIElementCopyAttributeValue(
                system,
                kAXFocusedApplicationAttribute as CFString,
                &systemFocusedApplication
            )
            var systemFocusStatus = AXError.attributeUnsupported
            if systemApplicationStatus == .success,
                let systemFocusedApplication,
                CFGetTypeID(systemFocusedApplication) == AXUIElementGetTypeID()
            {
                var systemFocusedElement: CFTypeRef?
                systemFocusStatus = AXUIElementCopyAttributeValue(
                    systemFocusedApplication as! AXUIElement,  // swiftlint:disable:this force_cast
                    kAXFocusedUIElementAttribute as CFString,
                    &systemFocusedElement
                )
            }

            let frontmostAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
            return [
                "INSERT-DIAGNOSTICS:",
                "target-pid=\(pid)",
                "bundle=\(bundleID)",
                "frontmost-before=\(frontmostBefore)",
                "frontmost-after=\(frontmostAfter)",
                "application-focus-status=\(applicationFocusStatus.rawValue)",
                "system-application-status=\(systemApplicationStatus.rawValue)",
                "system-focus-status=\(systemFocusStatus.rawValue)",
            ].joined(separator: " ")
        }

        /// Renders the shipping Home and recorder views with deterministic sample
        /// content. No user history, preferences, recordings, or credentials are
        /// read into the output.
        @MainActor
        private static func renderMarketingPreview(directory: URL) throws {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let iconURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("branding/raster/icon-1024.png")
            if let icon = NSImage(contentsOf: iconURL) {
                NSApplication.shared.applicationIconImage = icon
            }

            let state = AppState(marketingPreview: true)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let referenceDate =
                calendar.date(
                    from: DateComponents(
                        year: 2026,
                        month: 8,
                        day: 8,
                        hour: 19,
                        minute: 46
                    )
                ) ?? Date(timeIntervalSince1970: 1_786_230_360)
            state.historyEntries = [
                HistoryEntry(
                    createdAt: referenceDate.addingTimeInterval(-8 * 60),
                    raw: "Um, we should ship the update today, ah, and send a note to the team.",
                    final: "We should ship the update today and send a note to the team.",
                    duration: 7.8,
                    profileID: "General",
                    targetAppName: "Notes",
                    modelID: "parakeet-multilingual"
                ),
                HistoryEntry(
                    createdAt: referenceDate.addingTimeInterval(-42 * 60),
                    raw: "Please review the launch checklist before our three PM meeting.",
                    final: "Please review the launch checklist before our 3:00 PM meeting.",
                    duration: 5.6,
                    profileID: "Email",
                    targetAppName: "Mail",
                    modelID: "parakeet-multilingual"
                ),
                HistoryEntry(
                    createdAt: referenceDate.addingTimeInterval(-2 * 3_600),
                    raw: "Um, locked in flow processes every dictation, ah, privately on this Mac.",
                    final: "LockedIn Flow processes every dictation privately on this Mac.",
                    duration: 4.9,
                    profileID: "General",
                    targetAppName: "TextEdit",
                    modelID: "parakeet-multilingual"
                ),
            ]
            state.statsWordsTotal = 16_482
            state.statsDictationsTotal = 421
            state.statsAverageWPM = 144
            state.targetAppName = "Notes"

            let home = HomeView()
                .environmentObject(state)
                .frame(width: 620, height: 680)
            try writePNG(
                from: home,
                scale: 2,
                to: directory.appendingPathComponent("lockedin-home.png")
            )
            try writePNG(
                from: home,
                scale: 760.0 / 620.0,
                to: directory.appendingPathComponent("lockedin-home-760.png")
            )

            state.pipelineState = .failed
            state.errorMessage = "No speech was recognized on the last local pass."
            state.updateFailedDictationRetryAvailability(true)
            let retryHome = HomeView()
                .environmentObject(state)
                .frame(width: 620, height: 680)
            try writePNG(
                from: retryHome,
                scale: 2,
                to: directory.appendingPathComponent("lockedin-home-retry.png")
            )

            state.updateFailedDictationRetryAvailability(false)
            state.modelReady = false
            state.modelStatus = "Provisioned model unavailable"
            state.errorMessage = "The reviewed on-device speech model is not provisioned."
            state.pipelineState = .failed
            let unavailableHome = HomeView()
                .environmentObject(state)
                .frame(width: 620, height: 680)
            try writePNG(
                from: unavailableHome,
                scale: 2,
                to: directory.appendingPathComponent("lockedin-home-model-unavailable.png")
            )

            for size in [CGSize(width: 600, height: 660), CGSize(width: 520, height: 480)] {
                try writeHostedPNG(
                    from: ModelSetupView()
                        .environmentObject(state)
                        .frame(width: size.width, height: size.height)
                        .preferredColorScheme(.light),
                    size: size,
                    appearance: .aqua,
                    to: directory.appendingPathComponent(
                        "lockedin-model-setup-\(Int(size.width)).png")
                )
            }
            try writeHostedPNG(
                from: ModelSetupView(installation: .managedMac)
                    .environmentObject(state)
                    .frame(width: 600, height: 660)
                    .preferredColorScheme(.dark),
                size: CGSize(width: 600, height: 660),
                appearance: .darkAqua,
                to: directory.appendingPathComponent("lockedin-model-setup-managed.png")
            )
            try writeHostedPNG(
                from: OnboardingView(initialPage: 2)
                    .environmentObject(state)
                    .frame(width: 560, height: 500),
                size: CGSize(width: 560, height: 500),
                appearance: .aqua,
                to: directory.appendingPathComponent("lockedin-onboarding-model-setup.png")
            )
            state.modelReady = true
            state.microphoneAuthorized = false
            state.accessibilityTrusted = false
            state.errorMessage = nil
            state.modelStatus = "Ready"
            try writeHostedPNG(
                from: OnboardingView(initialPage: 2)
                    .environmentObject(state)
                    .frame(width: 560, height: 500),
                size: CGSize(width: 560, height: 500),
                appearance: .aqua,
                to: directory.appendingPathComponent("lockedin-onboarding-permissions-needed.png")
            )
            state.modelReady = false
            state.microphoneAuthorized = true
            state.accessibilityTrusted = true

            state.errorMessage = nil
            state.modelStatus = "Verifying provisioned speech model…"
            state.pipelineState = .preparing
            let preparingMenu = MenuBarView()
                .environmentObject(state)
                .frame(width: 332)
                .fixedSize(horizontal: false, vertical: true)
            try writePNG(
                from: preparingMenu,
                scale: 2,
                to: directory.appendingPathComponent("lockedin-menu-preparing.png")
            )

            let preparingOverlay = FloatingBarView()
                .environmentObject(state)
                .frame(width: 134, height: 42)
            try writePNG(
                from: preparingOverlay,
                scale: 2,
                to: directory.appendingPathComponent("lockedin-overlay-preparing.png")
            )

            state.modelReady = true
            state.modelStatus = "Ready"
            state.pipelineState = .recording
            state.level = 0.72
            state.recordingStartedAt = referenceDate.addingTimeInterval(-11)
            let recorder = FloatingBarView()
                .environmentObject(state)
                .frame(width: 300, height: 68)
            try writePNG(
                from: recorder,
                scale: 2,
                to: directory.appendingPathComponent("lockedin-recorder.png")
            )

            print("MARKETING-PREVIEW:\(directory.path)")
        }

        @MainActor
        private static func writePNG<Content: View>(
            from content: Content,
            scale: CGFloat,
            to url: URL
        ) throws {
            let renderer = ImageRenderer(content: content)
            renderer.scale = scale
            // Render standard 8-bit sRGB website assets, not oversized 16-bit TIFF
            // intermediates. This still captures the production SwiftUI view.
            guard let image = renderer.cgImage,
                let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else {
                throw NSError(
                    domain: "LockedInFlow.MarketingPreview",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not render a PNG image."]
                )
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let output = context.makeImage(),
                let data = NSBitmapImageRep(cgImage: output).representation(
                    using: .png, properties: [:])
            else {
                throw NSError(domain: "LockedInFlow.MarketingPreview", code: 2)
            }
            try data.write(to: url, options: .atomic)
        }

        /// AppKit-backed controls such as SecureField need a hosted view hierarchy
        /// to render their native cells. This captures that exact hierarchy rather
        /// than replacing the credential field with a screenshot-only facsimile.
        @MainActor
        private static func writeHostedPNG<Content: View>(
            from content: Content,
            size: CGSize,
            appearance: NSAppearance.Name? = nil,
            to url: URL
        ) throws {
            let hostingView = NSHostingView(rootView: content)
            if let appearance { hostingView.appearance = NSAppearance(named: appearance) }
            hostingView.frame = CGRect(origin: .zero, size: size)
            hostingView.layoutSubtreeIfNeeded()
            hostingView.displayIfNeeded()

            guard
                let bitmap = hostingView.bitmapImageRepForCachingDisplay(
                    in: hostingView.bounds
                )
            else {
                throw NSError(
                    domain: "LockedInFlow.MarketingPreview",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Could not render a hosted PNG image."]
                )
            }
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(
                    domain: "LockedInFlow.MarketingPreview",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Could not encode a hosted PNG image."]
                )
            }
            try data.write(to: url, options: .atomic)
        }

        /// Returns the current resident set of this long-lived test process. Using
        /// `ps` keeps this diagnostic independent from private Mach APIs and mirrors
        /// the value operators see in Activity Monitor.
        private static func residentSetSizeKB() -> Int? {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = [
                "-o", "rss=", "-p",
                String(ProcessInfo.processInfo.processIdentifier),
            ]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let value = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return Int(value)
            } catch {
                return nil
            }
        }
    }
#endif
