// WhatsApp Web launcher — native macOS app (AppKit + WKWebView, tanpa Electron/Chromium).
// Mendukung banyak profil; tiap profil punya penyimpanan (login, cookie, cache) sendiri.
import Cocoa
import WebKit
import UserNotifications

private let homeURL = URL(string: "https://web.whatsapp.com/")!
private let allowedHosts: Set<String> = ["web.whatsapp.com", "whatsapp.com", "www.whatsapp.com"]
private let appTitle = "WhatsappWeb"

// MARK: - Script yang disuntikkan ke halaman

/// Mengganti Notification API browser dengan jembatan ke notifikasi native macOS.
private let notificationShim = """
(function () {
  const post = (m) => { try { window.webkit.messageHandlers.wa.postMessage(m); } catch (e) {} };
  const live = new Map(); let seq = 0;
  class WANotification extends EventTarget {
    constructor(title, opts) {
      super(); opts = opts || {};
      this.title = String(title || ''); this.body = String(opts.body || ''); this.tag = opts.tag || '';
      this.data = opts.data; this.onclick = null; this.onclose = null; this.onshow = null; this.onerror = null;
      this._id = 'n' + (++seq); live.set(this._id, this);
      if (live.size > 50) live.delete(live.keys().next().value);
      post({ type: 'notify', id: this._id, title: this.title, body: this.body });
    }
    close() { post({ type: 'close', id: this._id }); live.delete(this._id); }
    static get permission() { return 'granted'; }
    static requestPermission(cb) { if (cb) cb('granted'); return Promise.resolve('granted'); }
  }
  window.Notification = WANotification;
  window.__waNotifClick = function (id) {
    const n = live.get(id); if (!n) return;
    const ev = new Event('click');
    try { if (typeof n.onclick === 'function') n.onclick(ev); n.dispatchEvent(ev); } catch (e) {}
  };
  if (window.ServiceWorkerRegistration) {
    ServiceWorkerRegistration.prototype.showNotification = function (title, opts) {
      new WANotification(title, opts); return Promise.resolve();
    };
  }
  if (navigator.permissions && navigator.permissions.query) {
    const q = navigator.permissions.query.bind(navigator.permissions);
    navigator.permissions.query = (d) => (d && d.name === 'notifications')
      ? Promise.resolve({ state: 'granted', onchange: null, addEventListener() {}, removeEventListener() {} })
      : q(d);
  }
})();
"""

/// Profil yang tidak sedang ditampilkan tetap berjalan penuh (tidak di-throttle WebKit),
/// tetapi WhatsApp diberi tahu bahwa halamannya tersembunyi, agar chat tidak ditandai "dibaca".
private let visibilityShim = """
(function () {
  const D = Document.prototype;
  const hidden = Object.getOwnPropertyDescriptor(D, 'hidden');
  const state = Object.getOwnPropertyDescriptor(D, 'visibilityState');
  const hasFocus = D.hasFocus;
  window.__waVisible = false;
  Object.defineProperty(D, 'hidden', { configurable: true, get() { return !window.__waVisible || hidden.get.call(this); } });
  Object.defineProperty(D, 'visibilityState', { configurable: true, get() { return (!window.__waVisible || hidden.get.call(this)) ? 'hidden' : state.get.call(this); } });
  D.hasFocus = function () { return window.__waVisible && hasFocus.call(this); };
  window.__waSetVisible = function (v) {
    if (window.__waVisible === v) return;
    window.__waVisible = v;
    document.dispatchEvent(new Event('visibilitychange'));
    window.dispatchEvent(new Event(v ? 'focus' : 'blur'));
  };
})();
"""

/// Pengelola ekstensi di halaman: menjalankan, menyalakan, dan mematikan ekstensi tanpa reload.
/// Ekstensi .js bisa mendaftarkan `__waExt.onToggle(function (on) { ... })` agar bisa dimatikan langsung.
private let extensionRuntime = """
window.__waExt = (function () {
  const on = {}, runs = {}, ran = {}, hooks = {};
  let current = null;
  function run(id) {
    if (ran[id] || !runs[id]) return;
    ran[id] = true; current = id;
    try { runs[id](); } catch (e) { console.error('[ekstensi ' + id + ']', e); }
    current = null;
  }
  return {
    init(states) { Object.assign(on, states); },
    define(id, fn) { runs[id] = fn; if (on[id]) run(id); },
    onToggle(cb) { if (current) hooks[current] = cb; },
    set(id, v) {
      on[id] = v;
      if (!runs[id]) return v ? 'reload' : 'ok';
      if (!ran[id]) { if (v) run(id); return 'ok'; }
      if (hooks[id]) { try { hooks[id](v); } catch (e) { console.error(e); } return 'ok'; }
      return v ? 'ok' : 'reload';
    }
  };
})();
"""

/// Mengambil foto profil WhatsApp milik akun ini (ikon "Profil" di bawah sidebar kiri).
private let profilePhotoGrabber = """
(function () {
  let last = '';
  const post = (m) => { try { window.webkit.messageHandlers.wa.postMessage(m); } catch (e) {} };
  async function tick() {
    const img = document.querySelector('[data-testid="navbar-footer-section"] img');
    const src = img && img.src;
    if (!src || src === last) return;
    last = src;
    try {
      const r = await fetch(src, { credentials: 'include' });
      if (!r.ok) throw new Error('http');
      const b = await r.blob();
      const data = await new Promise((ok) => { const f = new FileReader(); f.onload = () => ok(f.result); f.readAsDataURL(b); });
      post({ type: 'avatar', data: data });
    } catch (e) {
      if (/^https:/.test(src)) post({ type: 'avatar', url: src });
    }
  }
  setInterval(tick, 5000);
})();
"""

/// Membaca warna latar bagian atas halaman agar title bar menyatu dengan konten.
private let themeSampler = """
(function () {
  let last = '';
  const solid = (c) => c && c !== 'transparent' && !/rgba\\([^)]*,\\s*0\\)$/.test(c);
  function colorAt(x, y) {
    let el = document.elementFromPoint(x, y);
    while (el && el !== document.documentElement) {
      const c = getComputedStyle(el).backgroundColor;
      if (solid(c)) return c;
      el = el.parentElement;
    }
    const b = document.body && getComputedStyle(document.body).backgroundColor;
    return solid(b) ? b : '';
  }
  function tick() {
    if (document.hidden) return;
    const c = colorAt(Math.min(40, window.innerWidth / 2), 2);
    if (c && c !== last) {
      last = c;
      try { window.webkit.messageHandlers.wa.postMessage({ type: 'theme', color: c }); } catch (e) {}
    }
  }
  const start = () => {
    tick();
    new MutationObserver(tick).observe(document.documentElement, { attributes: true, subtree: true, attributeFilter: ['class', 'data-theme'] });
    setInterval(tick, 3000);
    document.addEventListener('visibilitychange', tick);
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
"""

// MARK: - Kunci WebCrypto (tanpa Keychain)

/// WebKit secara default menyimpan "master key" WebCrypto di Keychain, sehingga app yang
/// ditandatangani ad-hoc memicu permintaan password Keychain berulang kali.
/// Di sini app memberikan kunci itu sendiri dari file privat di Application Support.
enum WebCryptoKey {
    static let shared: Data = load()

