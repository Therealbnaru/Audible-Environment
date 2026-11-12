import CoreMedia
import MWDATCamera
import MWDATCore
import Photos
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

                    // Only convert a frame to JPEG when it's time for a snapshot.
                    let now = ProcessInfo.processInfo.systemUptime
                    guard photosAllowed, streamState == .streaming,
                          sessionState == .started,
                          let deadline = nextSnapshotAt, now >= deadline else { return }

                    nextSnapshotAt = now + snapshotInterval

                    guard let jpeg = frame.makeUIImage()?.jpegData(compressionQuality: 0.8) else {
                        report("Couldn't convert the glasses frame to JPEG.")
                        return
                    }

                    await savePhoto(jpeg, streamID: id)
                }
            }.store(in: streamListeners)

            streamState = .starting
            stream.start()
        } catch {
            report("Camera error: \(error.localizedDescription)")
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
