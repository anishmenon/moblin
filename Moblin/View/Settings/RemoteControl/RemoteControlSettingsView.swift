import SwiftUI
import CoreImage.CIFilterBuiltins
import AVFoundation

private struct InterfaceViewUrl: View {
    @EnvironmentObject var model: Model
    var url: String
    var image: String

    var body: some View {
        HStack {
            Image(systemName: image)
            Text(url)
            Spacer()
            Button(action: {
                UIPasteboard.general.string = url
                model.makeToast(title: "URL copied to clipboard")
            }, label: {
                Image(systemName: "doc.on.doc")
            })
        }
    }
}

private struct InterfaceView: View {
    var ip: String
    var port: UInt16
    var image: String

    var body: some View {
        InterfaceViewUrl(url: "ws://\(ip):\(port)", image: image)
    }
}

private struct PasswordView: View {
    @EnvironmentObject var model: Model
    @State var value: String
    var onSubmit: (String) -> Void
    @State private var changed = false
    @State private var submitted = false
    @State private var message: String?

    private func submit() {
        value = value.trim()
        if isGoodPassword(password: value) {
            submitted = true
            onSubmit(value)
        }
    }

    private func createMessage() -> String? {
        if isGoodPassword(password: value) {
            return nil
        } else {
            return "Not long and random enough"
        }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("", text: $value)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .onChange(of: value) { _ in
                            changed = true
                            message = createMessage()
                        }
                        .onSubmit {
                            submit()
                        }
                        .submitLabel(.done)
                        .onDisappear {
                            if changed && !submitted {
                                submit()
                            }
                        }
                    Button {
                        UIPasteboard.general.string = value
                        model.makeToast(title: "Password copied to clipboard")
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            } footer: {
                if let message {
                    Text(message)
                        .foregroundColor(.red)
                        .bold()
                }
            }
            Section {
                Button {
                    value = randomGoodPassword()
                    submit()
                } label: {
                    HCenter {
                        Text("Generate")
                    }
                }
            }
        }
        .navigationTitle("Password")
    }
}

// QR Code display view that doesn't involve camera scanning
struct QRCodeDisplayView: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var model: Model
    var isStreamer: Bool
    
    var body: some View {
        VStack(spacing: 24) {
            Text(isStreamer ? "Streamer QR Code" : "Assistant QR Code")
                .font(.headline)
            
            RemoteControlPairingQRCodeView(isStreamer: isStreamer)
                .frame(width: 250, height: 250)
                .background(Color.white)
                .cornerRadius(10)
            
            Text("Scan with \(isStreamer ? "Assistant" : "Streamer") device")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            
            Button("Close") {
                presentationMode.wrappedValue.dismiss()
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 12)
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(8)
        }
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(radius: 10)
        .padding(.horizontal, 30)
    }
}

private struct QRCodeScannerView: UIViewControllerRepresentable {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var model: Model
    
