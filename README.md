# Audible Environment

Audible Environment is an iPhone accessibility prototype that turns the view from Ray-Ban Meta glasses into short spoken descriptions. It is designed for people who are blind or have low vision. The goal is to announce useful changes in the surroundings while leaving room to hear conversations and other sounds.

For example, if someone holds up a red mug, the app can say “Someone is holding up a red mug.” If the scene stays the same, automatic narration aims to stay quiet. A short sequence of frames gives the vision model more context for actions such as dancing than a single still image can provide.

## Project status

The iOS code on this repository’s main branch covers the initial glasses integration. The newer narration prototype is in local development. The sections below describe both stages so readers can tell which features are available in this checkout.

### Available in this repository

- Register the iPhone app with the Meta Wearables Device Access Toolkit and start a device session with paired Ray-Ban Meta glasses.
- Open the glasses camera stream and inspect stream state, frame counts, timestamps, and errors during development.
- Save a frame from the stream to the iPhone’s Photos library roughly every 10 seconds with Photos permission.

### Implemented in the local prototype

- **On-demand description.** Tap **Describe Frame** to analyze a fresh glasses frame. Tap **Speak Description** to play the result through the iPhone’s current audio output, including the glasses when selected.
- **Automatic narration.** Turn on a switch to sample frames, look for visual changes, and speak selected updates without tapping for each one.
- **On-device frame comparison.** The iPhone compares small previews of recent frames and the last frame analyzed by Gemini. It can skip uploads for near-identical views between periodic checks.
- **Temporal context.** The app sends up to four frames in chronological order, including an older reference when available. Gemini 3.5 Flash-Lite receives recent announcements as context so it can decide whether an observed change warrants speech.
- **Speech timing.** Automatic mode asks for a short phrase, discards late or overly long replies, and waits for speech to finish before starting another automatic request.
- **Direct model requests.** The iPhone calls Gemini over HTTPS using Wi-Fi or cellular. The Mac is used for development and installation. The app limits request frequency and pauses after rate-limit responses.

## How automatic narration works

1. **Capture.** The Meta toolkit delivers live camera frames to the Swift app on the iPhone.
2. **Compare.** The app samples the stream roughly twice per second and measures pixel changes locally. A change in viewpoint or lighting can also register as motion, so this step decides when to ask Gemini to look.
3. **Interpret.** Gemini compares the recent frames and previous announcements. It can return a brief description of a meaningful change or signal that the app should stay quiet.
4. **Speak.** AVFoundation reads timely descriptions aloud through the active iOS audio route.

The prototype is intended for scene awareness. It does not provide navigation instructions. Brief gestures may fall between samples, and model latency, internet connectivity, and API quota affect how quickly the app can respond.

## Run the GitHub version

1. Pair your Ray-Ban Meta glasses with your iPhone in the Meta AI app and enable Developer Mode for toolkit testing.
2. Open `Untitled Project.xcodeproj` in Xcode and let Swift Package Manager resolve the Meta toolkit dependencies.
3. Select a development team under **Signing & Capabilities**, select your physical iPhone as the run destination, and run the **MyApp** target.
4. Complete registration in the app, start the glasses session, and start the camera stream. Use the frame count and Xcode console to verify that frames are arriving.

## Roadmap

- **Publish the narration prototype.** Bring the local narration code into the repository with reproducible setup and a configuration flow that keeps credentials out of source control.
- **Improve change detection.** Tune the comparison with real glasses footage so subtle gestures are easier to catch and ordinary head movement or lighting changes trigger fewer uploads.
- **Build better scene memory.** Track what has already been said and recognize when a previously announced person, object, or activity has meaningfully changed.
- **Measure latency and API usage.** Compare frame sizes, sampling rates, and model response times to keep descriptions timely and control API costs.
- **Refine the listening experience.** Test how much detail people want, how often announcements should play, and how VoiceOver users start, pause, and replay narration.
- **Support distribution.** Evaluate a hosted backend for shared builds so service credentials can stay server-side, and test the experience with blind and low-vision users.

## Technology

- **Swift and SwiftUI** for the iPhone app and controls.
- **Meta Wearables Device Access Toolkit** for device registration, sessions, and camera streaming.
- **Gemini 3.5 Flash-Lite** for interpreting images and deciding when to narrate in the local prototype.
- **AVFoundation** for spoken descriptions in the local prototype.
