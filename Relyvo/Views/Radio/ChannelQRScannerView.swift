import SwiftUI
import AVFoundation
import CryptoKit

struct ChannelQRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onChannelScanned: (String) -> Void
    
    @State private var hasCameraAccess = false
    @State private var isSimulator = false
    
    var body: some View {
        NavigationStack {
            VStack {
                if isSimulator {
                    VStack(spacing: 20) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        Text("Camera is not available on iOS Simulator.")
                            .font(.headline)
                        
                        Button("Simulate Successful Scan") {
                            // Simulate scanning a secure channel
                            let mockID = "CH-MOCKSECURE"
                            if let mockKey = ChannelCrypto.deriveKey(passphrase: "mock", channelID: mockID) {
                                ChannelKeyStore.shared.importKey(key: mockKey, for: mockID)
                            }
                            onChannelScanned(mockID)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else if hasCameraAccess {
                    QRScannerViewRepresentable { urlString in
                        handleScannedURL(urlString)
                    }
                    .edgesIgnoringSafeArea(.all)
                } else {
                    ProgressView("Requesting camera access...")
                }
            }
            .navigationTitle("Scan Channel QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                checkEnvironmentAndPermissions()
            }
        }
    }
    
    private func checkEnvironmentAndPermissions() {
        #if targetEnvironment(simulator)
        isSimulator = true
        #else
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                self.hasCameraAccess = granted
            }
        }
        #endif
    }
    
    private func handleScannedURL(_ urlString: String) {
        guard let components = URLComponents(string: urlString),
              components.scheme == "relyvo",
              components.host == "channel",
              let queryItems = components.queryItems,
              let channelID = queryItems.first(where: { $0.name == "id" })?.value else {
            return
        }
        
        if let keyBase64 = queryItems.first(where: { $0.name == "key" })?.value,
           let keyData = Data(base64Encoded: keyBase64) {
            let key = SymmetricKey(data: keyData)
            ChannelKeyStore.shared.importKey(key: key, for: channelID)
        }
        
        DispatchQueue.main.async {
            onChannelScanned(channelID)
            dismiss()
        }
    }
}

fileprivate struct QRScannerViewRepresentable: UIViewControllerRepresentable {
    let completion: (String) -> Void
    
    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.delegate = context.coordinator
        return vc
    }
    
    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }
    
    class Coordinator: NSObject, ScannerViewControllerDelegate {
        let completion: (String) -> Void
        init(completion: @escaping (String) -> Void) {
            self.completion = completion
        }
        func didScan(code: String) {
            completion(code)
        }
    }
}

fileprivate protocol ScannerViewControllerDelegate: AnyObject {
    func didScan(code: String)
}

fileprivate class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: ScannerViewControllerDelegate?
    private var captureSession: AVCaptureSession!
    private var previewLayer: AVCaptureVideoPreviewLayer!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = UIColor.black
        captureSession = AVCaptureSession()
        
        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else { return }
        let videoInput: AVCaptureDeviceInput
        
        do {
            videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
        } catch {
            return
        }
        
        if (captureSession.canAddInput(videoInput)) {
            captureSession.addInput(videoInput)
        } else {
            return
        }
        
        let metadataOutput = AVCaptureMetadataOutput()
        if (captureSession.canAddOutput(metadataOutput)) {
            captureSession.addOutput(metadataOutput)
            
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        } else {
            return
        }
        
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.frame = view.layer.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        
        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession.startRunning()
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if captureSession?.isRunning == true {
            captureSession.stopRunning()
        }
    }
    
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        if let metadataObject = metadataObjects.first {
            guard let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject else { return }
            guard let stringValue = readableObject.stringValue else { return }
            
            captureSession.stopRunning()
            delegate?.didScan(code: stringValue)
        }
    }
}