    func makeUIViewController(context: Context) -> UIViewController {
        let viewController = QRScannerViewController()
        viewController.delegate = context.coordinator
        return viewController
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, QRScannerDelegate {
        let parent: QRCodeScannerView
        
        init(_ parent: QRCodeScannerView) {
            self.parent = parent
        }
        
        func qrScanningDidComplete(with result: String) {
            // Parse the QR code data (moblin://pair?device=streamer/assistant&url=ws://192.168.1.1:2345&password=securepassword)
            guard let url = URLComponents(string: result),
                  url.scheme == "moblin",
                  url.host == "pair",
                  let queryItems = url.queryItems else {
                parent.model.makeToast(title: "Invalid QR code format")
                parent.presentationMode.wrappedValue.dismiss()
                return
            }
            
            if let deviceType = queryItems.first(where: { $0.name == "device" })?.value,
               let wsUrl = queryItems.first(where: { $0.name == "url" })?.value,
               let password = queryItems.first(where: { $0.name == "password" })?.value {
                
                // Handle based on device type in QR code
                if deviceType == "streamer" {
                    // Scanned a streamer QR code, configure assistant to connect to it
                    parent.model.database.remoteControl!.client.enabled = true
                    parent.model.database.remoteControl!.password = password
                    
                    // Fix: Handle split results properly without optional binding
                    let hostAndPort = wsUrl.replacingOccurrences(of: "ws://", with: "").split(separator: ":")
                    if hostAndPort.count == 2, let port = UInt16(hostAndPort[1]) {
                        // Configure connection to streamer
                        parent.model.database.remoteControl!.server.url = wsUrl
                        parent.model.reloadRemoteControlAssistant()
                    }
                    
                    parent.model.makeToast(title: "Successfully paired with Streamer")
                } else if deviceType == "assistant" {
                    // Scanned an assistant QR code, configure streamer to connect to it
                    parent.model.database.remoteControl!.server.enabled = true
                    parent.model.database.remoteControl!.password = password
                    parent.model.database.remoteControl!.server.url = wsUrl
                    
                    // Reload the remote control settings
                    parent.model.reloadRemoteControlStreamer()
                    
                    parent.model.makeToast(title: "Successfully paired with Assistant")
                } else {
                    parent.model.makeToast(title: "Unknown device type in QR code")
                }
            } else {
                parent.model.makeToast(title: "Missing required pairing information")
            }
            
            parent.presentationMode.wrappedValue.dismiss()
        }
        
        func qrScanningDidFail() {
            parent.model.makeToast(title: "QR code scanning failed")
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}

protocol QRScannerDelegate: AnyObject {
    func qrScanningDidComplete(with result: String)
    func qrScanningDidFail()
}

class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var captureSession: AVCaptureSession!
    var previewLayer: AVCaptureVideoPreviewLayer!
    weak var delegate: QRScannerDelegate?
    
    // Add static flag to track if scanner is active
    static var isScannerActive = false
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Set flag to indicate scanner is active
        QRScannerViewController.isScannerActive = true
        
        view.backgroundColor = UIColor.black
        
        // Create separate capture session that doesn't share resources
        captureSession = AVCaptureSession()
        captureSession.sessionPreset = .high
        
        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else { return }
        let videoInput: AVCaptureDeviceInput
        
        do {
            videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
        } catch {
            failed()
            return
        }
        
        if (captureSession.canAddInput(videoInput)) {
            captureSession.addInput(videoInput)
        } else {
            failed()
            return
        }
        
        let metadataOutput = AVCaptureMetadataOutput()
        
        if (captureSession.canAddOutput(metadataOutput)) {
            captureSession.addOutput(metadataOutput)
            
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        } else {
            failed()
            return
        }
        
        // Improved close button
        let closeButton = UIButton(type: .system)
        closeButton.setTitle("Close", for: .normal)
        closeButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 18)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.backgroundColor = UIColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 0.8)
        closeButton.layer.cornerRadius = 10
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 80),
            closeButton.heightAnchor.constraint(equalToConstant: 40)
        ])
        
        // Configure preview layer for proper camera display
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.frame = view.layer.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        view.bringSubviewToFront(closeButton)
        
        // More visible scanning guide overlay
        let scanFrame = UIView()
        scanFrame.layer.borderColor = UIColor.white.cgColor
        scanFrame.layer.borderWidth = 4
        scanFrame.layer.cornerRadius = 15
        view.addSubview(scanFrame)
        scanFrame.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scanFrame.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scanFrame.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            scanFrame.widthAnchor.constraint(equalToConstant: 250),
            scanFrame.heightAnchor.constraint(equalToConstant: 250)
        ])
        view.bringSubviewToFront(scanFrame)
        
        // Better scanning status label
        let statusContainer = UIView()
        statusContainer.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.8)
        statusContainer.layer.cornerRadius = 10
        view.addSubview(statusContainer)
        
        let statusLabel = UILabel()
        statusLabel.text = "Position QR code within frame"
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        statusContainer.addSubview(statusLabel)
        
        statusContainer.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            statusContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            statusContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusContainer.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
            
            statusLabel.topAnchor.constraint(equalTo: statusContainer.topAnchor, constant: 12),
            statusLabel.bottomAnchor.constraint(equalTo: statusContainer.bottomAnchor, constant: -12),
            statusLabel.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor, constant: -20)
        ])
        
        captureSession.startRunning()
    }
    
    @objc func closeTapped() {
        QRScannerViewController.isScannerActive = false
        dismiss(animated: true)
    }
    
    func failed() {
        let ac = UIAlertController(title: "Scanning not supported", message: "Your device does not support scanning a code from an item. Please use a device with a camera.", preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "OK", style: .default))
        present(ac, animated: true)
        captureSession = nil
        delegate?.qrScanningDidFail()
        QRScannerViewController.isScannerActive = false
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        if (captureSession?.isRunning == false) {
            captureSession.startRunning()
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        if (captureSession?.isRunning == true) {
            captureSession.stopRunning()
        }
        
        QRScannerViewController.isScannerActive = false
    }
    
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        captureSession.stopRunning()
        
        if let metadataObject = metadataObjects.first {
            guard let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject else { return }
            guard let stringValue = readableObject.stringValue else { return }
            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            
            QRScannerViewController.isScannerActive = false
            delegate?.qrScanningDidComplete(with: stringValue)
        }
    }
}

