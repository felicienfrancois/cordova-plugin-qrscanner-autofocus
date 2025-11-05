import Foundation
import UIKit
import AVFoundation

@objc(QRScanner)
class QRScanner : CDVPlugin, AVCaptureMetadataOutputObjectsDelegate {
    
    class CameraView: UIView {
        var videoPreviewLayer: AVCaptureVideoPreviewLayer?
        
        func interfaceOrientationToVideoOrientation(_ orientation : UIInterfaceOrientation) -> AVCaptureVideoOrientation {
            switch orientation {
            case .portrait:
                return .portrait
            case .portraitUpsideDown:
                return .portraitUpsideDown
            case .landscapeLeft:
                return .landscapeLeft
            case .landscapeRight:
                return .landscapeRight
            default:
                return .portrait
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let sublayers = self.layer.sublayers {
                for layer in sublayers {
                    layer.frame = self.bounds
                }
            }
            
            // Obtain the current interface orientation in a modern, safe way
            var ifaceOrientation = UIInterfaceOrientation.portrait
            if #available(iOS 13.0, *) {
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    ifaceOrientation = scene.interfaceOrientation
                }
            } else {
                ifaceOrientation = UIApplication.shared.statusBarOrientation
            }
            self.videoPreviewLayer?.connection?.videoOrientation = interfaceOrientationToVideoOrientation(ifaceOrientation)
        }
        
        
        func addPreviewLayer(_ previewLayer: AVCaptureVideoPreviewLayer?) {
            guard let previewLayer = previewLayer else { return }
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.frame = self.bounds
            self.layer.addSublayer(previewLayer)
            self.videoPreviewLayer = previewLayer
        }
        
