import AVFoundation
import Combine
import SwiftUI

struct MacCameraCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = MacCameraController()
    let onCapture: (Data) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Camera").font(Geist.heading(.title2))
                    Text("Use a built-in, external, or Continuity Camera device.")
                        .font(Geist.caption()).foregroundStyle(Geist.muted)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Take Photo") {
                    camera.capture { data in
                        onCapture(data)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!camera.isReady)
                .accessibilityIdentifier("mac_capture_camera_shutter")
            }
            .padding(Geist.Spacing.four)
            .background(Geist.Palette.background100)
            GeistDivider()
            ZStack {
                Color.black
                MacCameraPreview(session: camera.session)
                if camera.isConfiguring {
                    ProgressView("Preparing Camera…").foregroundStyle(.white)
                } else if let message = camera.errorMessage {
                    VStack(spacing: Geist.Spacing.three) {
                        Image(systemName: "camera.fill").font(.system(size: 34))
                        Text(message).multilineTextAlignment(.center)
                        if camera.permissionDenied,
                           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                            Link("Open Camera Privacy Settings", destination: url)
                        }
                    }
                    .font(Geist.body()).foregroundStyle(.white)
                    .padding(Geist.Spacing.six)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }
}

private struct MacCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> MacCameraPreviewNSView {
        let view = MacCameraPreviewNSView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ view: MacCameraPreviewNSView, context: Context) {
        view.previewLayer.session = session
    }
}

private final class MacCameraPreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspect
        layer = previewLayer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

private final class MacCameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    @Published private(set) var isReady = false
    @Published private(set) var isConfiguring = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var permissionDenied = false

    private let output = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "vox.camera.session", qos: .userInitiated)
    private var completion: ((Data) -> Void)?

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                granted ? self?.configure() : self?.publishPermissionDenied()
            }
        default:
            publishPermissionDenied()
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func capture(completion: @escaping (Data) -> Void) {
        self.completion = completion
        output.capturePhoto(with: AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]), delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            publish(error: error.localizedDescription)
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            publish(error: String(localized: "The camera did not return an image."))
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.completion?(data)
            self?.completion = nil
        }
    }

    private func configure() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                session.beginConfiguration()
                do {
                    session.sessionPreset = .photo
                    guard let device = AVCaptureDevice.default(for: .video) else {
                        throw MacCameraError.noCamera
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input), session.canAddOutput(output) else {
                        throw MacCameraError.configurationFailed
                    }
                    session.addInput(input)
                    session.addOutput(output)
                    session.commitConfiguration()
                } catch {
                    session.commitConfiguration()
                    throw error
                }
                session.startRunning()
                DispatchQueue.main.async {
                    self.isConfiguring = false
                    self.isReady = true
                }
            } catch {
                self.publish(error: error.localizedDescription)
            }
        }
    }

    private func publishPermissionDenied() {
        DispatchQueue.main.async { [weak self] in
            self?.isConfiguring = false
            self?.permissionDenied = true
            self?.errorMessage = String(localized: "Camera access is required to take a photo.")
        }
    }

    private func publish(error: String) {
        DispatchQueue.main.async { [weak self] in
            self?.isConfiguring = false
            self?.isReady = false
            self?.errorMessage = error
        }
    }
}

private enum MacCameraError: LocalizedError {
    case noCamera
    case configurationFailed

    var errorDescription: String? {
        switch self {
        case .noCamera: String(localized: "No camera is available. Connect a camera or enable Continuity Camera.")
        case .configurationFailed: String(localized: "The selected camera could not be configured.")
        }
    }
}