private struct RemoteControlSettingsStreamerView: View {
    @EnvironmentObject var model: Model
    @State private var showScanner = false
    @State private var showQRCode = false

    private func submitStreamerUrl(value: String) {
        guard isValidWebSocketUrl(url: value) == nil else {
            return
        }
        model.database.remoteControl!.server.url = value
        model.reloadRemoteControlStreamer()
    }

    private func submitStreamerPreviewFps(value: Float) {
        model.database.remoteControl!.server.previewFps = value
        model.setLowFpsImage()
    }

    private func formatStreamerPreviewFps(value: Float) -> String {
        return String(Int(value))
    }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: {
                model.database.remoteControl!.server.enabled
            }, set: { value in
                model.database.remoteControl!.server.enabled = value
                model.reloadRemoteControlStreamer()
            })) {
                Text("Enabled")
            }
            TextEditNavigationView(
                title: String(localized: "Assistant URL"),
                value: model.database.remoteControl!.server.url,
                onSubmit: submitStreamerUrl,
                footers: [
                    String(
                        localized: "Enter assistant's address and port. For example ws://132.23.43.43:2345."
                    ),
                ],
                keyboardType: .URL,
                placeholder: "ws://32.143.32.12:2345"
            )
            HStack {
                Text("Preview FPS")
                SliderView(
                    value: model.database.remoteControl!.server.previewFps!,
                    minimum: 1,
                    maximum: 5,
                    step: 1,
                    onSubmit: submitStreamerPreviewFps,
                    width: 20,
                    format: formatStreamerPreviewFps
                )
            }
            
            HStack {
                Spacer()
                // Single QR code button with menu
                Menu {
                    Button(action: {
                        if !QRScannerViewController.isScannerActive {
                            showScanner = true
                        }
                    }) {
                        Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    }
                    
                    Button(action: {
                        showQRCode = true
                    }) {
                        Label("Show QR Code", systemImage: "qrcode")
                    }
                } label: {
                    VStack {
                        Image(systemName: "qrcode")
                            .font(.system(size: 40))
                        Text("QR Code")
                            .font(.caption)
                    }
                    .frame(width: 120, height: 120)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(15)
                }
                .sheet(isPresented: $showScanner) {
                    QRCodeScannerView()
                        .edgesIgnoringSafeArea(.all)
                }
                .fullScreenCover(isPresented: $showQRCode) {
                    // Use fullScreenCover instead of sheet to avoid camera activation
                    ZStack {
                        Color(.systemBackground).edgesIgnoringSafeArea(.all)
                        
                        VStack {
                            HStack {
                                Spacer()
                                Button(action: {
                                    showQRCode = false
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 30))
                                        .foregroundColor(.gray)
                                }
                                .padding()
                            }
                            
                            Spacer()
                            
                            VStack(spacing: 24) {
                                Text("Streamer QR Code")
                                    .font(.headline)
                                
                                RemoteControlPairingQRCodeView(isStreamer: true)
                                    .frame(width: 250, height: 250)
                                    .background(Color.white)
                                    .cornerRadius(10)
                                
                                Text("Scan with Assistant device")
                                    .font(.subheadline)
                            }
                            
                            Spacer()
                        }
                    }
                }
                Spacer()
            }
            .padding(.vertical)
        } header: {
            Text("Streamer")
        } footer: {
            Text("""
            Enable to allow an assistant to monitor and control this device from a \
            different device.
            """)
        }
    }
}

private struct RemoteControlSettingsAssistantView: View {
    @EnvironmentObject var model: Model
    @State private var showScanner = false
    @State private var showQRCode = false

