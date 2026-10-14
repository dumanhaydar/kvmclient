import CoreGraphics
import Foundation
import WebRTC

/// The families of KVM firmware the app can talk to. Each speaks its own protocol.
enum DeviceKind: String, Codable, CaseIterable, Identifiable {
    case jetKVM
    case piKVM
    case nanoKVM
    case tinyPilot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jetKVM: "JetKVM / Luckfox PicoKVM"
        case .piKVM: "PiKVM / BliKVM"
        case .nanoKVM: "Sipeed NanoKVM"
        case .tinyPilot: "TinyPilot"
        }
    }

    var shortTitle: String {
        switch self {
        case .jetKVM: "JetKVM"
        case .piKVM: "PiKVM"
        case .nanoKVM: "NanoKVM"
        case .tinyPilot: "TinyPilot"
        }
    }

    /// Whether logging in takes a user name as well as a password.
    var usesUsername: Bool {
        switch self {
        case .jetKVM: false
        case .piKVM, .nanoKVM, .tinyPilot: true
        }
    }

    var defaultUsername: String? {
        switch self {
        case .piKVM, .nanoKVM: "admin"
        case .jetKVM, .tinyPilot: nil
        }
    }
}

struct Credentials {
    var username: String?
    var password: String?
}

/// What the screen view renders.
enum VideoFeed {
    /// Decoded and drawn by WebRTC.
    case webRTC(RTCVideoTrack)
    /// H.264 sample buffers or JPEG images pushed by the driver.
    case frames(FrameStream)

    func isSame(as other: VideoFeed?) -> Bool {
        switch (self, other) {
        case (.webRTC(let a), .webRTC(let b)?): a === b
        case (.frames(let a), .frames(let b)?): a === b
        default: false
        }
    }
}

/// Driver → session notifications. Always called on the main actor.
@MainActor
protocol KVMDriverDelegate: AnyObject {
    func driver(progress message: String)
    func driverDidConnect()
    func driver(didFail error: Error)
    func driver(video: VideoFeed?)
    /// Remote display resolution, when the device reports it (the decoder also does).
    func driver(sourceSize: CGSize)
    /// nil when the HDMI input is fine, otherwise a human-readable reason.
    func driver(videoError: String?)
    func driver(keyboardLayout: String)
    func driver(tailscale: String?, zeroTier: String?)
}

/// One protocol implementation. Input coordinates and key codes are normalized by the session:
/// HID usages + modifier byte for keys, 0...32767 for absolute pointer axes, browser button mask
/// (1 left, 2 right, 4 middle), wheel notches (positive = up).
@MainActor
protocol KVMDriver: AnyObject {
    var delegate: KVMDriverDelegate? { get set }

    /// Authenticates and starts video + input. Throws `KVMError.credentialsRequired` when the
    /// device wants (other) credentials.
    func connect(credentials: Credentials) async throws
    func disconnect()

    func sendKeyboard(keys: [UInt8], modifier: UInt8)
    /// Same as `sendKeyboard`, returning once the device has taken the report (used for typing).
    func sendKeyboardAndWait(keys: [UInt8], modifier: UInt8) async
    func sendAbsoluteMouse(x: Int, y: Int, buttons: Int)
    func sendWheel(_ delta: Int)

    /// Whether the remote keyboard layout is stored on the device (JetKVM) rather than only locally.
    var storesKeyboardLayout: Bool { get }
    func setKeyboardLayout(_ code: String)
}

extension KVMDriver {
    var storesKeyboardLayout: Bool { false }
    func setKeyboardLayout(_ code: String) {}

    func sendKeyboardAndWait(keys: [UInt8], modifier: UInt8) async {
        sendKeyboard(keys: keys, modifier: modifier)
        // Without acknowledgements, a short pause keeps keystrokes from being merged.
        try? await Task.sleep(for: .milliseconds(12))
    }
}

/// Shared WebRTC factory (JetKVM data channels, Janus streams on PiKVM / TinyPilot).
enum WebRTCFactory {
    static let shared: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        #if os(iOS)
        // No audio is used: keep WebRTC from configuring and activating AVAudioSession
        // (play-and-record would ask for the microphone).
        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.useManualAudio = true
        audioSession.isAudioEnabled = false
        #endif
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()
}
