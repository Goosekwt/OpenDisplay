import AVFoundation
import SwiftUI
import UIKit

/// Scans the `opendisplay://pair` QR code, handling camera permission and camera-less iPads.
struct ScannerScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let onPaired: () -> Void

    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var hint: String?
    @State private var rejected: String?
    @State private var finished = false

    var body: some View {
        Group {
            switch access {
            case .authorized:
                if AVCaptureDevice.default(for: .video) == nil {
                    ContentUnavailableView {
                        Label("No Camera Available", systemImage: "camera")
                    } description: {
                        Text("Enter the key shown on your PC instead.")
                    } actions: {
                        manualEntryLink
                    }
                } else {
                    QRScannerView(onCode: handle)
                        .ignoresSafeArea(edges: .bottom)
                        .overlay(alignment: .bottom) { hintCapsule }
                }
            case .notDetermined:
                ProgressView()
                    .task {
                        _ = await AVCaptureDevice.requestAccess(for: .video)
                        access = AVCaptureDevice.authorizationStatus(for: .video)
                    }
            default:
                ContentUnavailableView {
                    Label("Camera Access Is Off", systemImage: "camera")
                } description: {
                    Text("Allow camera access in Settings to scan the pairing code, or enter the key instead.")
                } actions: {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(.borderedProminent)
                    manualEntryLink
                }
            }
        }
        .navigationTitle("Scan Pairing Code")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var manualEntryLink: some View {
        NavigationLink("Enter Key Manually") {
            ManualKeyEntryView(onPaired: onPaired)
        }
    }

    private var hintCapsule: some View {
        Text(hint ?? "Point the camera at the pairing code on your PC.")
            .font(.callout)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 32)
            .padding(.horizontal, 24)
    }

    private func handle(_ value: String) {
        guard !finished, value != rejected else { return }
        do {
            // A QR code must be the full link; a bare key is only accepted when typed.
            guard value.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("opendisplay:") else {
                throw PairingCode.ParseError.notOpenDisplayLink
            }
            try model.pair(with: PairingCode.parse(value))
            finished = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onPaired()
        } catch {
            rejected = value
            hint = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: QRScannerViewController, context: Context) {
        controller.onCode = onCode
    }
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "me.talsa.OpenDisplay.scanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var isConfigured = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return }

        let output = AVCaptureMetadataOutput()
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        if output.availableMetadataObjectTypes.contains(.qr) {
            output.metadataObjectTypes = [.qr]
        }
        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview

        // Keep the preview upright in every iPad orientation.
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: preview)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak preview] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async {
                guard let connection = preview?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
                connection.videoRotationAngle = angle
            }
        }
        isConfigured = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard isConfigured else { return }
        let session = self.session
        sessionQueue.async { if !session.isRunning { session.startRunning() } }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = self.session
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        for object in metadataObjects {
            if let code = object as? AVMetadataMachineReadableCodeObject, code.type == .qr, let value = code.stringValue {
                onCode?(value)
                return
            }
        }
    }
}