    private func submitAssistantPort(value: String) {
        guard let port = UInt16(value.trim()) else {
            return
        }
        model.database.remoteControl!.client.port = port
        model.reloadRemoteControlAssistant()
    }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: {
                model.database.remoteControl!.client.enabled
            }, set: { value in
                model.database.remoteControl!.client.enabled = value
                model.reloadRemoteControlAssistant()
                model.objectWillChange.send()
            })) {
                Text("Enabled")
            }
            TextEditNavigationView(
                title: String(localized: "Server port"),
                value: String(model.database.remoteControl!.client.port),
                onSubmit: submitAssistantPort,
                keyboardType: .numbersAndPunctuation,
                placeholder: "2345"
            )
            
            HStack {
                Spacer()
                // Single QR code button with menu
                Menu {
                    Button(action: {
                        if !QRScannerViewController.isScannerActive {
                            showScanner = true
                        }
                    }) {
                        Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    }
                    
                    Button(action: {
                        showQRCode = true
                    }) {
                        Label("Show QR Code", systemImage: "qrcode")
                    }
                } label: {
                    VStack {
                        Image(systemName: "qrcode")
                            .font(.system(size: 40))
                        Text("QR Code")
                            .font(.caption)
                    }
                    .frame(width: 120, height: 120)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(15)
                }
                .sheet(isPresented: $showScanner) {
                    QRCodeScannerView()
                        .edgesIgnoringSafeArea(.all)
                }
                .fullScreenCover(isPresented: $showQRCode) {
                    // Use fullScreenCover instead of sheet to avoid camera activation
                    ZStack {
                        Color(.systemBackground).edgesIgnoringSafeArea(.all)
                        
                        VStack {
                            HStack {
                                Spacer()
                                Button(action: {
                                    showQRCode = false
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 30))
                                        .foregroundColor(.gray)
                                }
                                .padding()
                            }
                            
                            Spacer()
                            
                            VStack(spacing: 24) {
                                Text("Assistant QR Code")
                                    .font(.headline)
                                
                                RemoteControlPairingQRCodeView(isStreamer: false)
                                    .frame(width: 250, height: 250)
                                    .background(Color.white)
                                    .cornerRadius(10)
                                
                                Text("Scan with Streamer device")
                                    .font(.subheadline)
                            }
                            
                            Spacer()
                        }
                    }
                }
                Spacer()
            }
            .padding(.vertical)
        } header: {
            Text("Assistant")
        } footer: {
            Text("""
            Enable to let a streamer device connect to this device. Once connected, \
            this device can monitor and control the streamer device.
            """)
        }
    }
}

private struct RemoteControlSettingsRelayView: View {
    @EnvironmentObject var model: Model

    private func submitAssistantRelayUrl(value: String) {
        guard isValidWebSocketUrl(url: value) == nil else {
            return
        }
        model.database.remoteControl!.client.relay!.baseUrl = value
        model.reloadRemoteControlRelay()
    }

    private func submitAssistantRelayBridgeId(value: String) {
        guard !value.isEmpty else {
            return
        }
        model.database.remoteControl!.client.relay!.bridgeId = value
        model.reloadRemoteControlRelay()
    }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: {
                model.database.remoteControl!.client.relay!.enabled
            }, set: { value in
                model.database.remoteControl!.client.relay!.enabled = value
                model.reloadRemoteControlRelay()
            })) {
                Text("Enabled")
            }
            TextEditNavigationView(
                title: String(localized: "Base URL"),
                value: model.database.remoteControl!.client.relay!.baseUrl,
                onSubmit: submitAssistantRelayUrl
            )
            TextEditNavigationView(
                title: String(localized: "Bridge id"),
                value: model.database.remoteControl!.client.relay!.bridgeId,
                onSubmit: submitAssistantRelayBridgeId
            )
        } header: {
            Text("Relay")
        } footer: {
            Text("Use a relay server when the assistant is behind CGNAT or similar.")
        }
    }
}

private struct RemoteControlPairingQRCodeView: View {
    @EnvironmentObject var model: Model
    var isStreamer: Bool
    let context = CIContext()
    let filter = CIFilter.qrCodeGenerator()
    
    private func generateQRCode(from string: String) -> UIImage {
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        
        if let outputImage = filter.outputImage {
            if let cgimg = context.createCGImage(outputImage, from: outputImage.extent) {
                return UIImage(cgImage: cgimg)
            }
        }
        
        return UIImage(systemName: "xmark.circle") ?? UIImage()
    }
    
