// Kunci aplikasi: PIN/password (disimpan sebagai hash, tanpa Keychain), Touch ID,
// dan overlay blur yang menutupi WhatsApp saat terkunci.
import Cocoa
import CommonCrypto
import LocalAuthentication

// MARK: - Penyimpanan & verifikasi

final class AppLock {
    static let shared = AppLock()

    private struct Secret: Codable {
        var salt: Data
        var hash: Data
        var rounds: UInt32
        var isPIN: Bool
    }

    private let file: URL
    private var secret: Secret?

    private init() {
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhatsApp Web Launcher/lock.json")
        if let data = try? Data(contentsOf: file) { secret = try? JSONDecoder().decode(Secret.self, from: data) }
    }

    var hasSecret: Bool { secret != nil }
    var isPIN: Bool { secret?.isPIN ?? true }

    // Pengaturan
    private let d = UserDefaults.standard
    var enabled: Bool {
        get { hasSecret && d.bool(forKey: "lock.enabled") }
        set { d.set(newValue, forKey: "lock.enabled") }
    }
    /// Menit tanpa aktivitas sebelum terkunci. 0 = hanya saat app ditutup/disembunyikan.
    var timeoutMinutes: Int {
        get { d.object(forKey: "lock.timeout") as? Int ?? 5 }
        set { d.set(newValue, forKey: "lock.timeout") }
    }
    var useBiometrics: Bool {
        get { d.object(forKey: "lock.biometrics") as? Bool ?? true }
        set { d.set(newValue, forKey: "lock.biometrics") }
    }
    var lockOnSleep: Bool {
        get { d.object(forKey: "lock.onSleep") as? Bool ?? true }
        set { d.set(newValue, forKey: "lock.onSleep") }
    }

    static var biometricsAvailable: Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    func setSecret(_ value: String) {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let rounds: UInt32 = 200_000
        let s = Secret(salt: salt, hash: Self.derive(value, salt: salt, rounds: rounds), rounds: rounds,
                       isPIN: value.allSatisfy(\.isNumber))
        secret = s
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    func removeSecret() {
        secret = nil
        enabled = false
        try? FileManager.default.removeItem(at: file)
    }

    func verify(_ value: String) -> Bool {
        guard let s = secret else { return true }
        let h = Self.derive(value, salt: s.salt, rounds: s.rounds)
        // perbandingan waktu-konstan
        guard h.count == s.hash.count else { return false }
        return zip(h, s.hash).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func derive(_ value: String, salt: Data, rounds: UInt32) -> Data {
        let pw = Array(value.utf8).map { Int8(bitPattern: $0) }
        var out = Data(count: 32)
        out.withUnsafeMutableBytes { o in
            salt.withUnsafeBytes { s in
                _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count,
                                         s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                                         o.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return out
    }

    /// Minta Touch ID. `done(true)` jika berhasil.
    private var authenticating = false
    func authenticateWithBiometrics(_ done: @escaping (Bool) -> Void) {
        guard !authenticating, useBiometrics, Self.biometricsAvailable else { done(false); return }
        authenticating = true
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Pakai PIN/Password"
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "membuka WhatsApp") { ok, _ in
            DispatchQueue.main.async {
                self.authenticating = false
                done(ok)
            }
        }
    }
}

// MARK: - Overlay terkunci

final class LockOverlayView: NSView {
    var onSubmit: ((String) -> Void)?
    var onBiometrics: (() -> Void)?

    private let blur = NSVisualEffectView()
    private let dim = NSView()
    private let card = NSVisualEffectView()
    let field = NSSecureTextField()
    private let error = NSTextField(labelWithString: "")
    private let bioButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        // Latar: blur isi WhatsApp di belakangnya + sedikit gelap.
        blur.blendingMode = .withinWindow
        blur.material = .fullScreenUI
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        blur.frame = bounds
        addSubview(blur)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        dim.autoresizingMask = [.width, .height]
        dim.frame = bounds
        addSubview(dim)

        // Kartu dialog
        card.material = .popover
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.masksToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let icon = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 34, weight: .regular))!)
        icon.contentTintColor = NSColor(srgbRed: 0.145, green: 0.827, blue: 0.4, alpha: 1)

        let title = NSTextField(labelWithString: "WhatsApp Terkunci")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let subtitle = NSTextField(labelWithString: AppLock.shared.isPIN ? "Masukkan PIN untuk membuka" : "Masukkan password untuk membuka")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 12)

        field.placeholderString = AppLock.shared.isPIN ? "PIN" : "Password"
        field.alignment = .center
        field.font = .systemFont(ofSize: 15)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true

        error.textColor = .systemRed
        error.font = .systemFont(ofSize: 11)
        error.stringValue = " "

        let unlock = NSButton(title: "Buka", target: self, action: #selector(submit))
        unlock.keyEquivalent = "\r"
        unlock.bezelStyle = .rounded
        unlock.controlSize = .large
        unlock.translatesAutoresizingMaskIntoConstraints = false
        unlock.widthAnchor.constraint(equalToConstant: 220).isActive = true

        bioButton.title = " Gunakan Touch ID"
        bioButton.image = NSImage(systemSymbolName: "touchid", accessibilityDescription: nil)
        bioButton.imagePosition = .imageLeading
        bioButton.isBordered = false
        bioButton.contentTintColor = .controlAccentColor
        bioButton.target = self
        bioButton.action = #selector(biometrics)
        bioButton.isHidden = !(AppLock.shared.useBiometrics && AppLock.biometricsAvailable)

        let stack = NSStackView(views: [icon, title, subtitle, field, error, unlock, bioButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(16, after: subtitle)
        stack.setCustomSpacing(2, after: field)
        stack.setCustomSpacing(6, after: error)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 300),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    // Tangkap semua klik & scroll agar WhatsApp di belakangnya tidak bisa disentuh.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) ?? self }
    override func mouseDown(with event: NSEvent) { focusField() }
    override func scrollWheel(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    func focusField() { window?.makeFirstResponder(field) }

    @objc private func submit() { onSubmit?(field.stringValue) }
    @objc private func biometrics() { onBiometrics?() }

    func showError(_ text: String) {
        error.stringValue = text
        field.stringValue = ""
        focusField()
        // goyangkan kartu
        guard let layer = card.layer else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [0, -10, 10, -8, 8, -4, 4, 0]
        a.duration = 0.4
        layer.add(a, forKey: "shake")
    }
}