    private static func load() -> Data {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhatsApp Web Launcher", isDirectory: true)
        let file = dir.appendingPathComponent("webcrypto.key")
        if let d = try? Data(contentsOf: file), d.count >= 16 { return d }

        // Sekali saja: ambil kunci lama dari Keychain agar login yang sudah ada tidak hilang.
        let key = migrateFromKeychain() ?? randomKey()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? key.write(to: file, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return key
    }

    private static func randomKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    private static func migrateFromKeychain() -> Data? {
        let account = "com.apple.WebKit.WebCrypto.master+\(Bundle.main.bundleIdentifier ?? "")"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let raw = out as? Data else { return nil }
        if let s = String(data: raw, encoding: .utf8), let d = Data(base64Encoded: s), d.count >= 16 { return d }
        return raw.count >= 16 ? raw : nil
    }
}

// MARK: - Ekstensi

/// Ekstensi = file .js atau .css yang disuntikkan ke WhatsApp Web.
/// Bawaan: di dalam app (Contents/Resources/Extensions). Buatan sendiri:
/// ~/Library/Application Support/WhatsApp Web Launcher/Extensions
struct Extension {
    let id: String
    let name: String
    let detail: String
    let script: String
    let builtIn: Bool
}

enum Extensions {
    private static let disabledKey = "extensions.disabled"

    static var userFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhatsApp Web Launcher/Extensions", isDirectory: true)
    }

    static func all() -> [Extension] {
        var list: [Extension] = []
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("Extensions") {
            list += load(from: dir, builtIn: true)
        }
        list += load(from: userFolder, builtIn: false)
        return list
    }

    private static func load(from dir: URL, builtIn: Bool) -> [Extension] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            let ext = url.pathExtension.lowercased()
            guard ext == "js" || ext == "css", let src = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let id = (builtIn ? "builtin:" : "user:") + url.lastPathComponent
            // Nama diambil dari baris pertama "// Ekstensi: Nama" atau "/* Ekstensi: Nama */", jika ada.
            var name = url.deletingPathExtension().lastPathComponent
            if let first = src.split(separator: "\n", maxSplits: 1).first,
               let r = first.range(of: "Ekstensi:") {
                let n = first[r.upperBound...].replacingOccurrences(of: "*/", with: "").trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { name = n }
            }
            // Keterangan = baris komentar berikutnya setelah nama.
            let detail = src.split(separator: "\n").dropFirst().prefix(3).map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { $0.hasPrefix("//") || $0.hasPrefix("/*") }.first.map {
                $0.replacingOccurrences(of: "//", with: "").replacingOccurrences(of: "/*", with: "")
                    .replacingOccurrences(of: "*/", with: "").trimmingCharacters(in: .whitespaces)
            } ?? ""
            let script: String
            if ext == "css" {
                let data = (try? JSONSerialization.data(withJSONObject: [src])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
                script = "const s=document.createElement('style');s.textContent=\(data)[0];(document.head||document.documentElement).appendChild(s);__waExt.onToggle(function(on){s.disabled=!on;});"
            } else {
                script = src
            }
            return Extension(id: id, name: name, detail: detail, script: script, builtIn: builtIn)
        }
    }

    static func isEnabled(_ e: Extension) -> Bool {
        !(UserDefaults.standard.stringArray(forKey: disabledKey) ?? []).contains(e.id)
    }

    static func setEnabled(_ e: Extension, _ on: Bool) {
        var set = Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? [])
        if on { set.remove(e.id) } else { set.insert(e.id) }
        UserDefaults.standard.set(Array(set), forKey: disabledKey)
    }
}

// MARK: - Profil

struct Profile: Codable, Equatable {
    var id: String          // "default" = profil bawaan (memakai data store default)
    var name: String
    var hue: Double         // warna avatar 0...1
}

final class ProfileStore {
    private let key = "profiles.v1", activeKey = "profiles.active"
    private(set) var profiles: [Profile]

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([Profile].self, from: data), !list.isEmpty {
            profiles = list
        } else {
            profiles = [Profile(id: "default", name: "Profil 1", hue: 0.40)]
        }
    }

    var activeID: String {
        get { UserDefaults.standard.string(forKey: activeKey).flatMap { id in profiles.contains { $0.id == id } ? id : nil } ?? profiles[0].id }
        set { UserDefaults.standard.set(newValue, forKey: activeKey) }
    }

    func profile(_ id: String) -> Profile? { profiles.first { $0.id == id } }

    @discardableResult
    func add(name: String) -> Profile {
        let used = Set(profiles.map { Int($0.hue * 12) })
        let slot = (0..<12).map { ($0 * 5) % 12 }.first { !used.contains($0) } ?? Int.random(in: 0..<12)
        let p = Profile(id: UUID().uuidString, name: name, hue: Double(slot) / 12)
        profiles.append(p); save(); return p
    }

    func rename(_ id: String, to name: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].name = name; save()
    }

    func remove(_ id: String) {
        profiles.removeAll { $0.id == id }; save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func dataStore(for p: Profile) -> WKWebsiteDataStore {
        if p.id != "default", let uuid = UUID(uuidString: p.id) { return WKWebsiteDataStore(forIdentifier: uuid) }
        return .default()
    }
}

/// Avatar bulat berisi inisial nama profil.
/// Foto profil WhatsApp per profil, disimpan di disk agar langsung tampil saat app dibuka.
enum AvatarCache {
    private static var images: [String: NSImage] = [:]
    private static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhatsApp Web Launcher/Avatars", isDirectory: true)
    }
    private static func file(_ id: String) -> URL { dir.appendingPathComponent("\(id).img") }

    static func image(for id: String) -> NSImage? {
        if let img = images[id] { return img }
        guard let img = NSImage(contentsOf: file(id)) else { return nil }
        images[id] = img
        return img
    }

    /// Simpan foto baru. Mengembalikan true jika fotonya berubah.
    @discardableResult
    static func store(_ data: Data, for id: String) -> Bool {
        guard let img = NSImage(data: data), img.isValid else { return false }
        if let old = try? Data(contentsOf: file(id)), old == data { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: file(id), options: .atomic)
        images[id] = img
        return true
    }

    static func remove(_ id: String) {
        images[id] = nil
        try? FileManager.default.removeItem(at: file(id))
    }
}

func avatarImage(for p: Profile, size: CGFloat, badge: Bool = false) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
        let circle = r.insetBy(dx: 0.5, dy: 0.5)
        if let photo = AvatarCache.image(for: p.id) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: circle).addClip()
            // isi lingkaran (aspect fill)
            let s = photo.size, scale = max(circle.width / max(s.width, 1), circle.height / max(s.height, 1))
            let w = s.width * scale, h = s.height * scale
            photo.draw(in: NSRect(x: circle.midX - w / 2, y: circle.midY - h / 2, width: w, height: h))
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        NSColor(calibratedHue: p.hue, saturation: 0.55, brightness: 0.78, alpha: 1).setFill()
        NSBezierPath(ovalIn: circle).fill()
        let words = p.name.split(separator: " ").prefix(2)
        let initials = (words.count > 1 ? words.map { String($0.prefix(1)) }.joined() : String(p.name.prefix(2))).uppercased()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * 0.40, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let s = NSAttributedString(string: initials, attributes: attrs)
        let ts = s.size()
        s.draw(at: NSPoint(x: r.midX - ts.width / 2, y: r.midY - ts.height / 2))
        if badge {
            let d = size * 0.34
            let dot = NSRect(x: r.maxX - d, y: r.maxY - d, width: d, height: d)
            NSColor(srgbRed: 0.15, green: 0.83, blue: 0.40, alpha: 1).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        return true
    }
}

