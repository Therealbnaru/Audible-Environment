import AVFoundation
import CoreMedia
import MWDATCamera
import MWDATCore
import Photos
import Security
import SwiftUI
import UIKit

@main
struct MyApp: App {
    @State private var sdkReady = false
    @State private var registration: RegistrationState?
    @State private var selector: AutoDeviceSelector?
    @State private var glassesReady = false
    @State private var connecting = false
    @State private var errorMessage: String?

    @State private var session: DeviceSession?
    @State private var sessionState: DeviceSessionState = .idle
    @State private var sessionID: UUID?

    @State private var camera: Camera?
    @State private var streamState: StreamState = .stopped
    @State private var streamID: UUID?
    @State private var streamListeners = ListenerTokenBag()
    @State private var startingStream = false
    @State private var frameCount = 0

    @State private var photosAllowed = false
    @State private var photosSaved = 0
    @State private var nextSnapshotAt: TimeInterval?

    @State private var geminiAPIKey = MyApp.defaultGeminiKey()
    @State private var speechSynthesizer = AVSpeechSynthesizer()
    @State private var pendingCapture: UUID?
    @State private var narrationRun: UUID?
    @State private var narrationSettlesAt: TimeInterval = 0
    @State private var narrationFrames: [NarrationFrame] = []
    @State private var previousNarrationFrame: NarrationFrame?
    @State private var nextNarrationFrameAt: TimeInterval = 0
    @State private var recentAnnouncements: [String] = []
    @State private var frameDescription: String?
    @State private var descriptionError: String?
    @State private var isDescribing = false
    @State private var geminiRetryAt: TimeInterval = 0
    @State private var nextNarrationRequestAt: TimeInterval = 0
    @State private var narrationStatus = "Collecting frames…"
    @State private var geminiBackoff: TimeInterval = 60

    private let snapshotInterval: TimeInterval = 10