    private func getPairingData() -> String {
        if isStreamer {
            // Generate QR code for Streamer (Assistant devices will scan this)
            let port = model.database.remoteControl!.client.port
            let ipAddress = model.ipStatuses.first(where: { $0.ipType == .ipv4 })?.ip ?? "127.0.0.1"
            let password = model.database.remoteControl!.password!
            
            return "moblin://pair?device=streamer&url=ws://\(ipAddress):\(port)&password=\(password)"
        } else {
            // Generate QR code for Assistant (Streamer devices will scan this)
            let port = model.database.remoteControl!.client.port
            let ipAddress = model.ipStatuses.first(where: { $0.ipType == .ipv4 })?.ip ?? "127.0.0.1"
            let password = model.database.remoteControl!.password!
            
            return "moblin://pair?device=assistant&url=ws://\(ipAddress):\(port)&password=\(password)"
        }
    }
    
    var body: some View {
        VStack {
            Image(uiImage: generateQRCode(from: getPairingData()))
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 200, height: 200)
                .background(Color.white)
                .cornerRadius(10)
            
            Text(isStreamer ? "Scan with Assistant device" : "Scan with Streamer device")
                .font(.caption)
                .padding(.top, 8)
        }
        .padding()
    }
}

struct RemoteControlSettingsView: View {
    @EnvironmentObject var model: Model

    private func submitPassword(value: String) {
        model.database.remoteControl!.password = value.trim()
        model.reloadRemoteControlStreamer()
        model.reloadRemoteControlAssistant()
    }

    private func relayUrl() -> String {
        let relay = model.database.remoteControl!.client.relay!
        return "\(relay.baseUrl)/streamer/\(relay.bridgeId)"
    }

    var body: some View {
        Form {
            Section {
                Text("Control and monitor Moblin from another device.")
            }
            Section {
                NavigationLink {
                    StreamObsRemoteControlSettingsView(stream: model.stream)
                } label: {
                    Toggle(isOn: Binding(get: {
                        model.stream.obsWebSocketEnabled!
                    }, set: {
                        model.setObsRemoteControlEnabled(enabled: $0)
                    })) {
                        IconAndTextView(
                            image: "dot.radiowaves.left.and.right",
                            text: String(localized: "OBS remote control")
                        )
                    }
                }
            } header: {
                Text("Shortcut")
            }
            Section {
                NavigationLink {
                    PasswordView(
                        value: model.database.remoteControl!.password!,
                        onSubmit: submitPassword
                    )
                } label: {
                    TextItemView(
                        name: String(localized: "Password"),
                        value: model.database.remoteControl!.password!,
                        sensitive: true
                    )
                }
            } header: {
                Text("General")
            } footer: {
                Text("Used by both streamer and assistant.")
            }
            RemoteControlSettingsStreamerView()
            RemoteControlSettingsAssistantView()
            RemoteControlSettingsRelayView()
            if model.database.remoteControl!.client.enabled {
                Section {
                    List {
                        ForEach(model.ipStatuses.filter { $0.ipType == .ipv4 }) { status in
                            InterfaceView(
                                ip: status.ipType.formatAddress(status.ip),
                                port: model.database.remoteControl!.client.port,
                                image: urlImage(interfaceType: status.interfaceType)
                            )
                        }
                        InterfaceView(
                            ip: personalHotspotLocalAddress,
                            port: model.database.remoteControl!.client.port,
                            image: "personalhotspot"
                        )
                        ForEach(model.ipStatuses.filter { $0.ipType == .ipv6 }) { status in
                            InterfaceView(
                                ip: status.ipType.formatAddress(status.ip),
                                port: model.database.remoteControl!.client.port,
                                image: urlImage(interfaceType: status.interfaceType)
                            )
                        }
                        if model.database.remoteControl!.client.relay!.enabled {
                            InterfaceViewUrl(url: relayUrl(), image: "globe")
                        }
                    }
                } footer: {
                    VStack(alignment: .leading) {
                        Text("""
                        Enter one of the URLs as "Assistant URL" in the streamer device to \
                        connect to this device.
                        """)
                    }
                }
                
                Section {
                    HCenter {
                        RemoteControlPairingQRCodeView(isStreamer: false)
                    }
                } header: {
                    Text("Quick Pairing")
                } footer: {
                    Text("The Streamer device can scan this QR code to automatically connect to this Assistant.")
                }
            }
        }
        .navigationTitle("Remote control")
    }
}