// MARK: - Bar profil di title bar

private let waGreen = NSColor(srgbRed: 0.145, green: 0.827, blue: 0.400, alpha: 1)

/// Satu ikon profil di title bar: avatar, cincin hijau untuk profil aktif, dan badge pesan belum dibaca.
final class ProfileChip: NSButton {
    var profile: Profile { didSet { updateTip(); needsDisplay = true } }
    var unread = 0 { didSet { if unread != oldValue { updateTip(); needsDisplay = true } } }
    var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }

    init(profile: Profile) {
        self.profile = profile
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 30))
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 36).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        updateTip()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateTip() {
        toolTip = unread > 0 ? "\(profile.name) — \(unread) belum dibaca" : profile.name
        setAccessibilityLabel(toolTip)
    }

    override func draw(_ dirtyRect: NSRect) {
        let d: CGFloat = 24
        let circle = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        if isActive {
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: -2.5, dy: -2.5))
            ring.lineWidth = 2
            waGreen.setStroke()
            ring.stroke()
        }
        avatarImage(for: profile, size: d).draw(in: circle, from: .zero, operation: .sourceOver,
                                                fraction: isActive ? 1 : 0.7, respectFlipped: true, hints: nil)
        guard unread > 0 else { return }
        let text = unread > 99 ? "99+" : String(unread)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.white,
        ]
        let ts = (text as NSString).size(withAttributes: attrs)
        let h: CGFloat = 14, w = max(h, ts.width + 7)
        let x = min(circle.maxX - w / 2 - 1, bounds.maxX - w)
        let y = isFlipped ? bounds.minY : bounds.maxY - h
        let pill = NSRect(x: x, y: y, width: w, height: h)
        let path = NSBezierPath(roundedRect: pill, xRadius: h / 2, yRadius: h / 2)
        waGreen.setFill()
        path.fill()
        path.lineWidth = 1.5
        (window?.backgroundColor ?? .windowBackgroundColor).setStroke()
        path.stroke()
        (text as NSString).draw(at: NSPoint(x: pill.midX - ts.width / 2, y: pill.midY - ts.height / 2), withAttributes: attrs)
    }
}

// MARK: - Wadah halaman

/// Semua profil tetap berada di jendela (jadi terus berjalan & siap tampil tanpa loading).
/// Yang aktif mengisi jendela; sisanya diletakkan di luar area tampilan.
final class ProfileHostView: NSView {
    var active: NSView? { didSet { needsLayout = true } }
    let separator = NSView()
    /// Overlay kunci (selalu paling atas, menutupi semua profil).
    var overlay: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let overlay { addSubview(overlay, positioned: .above, relativeTo: nil) }
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        separator.wantsLayer = true
        addSubview(separator)
    }
    required init?(coder: NSCoder) { fatalError() }

    func add(_ v: NSView) {
        addSubview(v, positioned: .below, relativeTo: separator)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for v in subviews where v !== separator && v !== overlay {
            v.frame = v === active ? bounds : bounds.offsetBy(dx: bounds.width + 400, dy: 0)
        }
        overlay?.frame = bounds
        separator.frame = NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1)
    }
}

// MARK: - Sesi per profil (satu WKWebView per profil)

protocol SessionHost: AnyObject {
    var window: NSWindow! { get }
    func sessionDidChange(_ s: Session)
    func session(_ s: Session, notify id: String, title: String, body: String)
    func session(_ s: Session, avatar data: Data)
}