    init() {
        do {
            try Wearables.configure()
            _sdkReady = State(initialValue: true)
        } catch {
            _errorMessage = State(initialValue: "Meta SDK setup failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Form {
                    Section("Status") {
                        if let registration {
                            Text("Registration: \(registration)")
                        }
                        Text(glassesReady ? "Glasses ready" : "Waiting for glasses")
                        Text("Session: \(sessionState)")
                        Text("Stream: \(streamState)")
                        Text("Frames received: \(frameCount)")
                        Text("Photos saved: \(photosSaved)")

                        if let errorMessage {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                        }
                    }

                    Section("Describe a frame") {
                        Toggle("Automatic Narration", isOn: Binding(
                            get: { narrationRun != nil },
                            set: { enabled in
                                narrationRun = enabled ? UUID() : nil
                                narrationFrames.removeAll()
                                narrationSettlesAt = 0
                                previousNarrationFrame = nil
                                recentAnnouncements.removeAll()
                                nextNarrationFrameAt = 0
                                narrationStatus = "Collecting frames…"
                                if !enabled {
                                    speechSynthesizer.stopSpeaking(at: .immediate)
                                }
                            }
                        ))
                        if narrationRun != nil && streamState != .streaming {
                            Text("Start the glasses stream to begin narration.")
                        } else if narrationRun != nil {
                            Text(narrationStatus)
                        }
                        SecureField("Gemini API key", text: $geminiAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            requestDescription()
                        } label: {
                            Text("Describe Now")
                                .frame(maxWidth: .infinity, minHeight: 64)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(streamState != .streaming || pendingCapture != nil || isDescribing)

                        Button {
                            if let frameDescription {
                                speakDescription(frameDescription)
                            }
                        } label: {
                            Text("Repeat Last Description")
                                .frame(maxWidth: .infinity, minHeight: 64)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(frameDescription == nil || isDescribing)

                        if pendingCapture != nil || isDescribing {
                            ProgressView("Describing frame")
                        }
                        if let frameDescription {
                            Text(frameDescription)
                            Button("Stop Speaking") {
                                speechSynthesizer.stopSpeaking(at: .immediate)
                            }
                        }
                        if let descriptionError {
                            Text(descriptionError)
                                .foregroundStyle(.red)
                        }
                    }

                    Section("Glasses") {
                        Button("Connect") {
                            Task { await connect() }
                        }
                        .disabled(
                            !sdkReady || connecting ||
                            registration == .registered || registration == .registering
                        )

                        Button("Start Session") {
                            startSession()
                        }
                        .disabled(!glassesReady || registration != .registered || session != nil)

                        Button("Start Stream") {
                            Task { await startStream() }
                        }
                        .disabled(sessionState != .started || startingStream || camera != nil)

                        Button("Stop Stream") {
                            nextSnapshotAt = nil
                            streamState = .stopping
                            camera?.stop()
                        }
                        .disabled(camera == nil || streamState == .stopping || sessionState == .stopping)

                        Button("End Session") {
                            nextSnapshotAt = nil
                            sessionState = .stopping
                            session?.stop()
                        }
                        .disabled(session == nil || sessionState == .stopping)
                    }
                }
                .navigationTitle("Audible Environment")
            }
            .task {
                guard sdkReady else { return }
                let wearables = Wearables.shared
                registration = wearables.registrationState

                for await state in wearables.registrationStateStream() {
                    registration = state
                    print("Registration: \(state)")
                }
            }
            .task {
                guard sdkReady else { return }
                let deviceSelector = AutoDeviceSelector(wearables: Wearables.shared)
                selector = deviceSelector

                for await deviceID in deviceSelector.activeDeviceStream() {
                    glassesReady = deviceID != nil
                    print("Glasses ready: \(glassesReady)")
                }
            }
            .onOpenURL { url in
                guard sdkReady, url.scheme == "scenenarrator",
                      URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
                else { return }

                Task {
                    do {
                        _ = try await Wearables.shared.handleUrl(url)
                    } catch {
                        report("Meta AI callback error: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    @MainActor
    private func connect() async {
        guard !connecting, Wearables.shared.registrationState != .registered else { return }
        connecting = true
        errorMessage = nil
        defer { connecting = false }

        do {
            try await Wearables.shared.startRegistration()
        } catch {
            report("Registration error: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func startSession() {
        guard let selector, glassesReady, session == nil else { return }
        errorMessage = nil

        do {
            let newSession = try Wearables.shared.createSession(deviceSelector: selector)
            let states = newSession.stateStream()
            let errors = newSession.errorStream()
            let id = UUID()

            try newSession.start()
            session = newSession
            sessionID = id
            sessionState = .starting

            Task {
                for await state in states {
                    guard sessionID == id else { return }
                    sessionState = state
                    print("Session: \(state)")

                    if state == .stopped {
                        clearStream()
                        session = nil
                        sessionID = nil
                    }
                }
            }

            Task {
                for await error in errors {
                    guard sessionID == id else { return }
                    report("Session error: \(error.localizedDescription)")
                }
            }
        } catch {
            report("Session error: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func startStream() async {
        guard let session, let sessionID, sessionState == .started,
              camera == nil, !startingStream else { return }

        startingStream = true
        errorMessage = nil
        defer { startingStream = false }

        do {
            let wearables = Wearables.shared
            if try await wearables.checkPermissionStatus(.camera) != .granted {
                guard try await wearables.requestPermission(.camera) == .granted else {
                    report("Glasses camera permission was denied.")
                    return
                }
            }

            guard self.sessionID == sessionID, sessionState == .started else { return }

            let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard self.sessionID == sessionID,
                  sessionState == .started, session.state == .started else { return }

            photosAllowed = permission == .authorized || permission == .limited
            if !photosAllowed {
                report("Allow Scene Narrator to add photos in iPhone Settings to save snapshots.")
            }

            let config = StreamConfiguration(
                videoCodec: .raw,
                resolution: .low,
                frameRate: 24
            )
            guard let newCamera = try session.addCamera(config: config) else {
                report("Could not open the glasses camera.")
                return
            }

            let id = UUID()
            camera = newCamera
            streamID = id
            narrationFrames.removeAll()
            narrationSettlesAt = 0
            previousNarrationFrame = nil
            recentAnnouncements.removeAll()
            nextNarrationFrameAt = 0
            frameDescription = nil
            descriptionError = nil
            frameCount = 0
            photosSaved = 0
            nextSnapshotAt = nil

            let stream = newCamera.stream
            stream.statePublisher.listen { state in
                Task { @MainActor in
                    guard streamID == id else { return }
                    streamState = state
                    print("Stream: \(state)")

                    if state == .streaming {
                        if nextSnapshotAt == nil {
                            nextSnapshotAt = ProcessInfo.processInfo.systemUptime + snapshotInterval
                        }
                    } else {
                        nextSnapshotAt = nil
                    }

                    if state == .stopped {
                        clearStream()
                    }
                }
            }.store(in: streamListeners)

            stream.errorPublisher.listen { error in
                Task { @MainActor in
                    guard streamID == id else { return }
                    report("Stream error: \(error.localizedDescription)")
                }
            }.store(in: streamListeners)

            stream.videoFramePublisher.listen { frame in
                let receivedAt = Date().timeIntervalSince1970
                let frameTime = frame.sampleBuffer.presentationTimeStamp.seconds

                Task { @MainActor in
                    guard streamID == id, streamState != .stopping,
                          sessionState != .stopping else { return }

                    frameCount += 1
                    print("Frame \(frameCount) | received: \(receivedAt) | PTS: \(frameTime)s")

                    let now = ProcessInfo.processInfo.systemUptime
                    guard streamState == .streaming, sessionState == .started else { return }
                    let snapshotDue = nextSnapshotAt.map { now >= $0 } ?? false
                    let narrationDue = narrationRun != nil &&
                        pendingCapture == nil && now >= nextNarrationFrameAt
                    guard snapshotDue || pendingCapture != nil || narrationDue else { return }

                    if snapshotDue {
                        nextSnapshotAt = now + snapshotInterval
                    }

                    guard let image = frame.makeUIImage(),
                          let jpeg = image.jpegData(compressionQuality: 0.8) else {
                        report("Couldn't convert the glasses frame to JPEG.")
                        return
                    }

                    if pendingCapture != nil {
                        pendingCapture = nil
                        Task { await describeFrame([jpeg]) }
                    }
                    if narrationDue, let run = narrationRun {
                        let sample = NarrationFrame(jpeg: jpeg, pixels: Self.comparisonPixels(image))
                        let latestMotion = narrationFrames.last.map { Self.frameChange($0, sample) } ?? 0
                        if latestMotion >= 0.45 {
                            narrationSettlesAt = now + 1
                        }
                        narrationFrames.append(sample)
                        nextNarrationFrameAt = now + 0.5
                        if narrationFrames.count > 7 {
                            narrationFrames.removeFirst()
                        }
                        if narrationFrames.count >= 3 && !isDescribing && !speechSynthesizer.isSpeaking &&
                            now >= max(geminiRetryAt, nextNarrationRequestAt) {
                            if !recentAnnouncements.isEmpty && now < narrationSettlesAt {
                                narrationStatus = "Waiting for the view to settle…"
                            } else {
                                let reference = previousNarrationFrame
                                let samples = narrationFrames
                                let recentChanges = zip(samples, samples.dropFirst()).map {
                                    Self.frameChange($0.0, $0.1)
                                }
                                let eventIndex = recentChanges.indices.dropLast().last {
                                    recentChanges[$0] >= 0.02
                                }
                                let sceneChange = reference.map { Self.frameChange($0, sample) } ?? 1
                                if recentAnnouncements.isEmpty || eventIndex != nil || sceneChange >= 0.02 {
                                    let sequence: [NarrationFrame]
                                    if let eventIndex {
                                        sequence = [samples[eventIndex], samples[eventIndex + 1], sample]
                                    } else {
                                        sequence = [reference ?? samples[0], samples[samples.count - 2], sample]
                                    }
                                    nextNarrationRequestAt = now + 15
                                    narrationFrames = [sample]
                                    narrationStatus = "Sending frames to Gemini…"
                                    await describeFrame(sequence.map { $0.jpeg }, narration: run,
                                                        sourceStream: id, capturedAt: now, reference: sample)
                                } else {
                                    narrationStatus = "Watching for changes…"
                                }
                            }
                        }
                    }
                    if snapshotDue && photosAllowed {
                        await savePhoto(jpeg, streamID: id)
                    }
                }
            }.store(in: streamListeners)

            streamState = .starting
            stream.start()
        } catch {
            report("Camera error: \(error.localizedDescription)")
        }
    }

    private struct NarrationFrame {
        let jpeg: Data
        let pixels: [UInt8]?
    }

    private static func comparisonPixels(_ image: UIImage) -> [UInt8]? {
        guard let source = image.cgImage else { return nil }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return rendered ? pixels : nil
    }

    private static func frameChange(_ first: NarrationFrame, _ second: NarrationFrame) -> Double {
        guard let before = first.pixels, let after = second.pixels else { return 1 }
        let changedPixels = stride(from: 0, to: before.count, by: 4).reduce(0) { count, offset in
            let difference = (0..<3).map { abs(Int(before[offset + $0]) - Int(after[offset + $0])) }.max() ?? 0
            return count + (difference >= 24 ? 1 : 0)
        }
        return Double(changedPixels) / Double(before.count / 4)
    }

    private static let geminiKeyQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: Bundle.main.bundleIdentifier ?? "AudibleEnvironment",
        kSecAttrAccount as String: "gemini-api-key"
    ]

    private static func defaultGeminiKey() -> String {
        if let url = Bundle.main.url(forResource: "LocalGeminiKey", withExtension: "txt"),
           let key = try? String(contentsOf: url, encoding: .utf8) {
            return key.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return loadGeminiKey()
    }

    private static func loadGeminiKey() -> String {
        var query = geminiKeyQuery
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func saveGeminiKey(_ code: String) -> OSStatus {
        let attributes = [kSecValueData as String: Data(code.utf8)]
        let status = SecItemUpdate(geminiKeyQuery as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var item = geminiKeyQuery
        item[kSecValueData as String] = attributes[kSecValueData as String]
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil)
    }

    private struct GeminiResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable {
                    let text: String?
                    let thought: Bool?
                }

                let parts: [Part]
            }

            let content: Content?
        }

        let candidates: [Candidate]?
    }

    private func speakDescription(_ description: String) {
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .spokenAudio)
            try audio.setActive(true)
            guard !speechSynthesizer.isSpeaking else { return }
            speechSynthesizer.speak(AVSpeechUtterance(string: description))
        } catch {
            descriptionError = "Audio setup failed: \(error.localizedDescription)"
        }
    }

    private func requestDescription() {
        let capture = UUID()
        pendingCapture = capture
        descriptionError = nil

        Task {
            try? await Task.sleep(for: .seconds(5))
            guard pendingCapture == capture else { return }
            pendingCapture = nil
            descriptionError = "No frame arrived from the glasses. Check the stream and try again."
        }
    }

    @MainActor
    private func describeFrame(_ frames: [Data], narration: UUID? = nil, sourceStream: UUID? = nil, capturedAt: TimeInterval? = nil, reference: NarrationFrame? = nil) async {
        guard !isDescribing else { return }
        guard ProcessInfo.processInfo.systemUptime >= geminiRetryAt else {
            descriptionError = "Gemini is on cooldown. Try again later."
            return
        }
        descriptionError = nil
        let key = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            if narration != nil { narrationStatus = "Enter your Gemini API key." }
            descriptionError = "Enter your Gemini API key."
            return
        }

        isDescribing = true
        defer {
            isDescribing = false
            if let narration, narrationRun == narration, streamID == sourceStream,
               narrationStatus == "Sending frames to Gemini…" {
                narrationStatus = descriptionError == nil ? "Watching for changes…" : "Gemini request failed."
            }
        }

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent")!
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")

        let manualPrompt = """
        Describe this first-person camera image in one or two short sentences for a blind or low-vision person.
        Lead with what people are holding up or visibly doing. If no person is visible, describe the main objects and layout. Only describe what is visible.
        Say when the image is unclear. Do not give navigation instructions.
        """
        let narrationPrompt = """
        Give a blind or low-vision listener one concrete detail visible in the latest image.
        The images are chronological. Use earlier images to identify changes and actions.
        Announce a useful detail if the recent announcements below do not already cover it.
        A newly visible object, someone holding or pointing at something, a new action, or a new view
        is worth describing even if it stays still across all frames. With no prior announcements,
        describe the clearest useful detail in the current view.
        Return exactly QUIET when the view is unusable or all useful visible details were already announced.
        Ignore blur, lighting shifts, and head movement by itself. Describe only visible evidence.
        Return a single phrase of at most ten words. Do not give navigation instructions.
        Recent announcements:
        \(recentAnnouncements.joined(separator: "\n"))
        """
        let initialPrompt = """
        Give a blind or low-vision listener a brief first description of the latest image.
        Describe one visible object, person, action, or feature of the surroundings in at most ten words.
        A still scene is expected. If the view is unusable, say why briefly, such as "The view is too dark."
        Do not give navigation instructions.
        """
        let prompt = narration == nil ? manualPrompt :
            (recentAnnouncements.isEmpty ? initialPrompt : narrationPrompt)
        var parts: [[String: Any]] = [["text": prompt]]
        for frame in frames {
            parts.append(["inlineData": ["mimeType": "image/jpeg", "data": frame.base64EncodedString()]])
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["contents": [["parts": parts]]])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                descriptionError = "Gemini returned an invalid response."
                return
            }
            if http.statusCode == 429 {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 0
                let delay = max(geminiBackoff, retryAfter.isFinite ? min(retryAfter, 86_400) : 0)
                geminiRetryAt = ProcessInfo.processInfo.systemUptime + delay
                geminiBackoff = min(geminiBackoff * 2, 900)
                if narration != nil { narrationStatus = "Waiting for Gemini quota…" }
                descriptionError = "Gemini reached its request limit. Paused for about \(Int(delay.rounded(.up))) seconds."
                return
            }
            if let narration, narrationRun != narration || streamID != sourceStream || streamState != .streaming {
                return
            }
            guard http.statusCode == 200 else {
                switch http.statusCode {
                case 400, 401, 403:
                    descriptionError = "Gemini rejected the request (HTTP \(http.statusCode)). Check the API key and its permissions."
                default:
                    descriptionError = "Gemini returned HTTP \(http.statusCode)."
                }
                return
            }
            geminiBackoff = 60
            let result = try JSONDecoder().decode(GeminiResponse.self, from: data)
            let description = result.candidates?.first?.content?.parts
                .filter { $0.thought != true }
                .compactMap(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let description, !description.isEmpty else {
                descriptionError = "Gemini returned no description."
                return
            }
            if narration != nil {
                previousNarrationFrame = reference
                let words = description.split { !$0.isLetter && !$0.isNumber }
                if !words.isEmpty && words.allSatisfy({ $0.uppercased() == "QUIET" }) {
                    narrationStatus = recentAnnouncements.isEmpty
                        ? "Waiting for an initial description…"
                        : "Gemini replied. Nothing new to announce."
                    return
                }
                let normalized = words.map { $0.lowercased() }
                if recentAnnouncements.contains(where: {
                    $0.split { !$0.isLetter && !$0.isNumber }.map { $0.lowercased() } == normalized
                }) {
                    narrationStatus = "Already announced."
                    return
                }
                guard words.count <= 10,
                      let capturedAt,
                      !speechSynthesizer.isSpeaking else { return }
                guard ProcessInfo.processInfo.systemUptime - capturedAt <= 12 else {
                    narrationStatus = "Gemini replied too late. Waiting for a fresh scene."
                    return
                }
            }
            do {
                frameDescription = description
                if narration != nil {
                    recentAnnouncements = Array((recentAnnouncements + [description]).suffix(4))
                    speakDescription(description)
                }
            }
            if Self.saveGeminiKey(key) != errSecSuccess {
                descriptionError = "The iPhone could not save the Gemini key in Keychain."
            }
        } catch {
            if narration == nil || (narrationRun == narration && streamID == sourceStream) {
                descriptionError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func savePhoto(_ jpeg: Data, streamID id: UUID) async {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let asset = PHAssetCreationRequest.forAsset()
                asset.addResource(with: .photo, data: jpeg, options: nil)
            }

            print("Glasses snapshot saved to Photos")
            if streamID == id {
                photosSaved += 1
            }
        } catch {
            if streamID == id {
                report("Photo save failed: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func clearStream() {
        streamID = nil
        camera = nil
        streamListeners = ListenerTokenBag()
        streamState = .stopped
        nextSnapshotAt = nil
    }

    @MainActor
    private func report(_ message: String) {
        errorMessage = message
        print(message)
    }
}