        func removePreviewLayer() {
            if let v = self.videoPreviewLayer {
                v.removeFromSuperlayer()
                self.videoPreviewLayer = nil
            }
        }
    }

    var cameraView: CameraView!
    var captureSession: AVCaptureSession?
    var captureVideoPreviewLayer: AVCaptureVideoPreviewLayer?
    var metaOutput: AVCaptureMetadataOutput?

    var currentCamera: Int = 0
    var frontCamera: AVCaptureDevice?
    var backCamera: AVCaptureDevice?

    var scanning: Bool = false
    var paused: Bool = false
    var nextScanningCommand: CDVInvokedUrlCommand?

    enum QRScannerError: Int32 {
        case unexpected_error = 0,
        camera_access_denied = 1,
        camera_access_restricted = 2,
        back_camera_unavailable = 3,
        front_camera_unavailable = 4,
        camera_unavailable = 5,
        scan_canceled = 6,
        light_unavailable = 7,
        open_settings_unavailable = 8
    }

    enum CaptureError: Error {
        case backCameraUnavailable
        case frontCameraUnavailable
        case couldNotCaptureInput(error: NSError)
    }

    enum LightError: Error {
        case torchUnavailable
    }

    override func pluginInitialize() {
        super.pluginInitialize()
        NotificationCenter.default.addObserver(self, selector: #selector(pageDidLoad), name: NSNotification.Name.CDVPageDidLoad, object: nil)
        self.cameraView = CameraView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height))
        self.cameraView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    func sendErrorCode(command: CDVInvokedUrlCommand, error: QRScannerError){
        let pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: error.rawValue)
        commandDelegate!.send(pluginResult, callbackId:command.callbackId)
    }

    // utility method
    @objc func backgroundThread(delay: Double = 0.0, background: (() -> Void)? = nil, completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            background?()
            if let completion = completion {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: completion)
            }
        }
    }

    @objc func prepScanner(command: CDVInvokedUrlCommand) -> Bool{
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .restricted {
            self.sendErrorCode(command: command, error: QRScannerError.camera_access_restricted)
            return false
        } else if status == .denied {
            self.sendErrorCode(command: command, error: QRScannerError.camera_access_denied)
            return false
        }
        do {
            if (captureSession?.isRunning != true){
                cameraView.backgroundColor = .clear
                if let web = self.webView, let superview = web.superview {
                    superview.insertSubview(cameraView, belowSubview: web)
                }
                let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
                let cameras = session.devices
                for camera in cameras {
                    if camera.position == .front {
                        self.frontCamera = camera
                    }
                    if camera.position == .back {
                        self.backCamera = camera
                        try camera.lockForConfiguration()
                        camera.focusMode = .continuousAutoFocus
                        camera.unlockForConfiguration()
                    }
                }
                // older iPods have no back camera
                if backCamera == nil {
                    currentCamera = 1
                }
                let input: AVCaptureDeviceInput = try self.createCaptureDeviceInput()
                captureSession = AVCaptureSession()
                if let captureSession = captureSession {
                    if captureSession.canAddInput(input) {
                        captureSession.addInput(input)
                    }
                    metaOutput = AVCaptureMetadataOutput()
                    if let metaOutput = metaOutput, captureSession.canAddOutput(metaOutput) {
                        captureSession.addOutput(metaOutput)
                        metaOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                        metaOutput.metadataObjectTypes = [.qr]
                    }
                    captureVideoPreviewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
                    cameraView.addPreviewLayer(captureVideoPreviewLayer)
                    captureSession.startRunning()
                }
            }
            return true
        } catch CaptureError.backCameraUnavailable {
            self.sendErrorCode(command: command, error: QRScannerError.back_camera_unavailable)
        } catch CaptureError.frontCameraUnavailable {
            self.sendErrorCode(command: command, error: QRScannerError.front_camera_unavailable)
        } catch CaptureError.couldNotCaptureInput(let error){
            print(error.localizedDescription)
            self.sendErrorCode(command: command, error: QRScannerError.camera_unavailable)
        } catch {
            self.sendErrorCode(command: command, error: QRScannerError.unexpected_error)
        }
        return false
    }

    @objc func createCaptureDeviceInput() throws -> AVCaptureDeviceInput {
        let captureDevice: AVCaptureDevice
        if currentCamera == 0 {
            if let back = backCamera {
                captureDevice = back
            } else {
                throw CaptureError.backCameraUnavailable
            }
        } else {
            if let front = frontCamera {
                captureDevice = front
            } else {
                throw CaptureError.frontCameraUnavailable
            }
        }
        do {
            return try AVCaptureDeviceInput(device: captureDevice)
        } catch let error as NSError {
            throw CaptureError.couldNotCaptureInput(error: error)
        }
    }

    @objc func makeOpaque(){
        self.webView?.isOpaque = true
        self.webView?.backgroundColor = .white
        self.webView?.scrollView.backgroundColor = .white
    }

    @objc func boolToNumberString(bool: Bool) -> String{
        return bool ? "1" : "0"
    }

    @objc func configureLight(command: CDVInvokedUrlCommand, state: Bool){
        let useMode: AVCaptureDevice.TorchMode = state ? .on : .off
        do {
            // torch is only available for back camera
            guard let back = backCamera,
                  back.hasTorch,
                  back.isTorchAvailable,
                  back.isTorchModeSupported(useMode) else {
                throw LightError.torchUnavailable
            }
            try back.lockForConfiguration()
            back.torchMode = useMode
            back.unlockForConfiguration()
            self.getStatus(command)
        } catch LightError.torchUnavailable {
            self.sendErrorCode(command: command, error: QRScannerError.light_unavailable)
        } catch let error as NSError {
            print(error.localizedDescription)
            self.sendErrorCode(command: command, error: QRScannerError.unexpected_error)
        } catch {
            self.sendErrorCode(command: command, error: QRScannerError.unexpected_error)
        }
    }

    // This method processes metadataObjects captured by iOS.
    func metadataOutput(_ captureOutput: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        if metadataObjects.isEmpty || scanning == false {
            return
        }
        if let found = metadataObjects[0] as? AVMetadataMachineReadableCodeObject {
            if found.type == .qr, let val = found.stringValue {
                scanning = false
                if let next = nextScanningCommand {
                    let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: val)
                    commandDelegate!.send(pluginResult, callbackId: next.callbackId)
                }
                nextScanningCommand = nil
            }
        }
    }

    @objc func pageDidLoad() {
        self.webView?.isOpaque = false
        self.webView?.backgroundColor = .clear
    }

    // ---- BEGIN EXTERNAL API ----

    @objc func prepare(_ command: CDVInvokedUrlCommand){
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { (granted) in
                self.backgroundThread(delay: 0) {
                    if self.prepScanner(command: command) {
                        self.getStatus(command)
                    }
                }
            }
        } else {
            if self.prepScanner(command: command) {
                self.getStatus(command)
            }
        }
    }

    @objc func scan(_ command: CDVInvokedUrlCommand){
        if self.prepScanner(command: command) {
            nextScanningCommand = command
            scanning = true
        }
    }

    @objc func cancelScan(_ command: CDVInvokedUrlCommand){
        if self.prepScanner(command: command) {
            scanning = false
            if let next = nextScanningCommand {
                self.sendErrorCode(command: next, error: QRScannerError.scan_canceled)
            }
            self.getStatus(command)
        }
    }

    @objc func show(_ command: CDVInvokedUrlCommand) {
        self.webView?.isOpaque = false
        self.webView?.backgroundColor = .clear
        self.webView?.scrollView.backgroundColor = .clear
        self.getStatus(command)
    }

    @objc func hide(_ command: CDVInvokedUrlCommand) {
        self.makeOpaque()
        self.getStatus(command)
    }

    @objc func pausePreview(_ command: CDVInvokedUrlCommand) {
        if scanning {
            paused = true
            scanning = false
        }
        captureVideoPreviewLayer?.connection?.isEnabled = false
        self.getStatus(command)
    }

    @objc func resumePreview(_ command: CDVInvokedUrlCommand) {
        if paused {
            paused = false
            scanning = true
        }
        captureVideoPreviewLayer?.connection?.isEnabled = true
        self.getStatus(command)
    }

    // backCamera is 0, frontCamera is 1

    @objc func useCamera(_ command: CDVInvokedUrlCommand){
        guard let index = command.arguments[0] as? Int else {
            self.getStatus(command)
            return
        }
        if currentCamera != index {
            if backCamera != nil && frontCamera != nil {
                currentCamera = index
                if self.prepScanner(command: command) {
                    do {
                        captureSession?.beginConfiguration()
                        if let currentInput = captureSession?.inputs.first as? AVCaptureDeviceInput {
                            captureSession?.removeInput(currentInput)
                        }
                        let input = try self.createCaptureDeviceInput()
                        if let captureSession = captureSession, captureSession.canAddInput(input) {
                            captureSession.addInput(input)
                        }
                        captureSession?.commitConfiguration()
                        self.getStatus(command)
                    } catch CaptureError.backCameraUnavailable {
                        self.sendErrorCode(command: command, error: QRScannerError.back_camera_unavailable)
                    } catch CaptureError.frontCameraUnavailable {
                        self.sendErrorCode(command: command, error: QRScannerError.front_camera_unavailable)
                    } catch CaptureError.couldNotCaptureInput(let error) {
                        print(error.localizedDescription)
                        self.sendErrorCode(command: command, error: QRScannerError.camera_unavailable)
                    } catch {
                        self.sendErrorCode(command: command, error: QRScannerError.unexpected_error)
                    }
                }
            } else {
                if backCamera == nil {
                    self.sendErrorCode(command: command, error: QRScannerError.back_camera_unavailable)
                } else {
                    self.sendErrorCode(command: command, error: QRScannerError.front_camera_unavailable)
                }
            }
        } else {
            self.getStatus(command)
        }
    }

    @objc func enableLight(_ command: CDVInvokedUrlCommand) {
        if self.prepScanner(command: command) {
            self.configureLight(command: command, state: true)
        }
    }

    @objc func disableLight(_ command: CDVInvokedUrlCommand) {
        if self.prepScanner(command: command) {
            self.configureLight(command: command, state: false)
        }
    }

    @objc func destroy(_ command: CDVInvokedUrlCommand) {
        self.makeOpaque()
        if self.captureSession != nil {
            backgroundThread(delay: 0, background: {
                self.captureSession!.stopRunning()
                self.cameraView.removePreviewLayer()
                self.captureVideoPreviewLayer = nil
                self.metaOutput = nil
                self.captureSession = nil
                self.currentCamera = 0
                self.frontCamera = nil
                self.backCamera = nil
            }, completion: {
                self.getStatus(command)
            })
        } else {
            self.getStatus(command)
        }
    }

    @objc func getStatus(_ command: CDVInvokedUrlCommand){

        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

        let authorized = (authorizationStatus == .authorized)
        let denied = (authorizationStatus == .denied)
        let restricted = (authorizationStatus == .restricted)
        let prepared = (captureSession?.isRunning == true)
        let previewing = (captureVideoPreviewLayer?.connection?.isEnabled == true)
        let showing = (self.webView?.backgroundColor == UIColor.clear)
        let lightEnabled = (backCamera?.torchMode == .on)

        // canOpenSettings: modern check (iOS 8+ supported, but verify URL)
        var canOpenSettings = false
        if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
            canOpenSettings = UIApplication.shared.canOpenURL(settingsUrl)
        }

        var canEnableLight = false
        if let back = backCamera {
            canEnableLight = back.hasTorch && back.isTorchAvailable && back.isTorchModeSupported(.on)
        }

        let canChangeCamera = (backCamera != nil && frontCamera != nil)

        let status = [
            "authorized": boolToNumberString(bool: authorized),
            "denied": boolToNumberString(bool: denied),
            "restricted": boolToNumberString(bool: restricted),
            "prepared": boolToNumberString(bool: prepared),
            "scanning": boolToNumberString(bool: scanning),
            "previewing": boolToNumberString(bool: previewing),
            "showing": boolToNumberString(bool: showing),
            "lightEnabled": boolToNumberString(bool: lightEnabled),
            "canOpenSettings": boolToNumberString(bool: canOpenSettings),
            "canEnableLight": boolToNumberString(bool: canEnableLight),
            "canChangeCamera": boolToNumberString(bool: canChangeCamera),
            "currentCamera": String(currentCamera)
        ]

        let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: status)
        commandDelegate!.send(pluginResult, callbackId:command.callbackId)
    }

    @objc func openSettings(_ command: CDVInvokedUrlCommand) {
        if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
            if UIApplication.shared.canOpenURL(settingsUrl) {
                if #available(iOS 10.0, *) {
                    UIApplication.shared.open(settingsUrl, options: [:]) { _ in
                        self.getStatus(command)
                    }
                } else {
                    // deprecated but kept for older runtimes
                    UIApplication.shared.openURL(settingsUrl)
                    self.getStatus(command)
                }
            } else {
                self.sendErrorCode(command: command, error: QRScannerError.open_settings_unavailable)
            }
        } else {
            self.sendErrorCode(command: command, error: QRScannerError.open_settings_unavailable)
        }
    }
}