final class Session: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {
    let profileID: String
    let webView: WKWebView
    private(set) var unread = 0
    private(set) var themeColor: NSColor?
    /// Profil yang sedang ditampilkan. Profil lain tetap jalan di belakang.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            webView.evaluateJavaScript("window.__waSetVisible && window.__waSetVisible(\(isActive))")
            installScripts() // nilai awal untuk muat ulang berikutnya
        }
    }
    weak var host: SessionHost?
    private var titleObserver: NSKeyValueObservation?

    init(profile: Profile, host: SessionHost) {
        profileID = profile.id
        self.host = host
        let config = WKWebViewConfiguration()
        config.websiteDataStore = ProfileStore.dataStore(for: profile)
        config.applicationNameForUserAgent = "Version/18.5 Safari/605.1.15"
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        config.userContentController.add(WeakScriptHandler(self), name: "wa")
        installScripts()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground") // hindari kilatan putih saat memuat
        webView.autoresizingMask = [.width, .height]
        #if DEBUG
        webView.isInspectable = true
        #endif

        titleObserver = webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            guard let self else { return }
            // Judul halaman berbentuk "(3) WhatsApp" saat ada pesan belum dibaca.
            let t = wv.title ?? ""
            var n = 0
            if t.hasPrefix("("), let end = t.firstIndex(of: ")") {
                n = Int(t[t.index(after: t.startIndex)..<end]) ?? 0
            }
            if n != self.unread { self.unread = n; self.host?.sessionDidChange(self) }
        }
        webView.load(URLRequest(url: homeURL))
    }

    /// Pasang script inti + ekstensi yang aktif. Dipanggil ulang saat ekstensi diubah.
    func installScripts() {
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: notificationShim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: visibilityShim + "window.__waVisible = \(isActive);",
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: themeSampler, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: profilePhotoGrabber, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        // Semua ekstensi selalu disuntikkan; yang nonaktif tidak dijalankan sampai dinyalakan.
        // Dengan begitu ekstensi bisa dinyalakan/dimatikan tanpa memuat ulang halaman.
        let exts = Extensions.all()
        let states = exts.map { "\(Self.jsString($0.id)):\(Extensions.isEnabled($0))" }.joined(separator: ",")
        ucc.addUserScript(WKUserScript(source: extensionRuntime + "__waExt.init({\(states)});",
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        for ext in exts {
            let wrapped = "__waExt.define(\(Self.jsString(ext.id)), function () {\n\(ext.script)\n});"
            ucc.addUserScript(WKUserScript(source: wrapped, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
    }

    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(data.dropFirst().dropLast())
    }

    /// Nyalakan/matikan ekstensi di halaman yang sedang berjalan. Muat ulang hanya jika
    /// ekstensi tersebut tidak mendukung dimatikan langsung (ekstensi .js buatan sendiri).
    func setExtension(_ id: String, enabled: Bool) {
        installScripts() // keadaan awal yang benar untuk pemuatan berikutnya
        webView.evaluateJavaScript("window.__waExt ? __waExt.set(\(Self.jsString(id)), \(enabled)) : 'reload'") { [weak self] r, _ in
            if (r as? String) != "ok" { self?.webView.reload() }
        }
    }

    func teardown() {
        titleObserver = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "wa")
        webView.stopLoading()
        webView.removeFromSuperview()
    }

    func notificationClicked(_ id: String) {
        let data = (try? JSONSerialization.data(withJSONObject: [id])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        webView.evaluateJavaScript("window.__waNotifClick && window.__waNotifClick(\(data.dropFirst().dropLast()))")
    }

    // Pesan dari halaman
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "notify":
            guard let id = body["id"] as? String else { return }
            host?.session(self, notify: id, title: body["title"] as? String ?? "WhatsApp", body: body["body"] as? String ?? "")
        case "close":
            if let id = body["id"] as? String {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["\(profileID)|\(id)"])
            }
        case "avatar":
            if let s = body["data"] as? String, let comma = s.firstIndex(of: ","),
               let data = Data(base64Encoded: String(s[s.index(after: comma)...])) {
                host?.session(self, avatar: data)
            } else if let s = body["url"] as? String, let url = URL(string: s), url.scheme == "https" {
                URLSession.shared.dataTask(with: url) { data, resp, _ in
                    guard let data, (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
                    DispatchQueue.main.async { self.host?.session(self, avatar: data) }
                }.resume()
            }
        case "theme":
            if let css = body["color"] as? String, let c = Self.parseCSSColor(css) {
                themeColor = c; host?.sessionDidChange(self)
            }
        default: break
        }
    }

    private static func parseCSSColor(_ s: String) -> NSColor? {
        guard let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")") else { return nil }
        let parts = s[s.index(after: open)..<close].split(separator: ",").map {
            Double($0.trimmingCharacters(in: .whitespaces)) ?? 0
        }
        guard parts.count >= 3 else { return nil }
        return NSColor(srgbRed: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: 1)
    }

    // Delegate privat WebKit: berikan master key WebCrypto sendiri → Keychain tidak disentuh.
    @objc(_webCryptoMasterKeyForWebView:completionHandler:)
    func webCryptoMasterKey(for webView: WKWebView, completionHandler: @escaping (Data?) -> Void) {
        completionHandler(WebCryptoKey.shared)
    }

    @objc(_webCryptoMasterKeyForWebView:)
    func webCryptoMasterKey(for webView: WKWebView) -> Data? {
        WebCryptoKey.shared
    }

    // Navigasi — link luar dibuka di browser default
    private func isInternal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return true }
        if ["about", "blob", "data"].contains(scheme) { return true }
        guard let host = url.host?.lowercased() else { return true }
        return allowedHosts.contains(host)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { decisionHandler(.download); return }
        guard let url = action.request.url else { decisionHandler(.allow); return }
        if action.targetFrame?.isMainFrame != false, !isInternal(url) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if isInternal(url) { webView.load(action.request) } else { NSWorkspace.shared.open(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Alat pengembang: WA_EVAL_JS=<file.js> WA_EVAL_OUT=<file> → jalankan script & simpan hasilnya.
        let env = ProcessInfo.processInfo.environment
        guard isActive, let jsPath = env["WA_EVAL_JS"], let out = env["WA_EVAL_OUT"],
              let js = try? String(contentsOfFile: jsPath, encoding: .utf8) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { r in
                let text: String
                switch r {
                case .success(let v): text = (try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .fragmentsAllowed]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "\(v)"
                case .failure(let e): text = "ERROR: \(e)"
                }
                try? text.write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload() // pulih otomatis jika proses web crash
    }

    // Unduhan → ~/Downloads
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension
        var dest = dir.appendingPathComponent(suggestedFilename)
        var i = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)")
            i += 1
        }
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        NSApp.requestUserAttention(.informationalRequest)
    }

    // Upload file, kamera/mikrofon, dialog JS
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        if let w = host?.window { panel.beginSheetModal(for: w) { r in completionHandler(r == .OK ? panel.urls : nil) } }
        else { completionHandler(panel.runModal() == .OK ? panel.urls : nil) }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(allowedHosts.contains(origin.host) ? .grant : .deny)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = message
        a.runModal(); completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = message
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Batal")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate,
    NSMenuDelegate, UNUserNotificationCenterDelegate, SessionHost {

    var window: NSWindow!
    private let store = ProfileStore()
    private var sessions: [String: Session] = [:]
    private var activeID = ""
    private let profileBar = NSStackView()
    private var chips: [ProfileChip] = []
    private let addButton = NSButton()
    private let settingsButton = NSButton()
    private var settingsPanel: NSWindow?
    private(set) var isLocked = false
    private var lastActivity = Date()
    private var lockOverlay: LockOverlayView?
    private let host = ProfileHostView()
    private let profileMainMenu = NSMenu(title: "Profil")
    private let extensionsMenu = NSMenu(title: "Ekstensi")
    private static let profileItemID = NSToolbarItem.Identifier("profile")

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        installDoubleClickToZoom()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        switchTo(store.activeID)
        // Semua profil langsung dimuat, jadi berpindah profil tidak perlu loading lagi.
        for p in store.profiles where sessions[p.id] == nil { _ = session(for: p.id) }
        refreshChrome()
        installLockMonitors()
        if AppLock.shared.enabled { lock() } // terkunci sejak app dibuka
        NSApp.activate(ignoringOtherApps: true)
    }

    // Tutup jendela = sembunyikan (sesi tetap hidup & notifikasi tetap masuk).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Window & title bar

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "WhatsApp"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true   // title bar memakai warna jendela → menyatu
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.11, green: 0.12, blue: 0.12, alpha: 1)
                : NSColor(srgbRed: 0.97, green: 0.96, blue: 0.95, alpha: 1)
        }
        window.minSize = NSSize(width: 640, height: 480)
        window.delegate = self
        window.tabbingMode = .disallowed
        window.contentView = host

        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        profileBar.orientation = .horizontal
        profileBar.spacing = 2
        profileBar.translatesAutoresizingMaskIntoConstraints = false
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Tambah profil")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        addButton.isBordered = false
        addButton.bezelStyle = .regularSquare
        addButton.imagePosition = .imageOnly
        addButton.contentTintColor = .secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(addProfile)
        addButton.toolTip = "Tambah profil"
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        addButton.heightAnchor.constraint(equalToConstant: 26).isActive = true

        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Pengaturan")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        settingsButton.isBordered = false
        settingsButton.bezelStyle = .regularSquare
        settingsButton.imagePosition = .imageOnly
        settingsButton.contentTintColor = .secondaryLabelColor
        settingsButton.target = self
        settingsButton.action = #selector(showSettings)
        settingsButton.toolTip = "Pengaturan"
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        settingsButton.heightAnchor.constraint(equalToConstant: 26).isActive = true

        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.profileItemID]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.profileItemID]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == Self.profileItemID else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Profil"
        item.view = profileBar
        item.isBordered = false
        return item
    }

    /// Klik dua kali di title bar → maximize (atau minimize, mengikuti pengaturan sistem).
    private func installDoubleClickToZoom() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            guard let self, let w = e.window, w === self.window, e.clickCount == 2 else { return e }
            let p = e.locationInWindow
            guard p.y >= w.contentLayoutRect.maxY else { return e }
            if let frameView = w.contentView?.superview,
               let hit = frameView.hitTest(frameView.convert(p, from: nil)), hit is NSControl {
                return e // klik pada tombol (lampu lalu lintas / profil)
            }
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": w.miniaturize(nil)
            case "None": break
            default: w.zoom(nil)
            }
            return nil
        }
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        window.screen?.visibleFrame ?? newFrame // maximize = isi seluruh area layar (tanpa full screen)
    }

    // MARK: Profil

    private func session(for id: String) -> Session? {
        if let s = sessions[id] { return s }
        guard let p = store.profile(id) else { return nil }
        let s = Session(profile: p, host: self)
        sessions[id] = s
        host.add(s.webView)
        return s
    }

    private func switchTo(_ id: String) {
        guard let s = session(for: id) else { return }
        if activeID != id { sessions[activeID]?.isActive = false }
        activeID = id
        store.activeID = id
        s.isActive = true
        host.active = s.webView
        host.layoutSubtreeIfNeeded()
        window.makeFirstResponder(s.webView)
        refreshChrome()
    }

    /// Perbarui judul, avatar, warna title bar, dan badge Dock.
    private func refreshChrome() {
        guard let p = store.profile(activeID) else { return }
        window.title = "WhatsApp - \(p.name)"
        updateProfileBar()

        if let c = sessions[activeID]?.themeColor {
            window.backgroundColor = c
            let rgb = c.usingColorSpace(.sRGB) ?? c
            let lum = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
            window.appearance = NSAppearance(named: lum < 0.5 ? .darkAqua : .aqua)
        }
        let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        host.separator.layer?.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.08)).cgColor

        if settingsPanel != nil { refreshSettingsIfNeeded() }
        let total = sessions.values.reduce(0) { $0 + $1.unread }
        NSApp.dockTile.badgeLabel = total > 0 ? String(total) : nil
    }

    func sessionDidChange(_ s: Session) { refreshChrome() }

    /// Ikon profil berbaris di title bar. Dibuat ulang hanya jika daftar profil berubah.
    private func updateProfileBar() {
        if chips.map({ $0.profile }) != store.profiles {
            profileBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
            chips = store.profiles.map { p in
                let chip = ProfileChip(profile: p)
                chip.target = self
                chip.action = #selector(chipClicked(_:))
                let menu = NSMenu()
                let rename = NSMenuItem(title: "Ganti Nama…", action: #selector(renameProfile(_:)), keyEquivalent: "")
                rename.target = self; rename.representedObject = p.id
                let del = NSMenuItem(title: "Hapus Profil…", action: #selector(deleteProfile(_:)), keyEquivalent: "")
                del.target = self; del.representedObject = p.id
                menu.addItem(rename); menu.addItem(del)
                chip.menu = menu   // klik kanan
                profileBar.addArrangedSubview(chip)
                return chip
            }
            profileBar.addArrangedSubview(addButton)
            profileBar.addArrangedSubview(settingsButton)
            profileBar.setCustomSpacing(6, after: addButton)
        }
        for chip in chips {
            chip.isActive = chip.profile.id == activeID
            chip.unread = sessions[chip.profile.id]?.unread ?? 0
            chip.needsDisplay = true
        }
    }

    func session(_ s: Session, avatar data: Data) {
        if AvatarCache.store(data, for: s.profileID) { chips.forEach { $0.needsDisplay = true } }
    }

    /// Klik profil lain → pindah. Klik profil yang sedang aktif → menu ganti nama / hapus.
    @objc private func chipClicked(_ sender: ProfileChip) {
        guard !isLocked else { return }
        if sender.profile.id != activeID {
            switchTo(sender.profile.id)
        } else if let menu = sender.menu {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === profileMainMenu { populate(menu, forMainMenu: true) }
        if menu === extensionsMenu { populateExtensions(menu) }
    }

    // MARK: Ekstensi

    private func populateExtensions(_ menu: NSMenu) {
        menu.removeAllItems()
        let list = Extensions.all()
        if list.isEmpty {
            let none = NSMenuItem(title: "Belum ada ekstensi", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        var lastBuiltIn = true
        for e in list {
            if lastBuiltIn && !e.builtIn { menu.addItem(.separator()); lastBuiltIn = false }
            let item = NSMenuItem(title: e.name, action: #selector(toggleExtension(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = e.id
            item.state = Extensions.isEnabled(e) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Buka Folder Ekstensi…", #selector(openExtensionsFolder)))
        menu.addItem(actionItem("Muat Ulang Ekstensi", #selector(reloadExtensions), "r", [.command, .shift]))
    }

    @objc private func toggleExtension(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let e = Extensions.all().first(where: { $0.id == id }) else { return }
        let on = !Extensions.isEnabled(e)
        Extensions.setEnabled(e, on)
        sessions.values.forEach { $0.setExtension(e.id, enabled: on) }
    }

    @objc private func openExtensionsFolder() {
        let dir = Extensions.userFolder
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    /// Terapkan ulang ekstensi ke semua profil yang sedang terbuka.
    @objc private func reloadExtensions() {
        for s in sessions.values {
            s.installScripts()
            s.webView.reload()
        }
    }

    private func populate(_ menu: NSMenu, forMainMenu: Bool) {
        menu.removeAllItems()
        if !forMainMenu {
            let header = NSMenuItem(title: "Profil WhatsApp", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }
        for (i, p) in store.profiles.enumerated() {
            let unread = sessions[p.id]?.unread ?? 0
            let item = NSMenuItem(title: p.name, action: #selector(selectProfile(_:)), keyEquivalent: i < 9 ? "\(i + 1)" : "")
            item.keyEquivalentModifierMask = [.command, .option]
            item.target = self
            item.representedObject = p.id
            item.image = avatarImage(for: p, size: 18)
            item.state = p.id == activeID ? .on : .off
            if unread > 0 { item.badge = NSMenuItemBadge(count: unread) }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Tambah Profil…", #selector(addProfile), "n", [.command, .shift]))
        menu.addItem(actionItem("Ganti Nama Profil…", #selector(renameProfile(_:))))
        let del = actionItem("Hapus Profil…", #selector(deleteProfile(_:)))
        del.isEnabled = store.profiles.count > 1
        menu.addItem(del)
    }

    private func actionItem(_ title: String, _ sel: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = self
        return item
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard !isLocked else { return }
        if let id = sender.representedObject as? String, id != activeID { switchTo(id) }
    }

    @objc private func addProfile() {
        guard let name = ask(title: "Tambah Profil", message: "Nama profil baru (misalnya: Kerja, Pribadi).",
                             value: "Profil \(store.profiles.count + 1)", button: "Tambah") else { return }
        switchTo(store.add(name: name).id)
    }

    @objc private func renameProfile(_ sender: Any?) {
        let id = (sender as? NSMenuItem)?.representedObject as? String ?? activeID
        guard let p = store.profile(id),
              let name = ask(title: "Ganti Nama Profil", message: "Nama baru untuk profil \"\(p.name)\".",
                             value: p.name, button: "Simpan") else { return }
        store.rename(p.id, to: name)
        refreshChrome()
    }

    @objc private func deleteProfile(_ sender: Any?) {
        let id = (sender as? NSMenuItem)?.representedObject as? String ?? activeID
        guard store.profiles.count > 1, let p = store.profile(id) else { return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Hapus profil \"\(p.name)\"?"
        a.informativeText = "Login WhatsApp dan semua data profil ini di aplikasi akan dihapus. Chat di HP tidak terpengaruh."
        a.addButton(withTitle: "Hapus")
        a.addButton(withTitle: "Batal")
        a.buttons[0].hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }

        sessions.removeValue(forKey: p.id)?.teardown()
        store.remove(p.id)
        AvatarCache.remove(p.id)
        if p.id == activeID || store.profile(activeID) == nil { switchTo(store.profiles[0].id) } else { refreshChrome() }
        if p.id == "default" {
            let ds = WKWebsiteDataStore.default()
            ds.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        } else if let uuid = UUID(uuidString: p.id) {
            // Beri waktu proses web milik profil ini berhenti sebelum datanya dihapus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                WKWebsiteDataStore.remove(forIdentifier: uuid) { _ in }
            }
        }
    }

    private func ask(title: String, message: String, value: String, button: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Batal")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = value
        a.accessoryView = field
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    // MARK: Notifikasi native

    func session(_ s: Session, notify id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        // Saat terkunci, isi pesan tidak ditampilkan di notifikasi.
        content.title = isLocked ? "WhatsApp" : title
        content.body = isLocked ? "Pesan baru" : body
        if store.profiles.count > 1, let p = store.profile(s.profileID) { content.subtitle = p.name }
        content.sound = .default
        content.userInfo = ["profile": s.profileID, "id": id]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "\(s.profileID)|\(id)", content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Jangan ganggu kalau profil itu sedang tampil di depan.
        let pid = notification.request.content.userInfo["profile"] as? String
        let inFront = NSApp.isActive && window.isKeyWindow && pid == activeID
        completionHandler(inFront ? [] : [.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let pid = info["profile"] as? String, nid = info["id"] as? String
        DispatchQueue.main.async {
            if let pid, pid != self.activeID { self.switchTo(pid) }
            self.showWindow()
            if let nid { self.sessions[self.activeID]?.notificationClicked(nid) }
        }
        completionHandler()
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appTitle)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let prefs = appMenu.addItem(withTitle: "Pengaturan…", action: #selector(showSettings), keyEquivalent: ",")
        prefs.target = self
        let lockItem = appMenu.addItem(withTitle: "Kunci Sekarang", action: #selector(lockNow), keyEquivalent: "l")
        lockItem.keyEquivalentModifierMask = [.command, .control]
        lockItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appTitle)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appTitle)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: appTitle)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: "Edit")

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r")
        view.addItem(.separator())
        view.addItem(withTitle: "Actual Size", action: #selector(zoomReset), keyEquivalent: "0")
        view.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "=")
        view.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        view.addItem(.separator())
        let fs = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        main.addItem(submenu: view, title: "View")

        profileMainMenu.delegate = self
        main.addItem(submenu: profileMainMenu, title: "Profil")

        extensionsMenu.delegate = self
        main.addItem(submenu: extensionsMenu, title: "Ekstensi")

        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(.separator())
        win.addItem(withTitle: appTitle, action: #selector(showMain), keyEquivalent: "1")
        main.addItem(submenu: win, title: "Window")
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }

    private var activeWebView: WKWebView? { sessions[activeID]?.webView }
    @objc private func reload() { activeWebView?.reload() }
    @objc private func showMain() { showWindow() }
    @objc private func zoomReset() { setZoom(1) }
    @objc private func zoomIn() { setZoom((activeWebView?.pageZoom ?? 1) + 0.1) }
    @objc private func zoomOut() { setZoom((activeWebView?.pageZoom ?? 1) - 0.1) }
    private func setZoom(_ z: CGFloat) { activeWebView?.pageZoom = min(max(z, 0.5), 2.0) }
}

// MARK: - Dialog Pengaturan (Profil & Ekstensi)

extension AppDelegate {
    @objc func showSettings() {
        guard !isLocked else { showWindow(); return }
        if let panel = settingsPanel { panel.makeKeyAndOrderFront(nil); return }
        showWindow()
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                             styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Pengaturan"
        settingsPanel = panel
        buildSettingsContent()
        window.beginSheet(panel) { [weak self] _ in self?.settingsPanel = nil }
    }

    @objc private func closeSettings() {
        guard let panel = settingsPanel else { return }
        panel.makeFirstResponder(nil) // simpan nama yang sedang diedit
        window.endSheet(panel)
    }

    private var settingsTabIndex: Int {
        get { UserDefaults.standard.integer(forKey: "settings.tab") }
        set { UserDefaults.standard.set(newValue, forKey: "settings.tab") }
    }

    /// Bangun ulang isi dialog, kecuali saat pengguna sedang mengetik nama.
    fileprivate func refreshSettingsIfNeeded() {
        guard let panel = settingsPanel else { return }
        if panel.firstResponder is NSTextView { return }
        buildSettingsContent()
    }

    fileprivate func buildSettingsContent() {
        guard let panel = settingsPanel else { return }
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let profileTab = NSTabViewItem(identifier: "profiles")
        profileTab.label = "Profil"
        profileTab.view = profileSettingsView()
        let extTab = NSTabViewItem(identifier: "extensions")
        extTab.label = "Ekstensi"
        extTab.view = extensionSettingsView()
        tabs.addTabViewItem(profileTab)
        tabs.addTabViewItem(extTab)
        let lockTab = NSTabViewItem(identifier: "lock")
        lockTab.label = "Kunci"
        lockTab.view = lockSettingsView()
        tabs.addTabViewItem(lockTab)
        tabs.selectTabViewItem(at: min(settingsTabIndex, 2))
        tabs.delegate = self

        let done = NSButton(title: "Selesai", target: self, action: #selector(closeSettings))
        done.keyEquivalent = "\r"
        done.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(tabs)
        root.addSubview(done)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            done.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 12),
            done.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            done.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            done.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])
        panel.contentView = root
        panel.setContentSize(NSSize(width: 560, height: 420))
    }

    // Tab Profil
    private func profileSettingsView() -> NSView {
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10

        for p in store.profiles {
            let avatar = NSImageView(image: avatarImage(for: p, size: 32))
            avatar.translatesAutoresizingMaskIntoConstraints = false
            avatar.widthAnchor.constraint(equalToConstant: 32).isActive = true
            avatar.heightAnchor.constraint(equalToConstant: 32).isActive = true

            let name = NSTextField(string: p.name)
            name.identifier = NSUserInterfaceItemIdentifier(p.id)
            name.target = self
            name.action = #selector(profileNameEdited(_:))
            name.placeholderString = "Nama profil"
            name.translatesAutoresizingMaskIntoConstraints = false
            name.widthAnchor.constraint(equalToConstant: 170).isActive = true

            let unread = sessions[p.id]?.unread ?? 0
            var info = p.id == activeID ? "Sedang dibuka" : ""
            if unread > 0 { info += (info.isEmpty ? "" : " · ") + "\(unread) belum dibaca" }
            let status = NSTextField(labelWithString: info)
            status.textColor = .secondaryLabelColor
            status.font = .systemFont(ofSize: 11)
            status.translatesAutoresizingMaskIntoConstraints = false
            status.widthAnchor.constraint(equalToConstant: 175).isActive = true

            let open = NSButton(title: "Buka", target: self, action: #selector(settingsOpenProfile(_:)))
            open.identifier = NSUserInterfaceItemIdentifier(p.id)
            open.isEnabled = p.id != activeID
            open.bezelStyle = .rounded

            let del = NSButton(title: "Hapus", target: self, action: #selector(settingsDeleteProfile(_:)))
            del.identifier = NSUserInterfaceItemIdentifier(p.id)
            del.isEnabled = store.profiles.count > 1
            del.hasDestructiveAction = true
            del.bezelStyle = .rounded

            let row = NSStackView(views: [avatar, name, status, open, del])
            row.orientation = .horizontal
            row.spacing = 10
            row.alignment = .centerY
            list.addArrangedSubview(row)
        }

        let add = NSButton(title: "Tambah Profil…", target: self, action: #selector(addProfile))
        add.bezelStyle = .rounded
        let hint = NSTextField(wrappingLabelWithString: "Tiap profil punya login WhatsApp sendiri. Foto diambil otomatis dari WhatsApp. Ganti nama lalu tekan Enter untuk menyimpan.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        return settingsPage(content: list, footer: [add], hint: hint)
    }

    // Tab Ekstensi
    private func extensionSettingsView() -> NSView {
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 12
        let exts = Extensions.all()
        if exts.isEmpty {
            list.addArrangedSubview(NSTextField(labelWithString: "Belum ada ekstensi."))
        }
        for e in exts {
            let box = NSButton(checkboxWithTitle: e.name + (e.builtIn ? "" : "  (buatan sendiri)"),
                               target: self, action: #selector(settingsToggleExtension(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(e.id)
            box.state = Extensions.isEnabled(e) ? .on : .off
            let col = NSStackView(views: [box])
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 2
            if !e.detail.isEmpty {
                let d = NSTextField(wrappingLabelWithString: e.detail)
                d.textColor = .secondaryLabelColor
                d.font = .systemFont(ofSize: 11)
                d.translatesAutoresizingMaskIntoConstraints = false
                d.widthAnchor.constraint(equalToConstant: 440).isActive = true
                let indent = NSStackView(views: [d])
                indent.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
                col.addArrangedSubview(indent)
            }
            list.addArrangedSubview(col)
        }
        let folder = NSButton(title: "Buka Folder Ekstensi…", target: self, action: #selector(openExtensionsFolder))
        folder.bezelStyle = .rounded
        let reload = NSButton(title: "Muat Ulang", target: self, action: #selector(settingsReloadExtensions))
        reload.bezelStyle = .rounded
        let hint = NSTextField(wrappingLabelWithString: "Ekstensi buatan sendiri: taruh file .js atau .css di folder ekstensi, lalu klik Muat Ulang. Perubahan langsung berlaku untuk semua profil.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        return settingsPage(content: list, footer: [folder, reload], hint: hint)
    }

    /// Halaman tab: daftar yang bisa di-scroll + tombol di bawah.
    private func settingsPage(content: NSStackView, footer: [NSView], hint: NSTextField) -> NSView {
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: doc.topAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -8),
            content.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -8),
        ])
        let scroll = NSScrollView()
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        let buttons = NSStackView(views: footer)
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        hint.translatesAutoresizingMaskIntoConstraints = false

        let page = NSView()
        page.addSubview(scroll)
        page.addSubview(hint)
        page.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: page.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -8),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -16),
            buttons.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 14),
            buttons.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -12),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        return page
    }

    @objc private func profileNameEdited(_ sender: NSTextField) {
        guard let id = sender.identifier?.rawValue else { return }
        let name = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, store.profile(id)?.name != name else { return }
        store.rename(id, to: name)
        refreshChrome()
    }

    @objc private func settingsOpenProfile(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        switchTo(id)
        buildSettingsContent()
    }

    @objc private func settingsDeleteProfile(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let item = NSMenuItem()
        item.representedObject = id
        deleteProfile(item)
        buildSettingsContent()
    }

    @objc private func settingsToggleExtension(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let e = Extensions.all().first(where: { $0.id == id }) else { return }
        Extensions.setEnabled(e, sender.state == .on)
        sessions.values.forEach { $0.setExtension(e.id, enabled: sender.state == .on) }
    }

    @objc private func settingsReloadExtensions() {
        reloadExtensions()
        buildSettingsContent()
    }
}

// MARK: - Kunci aplikasi

extension AppDelegate {
    fileprivate func installLockMonitors() {
        window.acceptsMouseMovedEvents = true
        // Catat aktivitas pengguna di dalam app.
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .mouseMoved]) { [weak self] e in
            if let self, !self.isLocked { self.lastActivity = Date() }
            return e
        }
        // Periksa batas waktu tidak aktif.
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, !self.isLocked else { return }
            let lock = AppLock.shared
            guard lock.enabled, lock.timeoutMinutes > 0 else { return }
            if Date().timeIntervalSince(self.lastActivity) >= Double(lock.timeoutMinutes * 60) { self.lock() }
        }
        // Kunci saat Mac tidur atau layar dikunci.
        let sleepLock: (Notification) -> Void = { [weak self] _ in
            if AppLock.shared.enabled, AppLock.shared.lockOnSleep { self?.lock() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: sleepLock)
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: sleepLock)
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: sleepLock)
        // Mode "0 menit": kunci setiap kali app ditinggalkan.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if AppLock.shared.enabled, AppLock.shared.timeoutMinutes == 0 { self?.lock() }
        }
        // Tawarkan Touch ID saat kembali ke app yang terkunci.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isLocked, self.window.isVisible else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.tryBiometricUnlock() }
        }
    }

    @objc func lockNow() {
        if AppLock.shared.hasSecret { lock() } else {
            settingsTabIndex = 2
            showSettings()
        }
    }

    func lock() {
        guard !isLocked, AppLock.shared.hasSecret else { return }
        if let panel = settingsPanel { window.endSheet(panel) }
        isLocked = true
        let overlay = LockOverlayView(frame: host.bounds)
        overlay.onSubmit = { [weak self] value in self?.attemptUnlock(value) }
        overlay.onBiometrics = { [weak self] in self?.tryBiometricUnlock() }
        lockOverlay = overlay
        host.overlay = overlay
        host.layoutSubtreeIfNeeded()
        overlay.focusField()
        profileBar.alphaValue = 0.4
        if NSApp.isActive && window.isVisible {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.tryBiometricUnlock() }
        }
    }

    private func attemptUnlock(_ value: String) {
        guard !value.isEmpty else { lockOverlay?.showError(" "); return }
        if AppLock.shared.verify(value) { unlock() }
        else { lockOverlay?.showError(AppLock.shared.isPIN ? "PIN salah" : "Password salah") }
    }

    private func tryBiometricUnlock() {
        guard isLocked, NSApp.isActive else { return }
        AppLock.shared.authenticateWithBiometrics { [weak self] ok in
            if ok { self?.unlock() } else { self?.lockOverlay?.focusField() }
        }
    }

    private func unlock() {
        isLocked = false
        lastActivity = Date()
        host.overlay = nil
        lockOverlay = nil
        profileBar.alphaValue = 1
        if let wv = sessions[activeID]?.webView { window.makeFirstResponder(wv) }
    }

    // Tab "Kunci" di Pengaturan
    fileprivate func lockSettingsView() -> NSView {
        let lock = AppLock.shared
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 12

        let status = NSTextField(labelWithString: lock.hasSecret
            ? "\(lock.isPIN ? "PIN" : "Password") sudah diatur."
            : "Atur PIN atau password terlebih dahulu untuk memakai kunci.")
        status.font = .systemFont(ofSize: 12, weight: .medium)
        list.addArrangedSubview(status)

        let enable = NSButton(checkboxWithTitle: "Kunci WhatsApp otomatis", target: self, action: #selector(lockToggleEnabled(_:)))
        enable.state = lock.enabled ? .on : .off
        enable.isEnabled = lock.hasSecret
        list.addArrangedSubview(enable)

        let timeout = NSPopUpButton()
        let options: [(String, Int)] = [("Setiap kali app ditinggalkan", 0), ("1 menit", 1), ("5 menit", 5),
                                         ("15 menit", 15), ("30 menit", 30), ("1 jam", 60), ("4 jam", 240)]
        for (title, m) in options {
            timeout.addItem(withTitle: title)
            timeout.lastItem?.tag = m
        }
        timeout.selectItem(withTag: lock.timeoutMinutes)
        timeout.target = self
        timeout.action = #selector(lockTimeoutChanged(_:))
        timeout.isEnabled = lock.hasSecret
        let timeoutRow = NSStackView(views: [NSTextField(labelWithString: "Kunci setelah tidak aktif:"), timeout])
        timeoutRow.spacing = 8
        timeoutRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        list.addArrangedSubview(timeoutRow)

        let bio = NSButton(checkboxWithTitle: "Buka dengan Touch ID", target: self, action: #selector(lockToggleBiometrics(_:)))
        bio.state = lock.useBiometrics ? .on : .off
        bio.isEnabled = lock.hasSecret && AppLock.biometricsAvailable
        if !AppLock.biometricsAvailable { bio.title += " (tidak tersedia di Mac ini)" }
        let sleep = NSButton(checkboxWithTitle: "Kunci saat Mac tidur atau layar dikunci", target: self, action: #selector(lockToggleSleep(_:)))
        sleep.state = lock.lockOnSleep ? .on : .off
        sleep.isEnabled = lock.hasSecret
        for b in [bio, sleep] {
            let row = NSStackView(views: [b])
            row.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
            list.addArrangedSubview(row)
        }

        let set = NSButton(title: lock.hasSecret ? "Ubah PIN/Password…" : "Atur PIN/Password…", target: self, action: #selector(lockSetSecret))
        set.bezelStyle = .rounded
        var footer: [NSView] = [set]
        if lock.hasSecret {
            let remove = NSButton(title: "Hapus PIN/Password…", target: self, action: #selector(lockRemoveSecret))
            remove.bezelStyle = .rounded
            let now = NSButton(title: "Kunci Sekarang", target: self, action: #selector(lockNow))
            now.bezelStyle = .rounded
            footer += [remove, now]
        }
        let hint = NSTextField(wrappingLabelWithString: "Saat terkunci, WhatsApp diburamkan dan isi pesan disembunyikan dari notifikasi. PIN/password disimpan sebagai hash di Mac ini, tidak di Keychain. Pintasan: ⌃⌘L untuk mengunci.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        return settingsPage(content: list, footer: footer, hint: hint)
    }

    @objc private func lockToggleEnabled(_ sender: NSButton) {
        AppLock.shared.enabled = sender.state == .on
        lastActivity = Date()
    }
    @objc private func lockTimeoutChanged(_ sender: NSPopUpButton) {
        AppLock.shared.timeoutMinutes = sender.selectedTag()
        lastActivity = Date()
    }
    @objc private func lockToggleBiometrics(_ sender: NSButton) { AppLock.shared.useBiometrics = sender.state == .on }
    @objc private func lockToggleSleep(_ sender: NSButton) { AppLock.shared.lockOnSleep = sender.state == .on }

    /// Dialog atur/ubah PIN atau password.
    @objc private func lockSetSecret() {
        let lock = AppLock.shared
        let a = NSAlert()
        a.messageText = lock.hasSecret ? "Ubah PIN/Password" : "Atur PIN/Password"
        a.informativeText = "Gunakan PIN (angka) atau password, minimal 4 karakter."
        a.addButton(withTitle: "Simpan")
        a.addButton(withTitle: "Batal")
        let current = NSSecureTextField(), new = NSSecureTextField(), again = NSSecureTextField()
        current.placeholderString = "PIN/password saat ini"
        new.placeholderString = "PIN/password baru"
        again.placeholderString = "Ulangi PIN/password baru"
        let fields = (lock.hasSecret ? [current] : []) + [new, again]
        let stack = NSStackView(views: fields)
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 240, height: CGFloat(fields.count) * 30)
        fields.forEach { $0.widthAnchor.constraint(equalToConstant: 240).isActive = true }
        a.accessoryView = stack
        a.window.initialFirstResponder = fields[0]
        guard a.runModal() == .alertFirstButtonReturn else { return }

        if lock.hasSecret && !lock.verify(current.stringValue) {
            return showLockMessage("PIN/password saat ini salah.")
        }
        guard new.stringValue.count >= 4 else { return showLockMessage("Minimal 4 karakter.") }
        guard new.stringValue == again.stringValue else { return showLockMessage("PIN/password baru tidak sama.") }
        let first = !lock.hasSecret
        lock.setSecret(new.stringValue)
        if first { lock.enabled = true }
        lastActivity = Date()
        buildSettingsContent()
    }

    @objc private func lockRemoveSecret() {
        let a = NSAlert()
        a.messageText = "Hapus PIN/Password?"
        a.informativeText = "Kunci WhatsApp akan dimatikan."
        a.addButton(withTitle: "Hapus")
        a.addButton(withTitle: "Batal")
        a.buttons[0].hasDestructiveAction = true
        let current = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        current.placeholderString = "PIN/password saat ini"
        a.accessoryView = current
        a.window.initialFirstResponder = current
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard AppLock.shared.verify(current.stringValue) else { return showLockMessage("PIN/password salah.") }
        AppLock.shared.removeSecret()
        buildSettingsContent()
    }

    private func showLockMessage(_ text: String) {
        let a = NSAlert()
        a.messageText = text
        a.runModal()
    }
}

extension AppDelegate: NSTabViewDelegate {
    func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        if let item { settingsTabIndex = tabView.indexOfTabViewItem(item) }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Mencegah retain cycle antara WKUserContentController dan handler.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
