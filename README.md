# WhatsApp Web Launcher (macOS)

App native kecil (Swift + AppKit + WKWebView bawaan macOS) yang langsung membuka https://web.whatsapp.com. Tidak pakai Electron atau Chromium, dan tidak butuh browser pihak ketiga.

## Build & install

```bash
./build.sh            # hasil: build/WhatsApp Web.app
./build.sh install    # sekaligus salin ke /Applications/WhatsApp Web.app
```

## Fitur
- Title bar menyatu dengan halaman: warnanya mengikuti warna atas WhatsApp, termasuk mode gelap.
- Login tersimpan (sesi WebKit persisten).
- Notifikasi native macOS, dan klik notifikasi membuka chat terkait.
- Badge jumlah pesan belum dibaca di Dock.
- Tutup jendela (⌘W) hanya menyembunyikan app, jadi pesan tetap masuk. ⌘Q untuk keluar.
- Link luar dibuka di browser default. Unduhan masuk ke ~/Downloads.
- Upload file, kamera/mikrofon, zoom (⌘= / ⌘- / ⌘0), reload (⌘R).

## Profil
Klik avatar di kanan atas untuk ganti, tambah, ganti nama, atau hapus profil. Tiap profil punya login sendiri.

## Ekstensi
Menu **Ekstensi** di menu bar:
- **Sidebar bisa di-resize** (bawaan): tarik garis batas daftar chat. Klik dua kali garis itu untuk kembali ke lebar bawaan.
- **Buka Folder Ekstensi…**: taruh file `.js` atau `.css` sendiri di folder ini, lalu pilih **Muat Ulang Ekstensi** (⌘⇧R). Baris pertama `// Ekstensi: Nama` menjadi nama di menu.

Ekstensi bawaan ada di folder `Extensions/` proyek ini dan ikut dimasukkan ke app saat build.

### Nyala/mati tanpa reload
Ekstensi `.css` dan ekstensi bawaan langsung nyala/mati tanpa memuat ulang halaman.
Ekstensi `.js` buatan sendiri juga bisa, asalkan mendaftarkan fungsi pematinya:

```js
// Ekstensi: Contoh
// Keterangan singkat yang tampil di Pengaturan.
const el = document.createElement('div');
document.body.appendChild(el);
window.__waExt.onToggle(function (on) { el.hidden = !on; });
```

Tanpa `onToggle`, ekstensi `.js` tetap bisa langsung dinyalakan, tetapi mematikannya akan memuat ulang halaman.
