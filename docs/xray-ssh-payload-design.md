# Desain Fase 2 — Mode Xray, Mode SSH, dan Sistem Payload / Inject

> Dokumen rancangan. Belum ada kode produksi yang berubah gara-gara dokumen ini.
> Status: **draft buat dibaca & disetujui owner dulu**, baru implementasi jalan per fase.
> Bahasa: santai tapi teknis — yang penting keputusan arsitekturnya jelas dan bisa dieksekusi.

---

## 0. Ringkasan dalam 30 detik

App ini sekarang = satu mesin: **MASQUE/WARP** (Rust engine + `UsqueVpnService`).
Fase 2 nambah dua mesin lagi di dalam app yang sama:

| Mode | Mesin | Transport utama | Buat apa |
|------|-------|-----------------|----------|
| **MASQUE** (existing) | Rust `usque-engine` | MASQUE / HTTP/3 (QUIC), fallback HTTP/2 | WARP bawaan, nggak berubah |
| **Xray** (baru) | `xray-core` native per-ABI | VLESS / VMess / Trojan / SS di atas WS, HTTPUpgrade, XHTTP, gRPC + TLS/Reality | Konek ke panel/server Xray owner sendiri |
| **SSH** (baru) | SSH client Kotlin | SSH direct-tcpip + dynamic SOCKS5 (`-D`) | Konek ke akun SSH (Dropbear/OpenSSH) ala inject |

Ketiga mode ini **mutually exclusive**: cuma satu yang boleh aktif dalam satu waktu.
Alasannya bukan kemauan kita — itu batas keras Android (lihat §1).

Di atas mode Xray dan SSH, ada satu lapisan yang sama-sama dipakai:
**sistem Payload / Inject** (§5) — payload template ala HTTP Injector,
metode Direct / Payload+WS / Payload+TLS / **Payload Enhanced** (decoy blocks +
split + delay), yang konsepnya sengaja disamakan dengan gateway server-side
milik owner (`ws-proxy.js` di port 8880 buat SSH, `ws-xray.js` di port 8882
buat Xray). Client ngomong bahasa yang sama dengan server.

---

## 1. Constraint keras: Android cuma kasih SATU VpnService aktif

### 1.1 Faktanya

- Android **tidak** mengizinkan dua VPN aktif bersamaan di level sistem.
  Begitu satu `VpnService` establish TUN, VPN lain (termasuk dari app lain)
  akan memutus yang lama, atau permintaan baru ditolak.
- App ini **sudah** punya satu: `UsqueVpnService` (Kotlin) yang pegang TUN
  buat Rust engine (MASQUE).
- Artinya mode Xray dan mode SSH **tidak bisa** bikin `VpnService` kedua yang
  jalan barengan. Mereka harus **bergantian memakai TUN yang sama**, lewat
  satu-satunya service yang ada.

### 1.2 Keputusan: satu service, tiga "engine backend"

`UsqueVpnService` tetap satu-satunya pemilik TUN. Yang berubah: di belakang
TUN ada **engine backend** yang bisa diganti sesuai mode aktif:

```
                        ┌─────────────────────────────────────────┐
   App traffic ───────► │  TUN (ParcelFileDescriptor)             │
                        │  dimiliki UsqueVpnService — SATU-SATUNYA│
                        └────────────────┬────────────────────────┘
                                         │ fd TUN diserahkan ke
                                         ▼
                        ┌─────────────────────────────────────────┐
                        │  EngineBackend (interface, Kotlin)      │
                        ├──────────────┬──────────────┬───────────┤
                        │ MasqueBackend│ XrayBackend  │ SshBackend│
                        │ (existing,   │ (hev-socks5- │ (hev-socks5│
                        │  Rust native)│  tunnel ─►   │  tunnel ─► │
                        │              │  Xray SOCKS) │  SSH SOCKS)│
                        └──────────────┴──────────────┴───────────┘
                              hanya SATU backend hidup pada satu waktu
```

Kenapa desain ini, bukan service terpisah per mode?

1. **Nggak ada perang TUN.** Satu pemilik = satu sumber kebenaran soal
   siapa yang lagi pegang fd.
2. **Izin VPN cukup sekali.** `VpnService.prepare()` + dialog izin sistem
   tetap di jalur yang sudah ada dan sudah teruji.
3. **Notifikasi foreground, Quick Settings tile, boot receiver, per-app
   proxy** — semua infrastruktur existing nempel di service ini. Kalau bikin
   service baru, semua itu harus diduplikasi dan rawan tabrakan state.
4. **State machine UI existing** (`EngineSnapshot`, phase
   preparing/connecting/connected/error) bisa dipakai ulang oleh ketiga
   backend — UI nggak perlu tahu mesinnya apa, cukup tahu mode + phase.

### 1.3 Arbitrase / ownership TUN

Aturan mainnya ditulis eksplisit biar nggak ada race condition:

- **Single-writer:** hanya `UsqueVpnService` yang boleh `establish()` TUN
  dan yang boleh menutupnya. Backend **tidak pernah** menyentuh
  `VpnService.Builder` secara langsung.
- **Handoff bersih (stop-then-start):** ganti mode = urutan wajib:
  1. UI meminta disconnect (atau user menekan Connect di mode lain).
  2. Backend aktif menerima `stop()` → tunggu sampai proses native-nya
     benar-benar mati (Xray core berhenti, sesi SSH putus, MASQUE session
     ditutup) — ada **timeout keras** (mis. 5 detik), lewat itu paksa kill.
  3. TUN ditutup, fd dilepas.
  4. Mode aktif di-persist (lihat di bawah), backend baru di-`start()`,
     TUN di-establish ulang oleh service.
  
  Tidak ada "hot swap" backend di atas TUN yang sama. Selalu turun dulu,
  baru naik lagi. Lebih lambat ~1 detik, tapi deterministik.
- **Mode aktif disimpan persisten** (SharedPreferences / policy store
  existing, pola yang sama seperti setting lain yang sudah persisted):
  kunci `inject_active_mode` = `masque | xray | ssh`. Ini yang dibaca saat:
  - app restart,
  - boot receiver mau auto-connect (`startOnBoot`),
  - Quick Settings tile ditekan.
  
  Default kalau belum pernah diset: `masque` (perilaku lama tidak berubah).
- **Backend yang gagal start tidak boleh meninggalkan TUN setengah jadi.**
  Kalau `start()` backend baru gagal setelah backend lama berhenti,
  service wajib kembali ke state `disconnected` bersih, bukan nyangkut
  di `connecting`.
- **Koneksi ulang otomatis (Auto IP Hunter / reconnect command) hanya
  berlaku untuk backend yang sedang aktif**, dan tetap tunduk pada fix
  Fase 1 (setting persisted + satu master gate + timer dibatalkan saat
  dimatikan). Mode Xray/SSH tidak boleh memicu toggle airplane mode atas
  nama mode lain.

### 1.4 Yang TIDAK berubah

- Jalur MASQUE existing (Rust engine, IPC, snapshot) **tidak diutak-atik**
  selain penyesuaian minimal supaya dia jadi salah satu `EngineBackend`.
- Per-app proxy (`PerAppProxySettings`) tetap diterapkan di level
  `VpnService.Builder` (`addAllowedApplication` / `addDisallowedApplication`)
  oleh service — jadi otomatis berlaku buat ketiga mode, gratis.

---

## 2. Mode Xray

### 2.1 Cara embed xray-core

Dua opsi yang realistis, urutan preferensi:

1. **AndroidLibXrayLite-style AAR (gomobile)** — `libv2ray.aar` hasil build
   Xray-core lewat gomobile, dipanggil dari Kotlin lewat API
   `Libv2ray.newCoreController(...)` → `startLoop(configJson)`.
   - Pro: API lifecycle jelas (start/stop/query stats), nggak perlu
     ngurus proses terpisah, file descriptor TUN/SOCKS gampang diatur.
   - Con: build CI nambah langkah Go + gomobile (lihat §7).
2. **Binary `.so` per-ABI di `jniLibs`** — file `libxray.so` (xray-core
   dikompilasi sebagai executable, dinamai `lib*.so` supaya bisa dieksekusi
   dari native library dir Android), dijalankan sebagai child process:
   `libxray.so run -c config.json`.
   - Pro: gampang di-upgrade (ganti file binary), config JSON persis seperti
     di server — debugging gampang, `xray run -test` bisa dipakai validasi.
   - Con: manajemen proses manual (PID, stdout/stderr, zombie), dan sejak
     Android 10+ eksekusi binary dari writable dir dilarang — makanya
     harus lewat jalur `jniLibs` (native lib dir, memang executable).

**Rekomendasi:** mulai dari opsi 2 (binary `.so` per-ABI). Alasannya:
config JSON-nya identik dengan yang dihasilkan panel owner, gampang
diverifikasi pakai binary yang sama persis dengan yang dites di server
(ingat pelajaran panel: versi Xray menentukan transport yang didukung —
di sisi client pun sama, pin versi Xray client = versi yang sudah
terverifikasi jalan dengan panel, jangan asal ambil latest).

Pin versi: catat versi xray-core client di satu tempat
(`gradle.properties` / file versi di repo), dan CI memverifikasi checksum
binary per-ABI sebelum build.

### 2.2 Dari link ke config JSON

Sumber config, urutan prioritas UI:

1. **Import link satuan:** `vless://`, `vmess://`, `trojan://`, `ss://`
   (paste dari clipboard / hasil scan QR / deep link).
2. **Subscription URL:** HTTP GET ke URL `/sub` panel → body base64 berisi
   banyak link (satu per baris) → semua di-parse jadi daftar akun.
   Ini format yang **sama** dengan yang dikeluarkan panel owner sekarang,
   jadi tidak perlu format baru.
3. **Import JSON mentah** (lanjutan, Fase 2d): user paste config JSON Xray
   utuh — disimpan apa adanya, melewati generator.

Parser link hidup di Dart (`XrayLink.tryParse`, lihat
`apps/usque_gui/lib/models/inject_models.dart` — fondasi Fase 2 sudah
disediakan di situ): parse `vless://`/`trojan://` sebagai URI standar,
`vmess://` sebagai base64-JSON, `ss://` sebagai URI/base64 userinfo.
Parse gagal → `null`, **bukan exception** — UI menampilkan "link tidak
valid" tanpa crash.

Generator config (Kotlin, saat Connect ditekan) menyusun JSON Xray:

```
inbounds:
  - socks-in:  SOCKS5 di 127.0.0.1:<port lokal acak-tetap>, no-auth,
               udp: true        ← ini yang dimakan hev-socks5-tunnel
  (opsional) http-in buat mode frontend/proxy-only

outbounds:
  - proxy:     protokol dari XrayLink (vless/vmess/trojan/ss)
               streamSettings dari transport + security (§2.3, §2.4)
  - direct:    freedom
  - block:     blackhole

routing:
  - default semua ke "proxy" (global mode dulu; rule-based nyusul)
```

Port SOCKS lokal: satu port tetap per mode yang disimpan di setting
internal (bukan port publik), dicek bebas sebelum dipakai; kalau bentrok,
naik +1 dan catat. Jangan hardcode port yang sama dengan layanan lain
di HP user.

### 2.3 Transport

| Transport | `network` di Xray | Catatan |
|-----------|-------------------|---------|
| WebSocket | `ws` | Paling umum, target utama Fase 2a |
| HTTPUpgrade | `httpupgrade` | Pengganti HTTP/2 klasik di Xray modern |
| XHTTP | `xhttp` | Penerus resmi H2; mode `stream-one` buat kompat panel |
| gRPC | `grpc` | `serviceName` dari path link; lihat catatan kompat di §2.5 |

Parameter per transport diambil dari query link standar
(`type=`, `host=`, `path=`, `serviceName=`, `mode=`) — parser menyimpan
semuanya di `XrayLink`, generator tinggal memetakan 1:1. Tidak ada
penamaan transport versi kita sendiri; ikut nama Xray persis, biar link
dari panel / aplikasi lain (v2rayNG dll.) bisa saling tukar.

### 2.4 Security: TLS dan Reality

- `security=tls`: `serverName` = SNI dari link (`sni=`), fallback ke
  `host` transport, fallback terakhir ke address server. Opsi `fp=`
  (fingerprint uTLS, default `chrome`), `alpn=`, `allowInsecure` —
  **default `false`**; kalau link minta insecure, UI wajib menampilkan
  peringatan sekali, bukan diam-diam nurut.
- `security=reality`: butuh `pbk=` (public key), `sid=` (short id),
  `spx=` (spiderX), `flow=` (biasanya `xtls-rprx-vision` buat VLESS).
  Generator memetakan ke `realitySettings`. Link Reality yang tidak
  lengkap (nggak ada `pbk`) ditolak di level parser/UI dengan pesan
  jelas, bukan dikirim ke core untuk gagal misterius.
- `security=none`: cuma masuk akal di balik payload/TLS luar (§5) atau
  jaringan lokal — UI kasih badge "tanpa enkripsi" di daftar akun.

### 2.5 Kompatibilitas dengan panel /sub milik owner — WAJIB dibaca

Panel owner (keluarga `vmesssh3-fix`) menghasilkan link dengan konvensi
path yang **sudah terverifikasi** terhadap Xray 26.3.27 di server:

| Transport | Path di link /sub | Yang harus dilakukan client |
|-----------|-------------------|------------------------------|
| WS | `path` dasar (base path) | pakai apa adanya |
| HTTPUpgrade | `path + "-h2up"` | pakai apa adanya — **sudah termasuk** di link |
| XHTTP | `path + "-xhttp"`, mode `stream-one` | client **wajib** mengirim `mode=stream-one`; master inbound server butuh fallback `path` **dan** `path + "/"` (itu urusan server, sudah beres) |
| gRPC | — | **TIDAK ditawarkan lewat /sub panel** |

Konsekuensi buat client:

1. **Jangan "memperbaiki" path.** Path dari link dipakai verbatim.
   Menambah/mengurangi suffix di client = koneksi mati tanpa jejak.
2. **gRPC tidak bisa lewat fallback master panel.** Terverifikasi di
   server: parser fallback Xray 26.3.27 tidak mengekstrak path dari
   HTTP/2 preface gRPC, jadi gRPC lewat tunnel domain panel **tidak akan
   pernah connect** — bukan bug client. Maka:
   - Link gRPC dari sumber lain (server gRPC direct port) tetap didukung
     generator.
   - Tapi UI **tidak** menawarkan gRPC sebagai pilihan saat import dari
     subscription panel, dan dokumentasi di dalam app (tooltip) bilang
     alasannya. Menawarkan sesuatu yang pasti gagal = bug, titik.
3. **VMess + XHTTP dilewati panel di /sub** (panel mengeluarkan 8 link,
   VMess+XHTTP di-skip). Client tidak perlu menebak-nebak kombinasi itu;
   kalau user import link VMess+XHTTP dari sumber lain, generator tetap
   berusaha menyusunnya (itu config yang valid secara Xray), tapi bukan
     prioritas pengujian.
4. Versi Xray client yang di-embed harus **satu generasi** dengan yang
   terverifikasi di server, supaya perilaku `xhttp`/`httpupgrade` sama.
   Setiap naik versi client = ulangi uji transport satu per satu
   (WS, HTTPUpgrade, XHTTP) terhadap panel sebelum rilis.

### 2.6 TUN capture: hev-socks5-tunnel (tun2socks)

Xray sendiri tidak mengambil alih TUN Android di desain ini. Alurnya:

```
App lain ─► TUN ─► hev-socks5-tunnel ─► SOCKS5 127.0.0.1:<port> ─► Xray ─► server
```

- `hev-socks5-tunnel`: library C ringan (dipakai banyak client Android),
  di-embed sebagai `.so` per-ABI + dijalankan in-process dari Kotlin/JNI
  dengan config YAML kecil (tun name/fd, mtu, socks5 address, ipv4/ipv6).
- TUN fd didapat dari service (`establish()`), diteruskan ke
  hev-socks5-tunnel. Socket keluar milik Xray dan hev **wajib**
  di-`protect()` lewat `VpnService.protect()` supaya tidak masuk ke TUN
  sendiri (loop). Ini jalur yang sama polanya dengan perlindungan socket
  di backend MASQUE existing — pakai mekanisme yang sudah ada
  (`EstablishedTunProtection` dkk.), jangan bikin jalur protect baru.
- MTU: samakan dengan default backend MASQUE (jangan bikin MTU beda per
  mode tanpa alasan — beda MTU = bug fragmentasi yang susah dilacak).
- IPv6: kalau profile Xray tidak punya rute IPv6, cegah kebocoran IPv6
  dengan tidak mengiklankan rute IPv6 di TUN **atau** arahkan ke block —
  pilih satu dan tulis di UI ("IPv6: diblokir di mode ini") — jangan
  diam-diam bocor direct.

### 2.7 Lifecycle Mode Xray

- **Start:** service establish TUN → start hev-socks5-tunnel → spawn
  Xray (atau `startLoop`) dengan config JSON hasil generator → tunggu
  SOCKS inbound siap (poll port lokal, timeout ±3 dtk) → snapshot phase
  `connected`. Urutan ini penting: hev duluan tapi Xray belum siap =
  paket hilang di awal; Xray duluan = aman, hev menyusul.
  (Implementasi final boleh membalik urutan selama SOCKS-ready check
  ada sebelum phase dilaporkan `connected`.)
- **Stop:** hentikan hev → hentikan Xray → tutup TUN. Kebalikan urutan
  start, dan setiap langkah ditunggu/timeout, bukan fire-and-forget.
- **Notifikasi foreground:** pakai `VpnNotificationController` existing —
  teksnya ditambah nama mode + remark akun ("Xray • VLESS-WS-TLS kantor"),
  bukan bikin channel notifikasi baru.
- **Crash/restart:** kalau proses Xray mati di tengah jalan (exit code
  ≠ 0), backend melaporkan `error` ke snapshot dengan potongan stderr
  terakhir (dibatasi, mis. 2 KB) supaya user bisa screenshot ke owner —
  bukan cuma "gagal konek".
- **Per-app proxy:** gratis dari service (§1.4).

---

## 3. Mode SSH

### 3.1 Arsitektur

Tidak ada OpenSSH binary. SSH client ditulis/di-embed di sisi Kotlin:

```
App lain ─► TUN ─► hev-socks5-tunnel ─► SOCKS5 lokal ─► SSH client (Kotlin)
                                                          │ dynamic port
                                                          │ forwarding (-D)
                                                          ▼
                                              SSH server (Dropbear/OpenSSH)
                                                          │
                                                          ▼
                                                       internet
```

- **Library:** JSch fork yang masih dirawat (mis. `com.github.mwiede:jsch`)
  atau implementasi SSH di atas Mina SSHD client. Kriteria pilih:
  masih aktif dirawat, support algoritma modern (lihat §3.3), license
  cocok. Keputusan final dicatat di PR implementasi, bukan di dokumen ini.
- **Dynamic forwarding:** satu sesi SSH membuka SOCKS5 listener lokal
  (itu yang disebut `-D` di OpenSSH). Setiap koneksi SOCKS → SSH
  `direct-tcpip` channel ke tujuan. Tidak perlu port-forward satu-satu.
- **Reconnect:** sesi SSH putus = snapshot `error`/reconnecting; auto
  reconnect dengan backoff (5s → 15s → 30s, cap), dan **selalu** tunduk
  ke master gate reconnect Fase 1.
- **Keepalive:** `ServerAliveInterval` ±30 dtk biar NAT/server nggak
  memutus sesi idle.

### 3.2 Model akun

Sudah disediakan di fondasi Dart (`SshAccount` di `inject_models.dart`):

| Field | Isi |
|-------|-----|
| `host`, `port` | server SSH (biasanya 22 / 80 / 443 / 8080 dst.) |
| `username`, `password` | kredensial akun SSH |
| `payload` | template payload (§5), boleh kosong untuk SSH direct |
| `sniHost` | bug host / SNI untuk metode Payload+TLS |
| `method` | `InjectMethod` — direct / payloadWebSocket / payloadTls / payloadEnhanced |

Catatan keamanan (ditulis sekarang biar nggak lupa):
**password SSH disimpan terenkripsi** memakai mekanisme penyimpanan aman
yang sudah ada di app (pola `SecureIdentityStore` / Android Keystore),
**bukan** plaintext di SharedPreferences. `toMap()` di model Dart hanya
untuk transport antar-layer, bukan format penyimpanan final.

### 3.3 Kompatibilitas server

- **Dropbear** (yang jalan di panel owner): support `direct-tcpip`,
  algoritma klasik + modern. Pastikan client menawarkan
  `curve25519-sha256`, `ssh-ed25519`, `rsa-sha2-*`, dan **tetap**
  mengizinkan `ssh-rsa`/`aes128-ctr` dkk. sebagai fallback untuk server
  tua — tapi tampilkan peringatan kalau sesi menegosiasikan algoritma
  lemah.
- **OpenSSH modern:** host key `ed25519`/`ecdsa` wajib didukung;
  verifikasi host key mode **TOFU** (trust on first use): simpan
  fingerprint saat koneksi pertama, peringatkan keras kalau berubah.
  Tidak ada opsi "abaikan host key selamanya" tanpa peringatan.
- **SSH di atas WebSocket (kasus panel owner):** server SSH-nya sendiri
  berada di belakang gateway WS (`ws-proxy.js`, port 8880). Untuk akun
  seperti itu, urutan koneksinya: buka transport WS dulu (dengan/tanpa
  payload, §5), **baru** jalankan handshake SSH di atas stream WS itu.
  Jadi SSH client harus bisa bekerja di atas `Socket` abstrak hasil
  tahap transport, bukan selalu membuka TCP sendiri. Ini alasan
  `InjectMethod` nempel di akun SSH, bukan cuma di akun Xray.

---

## 4. (Sengaja dilompati — penomoran mengikuti rencana fase di repo)

_(§5 di bawah adalah inti permintaan owner: sistem payload.)_

---

## 5. Sistem Payload / Inject

Ini bagian terpenting buat owner sebagai pengguna inject. Konsepnya
mengikuti pakem **HTTP Injector** dkk. yang sudah jadi bahasa bersama
komunitas, dan diselaraskan dengan gateway server-side owner sendiri.

### 5.1 Payload template & placeholder

Payload = teks mentah (umumnya mirip request HTTP) yang dikirim ke
server/bug host sebelum/di awal koneksi. Di editor, user menulis
template dengan placeholder dalam kurung siku:

| Placeholder | Diganti jadi | Keterangan |
|-------------|--------------|------------|
| `[method]` | method HTTP, default `CONNECT` (bisa `GET` dll.) | |
| `[host]` | host tujuan (bug host / host akun) | |
| `[host_port]` | `host:port` gabungan | paling sering dipakai di baris pertama |
| `[protocol]` | `HTTP/1.1` | |
| `[crlf]` | `\r\n` | akhir baris standar HTTP |
| `[lf]` | `\n` | |
| `[crf]` | `\r` | |
| `[ua]` | User-Agent default app | *(usulan, Fase 2b)* |
| `[split]` | — **bukan teks** — | **directive waktu kirim:** putus pengiriman di titik ini, kirim sebagai potongan terpisah |
| `[delay]` | — **bukan teks** — | **directive waktu kirim:** jeda (default ±1 dtk, bisa `[delay=500]` ms — *usulan sintaks*) sebelum potongan berikutnya |

Aturan main yang dikunci dari sekarang (dan sudah diterapkan di fondasi
Dart `PayloadTemplate`):

- `build()` mengganti placeholder teks, dan **membiarkan `[split]` /
  `[delay]` apa adanya** di string hasil — mereka bukan urusan builder,
  mereka urusan pengirim (sender).
- `splitSegments()` memecah payload hasil build pada `[split]` menjadi
  daftar potongan yang dikirim berurutan.
- Placeholder tidak dikenal **dibiarkan utuh** (bukan dihapus, bukan
  error) — supaya template dari komunitas yang memakai placeholder lain
  tidak rusak diam-diam; editor boleh memberi highlight peringatan.
- Tidak ada evaluasi ekspresi, tidak ada scripting. Template = teks +
  placeholder di atas. Titik.

Contoh template klasik:

```
[method] [host_port] [protocol][crlf]Host: [host][crlf]Connection: Keep-Alive[crlf][crlf]
```

### 5.2 Empat metode koneksi

Enum-nya sudah ada di fondasi: `InjectMethod { direct, payloadWebSocket,
payloadTls, payloadEnhanced }`.

#### (a) Direct WebSocket — tanpa payload

Buat server WS biasa (termasuk gateway panel owner untuk config normal).

```
Client                                   Server WS / gateway
  │                                            │
  │── TCP connect ────────────────────────────►│
  │── GET /path HTTP/1.1  (Upgrade: websocket)►│
  │◄───────────── 101 Switching Protocols ─────│
  │════ stream WS bersih (VLESS/VMess/SSH) ════│
```

Tidak ada byte ekstra sebelum upgrade. Ini baseline; semua metode lain
adalah variasi "ada sesuatu sebelum/di sekitar langkah ini".

#### (b) Payload + WebSocket — payload dulu, baru upgrade bersih

Buat server di belakang gateway filter ala `ws-proxy.js` (SSH, port 8880)
dan `ws-xray.js` (Xray, port 8882) milik owner: gateway **memindai dan
membuang blok kotor di depan**, lalu meneruskan upgrade WS yang bersih
ke backend (SSH / Xray :8001).

```
Client                                   Gateway 8880/8882        Backend
  │                                            │                     │
  │── TCP connect ────────────────────────────►│                     │
  │── [PAYLOAD BLOCK][split] ─────────────────►│  dibaca, dibuang    │
  │── GET /path (Upgrade: websocket, bersih) ─►│── upgrade bersih ──►│
  │◄──────────── 101 ──────────────────────────│◄───────────────────│
  │══════════ stream (SSH / VLESS / dll.) ══════════════════════════│
```

- Payload boleh berisi Host bug, header acak, dsb. — gateway tidak
  peduli isinya, gateway cuma peduli **di mana payload berakhir dan
  upgrade bersih dimulai**. Makanya `[split]` di sini bukan kosmetik:
  dia menandai batas yang membuat pengiriman payload dan upgrade jadi
  dua potongan TCP terpisah, yang memang diharapkan sisi server.
- Path WS tetap harus salah satu path resmi akun/panel (gateway
  meng-allowlist path) — payload kotor tidak menolong kalau path salah.

#### (c) Payload + TLS — CONNECT di dalam TLS, SNI = bug host

Buat bug berupa host yang lolos SNI filtering (host gratisan operator,
host whitelist, dsb.):

```
Client                                   Bug host :443 (TLS)      Server tujuan
  │                                            │                        │
  │── TCP connect ────────────────────────────►│                        │
  │── TLS ClientHello, SNI = [sniHost] ───────►│  (filter melihat SNI   │
  │◄──────────── TLS established ──────────────│   ini dan meloloskan)  │
  │── di DALAM TLS: [PAYLOAD CONNECT           │                        │
  │    host_port tujuan] ─────────────────────►│── (server/proxy di ───►│
  │◄──────────── 200 Connection Established ───│    balik TLS menerus-  │
  │════ stream bersih: WS upgrade / SSH / ═════│    kan ke tujuan)      │
  │     protokol akun, di dalam TLS yang sama  │                        │
```

- Dari luar, yang terlihat cuma TLS ke bug host dengan SNI bug host.
- Payload CONNECT hidup **di dalam** tunnel TLS — beda total dengan
  metode (b) yang payload-nya plaintext di depan.
- Di model data: `sniHost` di akun diisi bug host; `host`/`port` tetap
  server tujuan sebenarnya.

#### (d) Payload Enhanced — decoy blocks sebelum request asli

Ini ciri khas gateway owner: client mengirim **satu atau lebih blok
payload umpan (decoy)** lebih dulu — boleh berisi host lain, request
palsu, potongan acak sesuai template user — baru kemudian request asli
(upgrade WS bersih, atau awal TLS). Gateway server memindai melewati
blok-blok kotor itu sampai menemukan request yang valid, membuang
sisanya, dan menyambung stream bersih ke backend. Client dan server
sudah sepakat soal konsep ini; Fase 2 tinggal membuat client-nya
sekelas server-nya.

```
Client                                   Gateway 8882 (ws-xray)   Xray :8001
  │                                            │                      │
  │── TCP connect ────────────────────────────►│                      │
  │── [DECOY BLOCK 1][split] ─────────────────►│  dipindai → dibuang  │
  │── [delay] [DECOY BLOCK 2][split] ─────────►│  dipindai → dibuang  │
  │── GET /path-resmi (Upgrade: websocket) ───►│── upgrade bersih ───►│
  │◄──────────── 101 ──────────────────────────│◄─────────────────────│
  │══════════ stream VLESS/VMess/Trojan ══════════════════════════════│
```

Parameter enhanced yang dikontrol user (per akun / per preset):

- **Jumlah blok decoy:** 1–4 (default 1). Lebih banyak ≠ lebih bagus;
  tiap blok = latensi + risiko gateway timeout.
- **Isi tiap blok:** dari template payload yang sama/diedit per blok
  (Fase 2b: satu template + opsi "acak tambahan" sederhana; jangan
  over-engineer).
- **Split-send:** hormati `[split]` di antara blok dan sebelum request
  asli — **wajib**, ini justru inti mekanismenya.
- **Delay antar potongan:** dari `[delay]` di template, default kecil
  (ratusan ms). Delay besar bikin koneksi terasa lemot dan bisa kena
  timeout gateway; UI menampilkan total estimasi delay.
- Metode enhanced bisa dikombinasikan sebagai pembuka untuk transport
  WS (paling umum) — kombinasi enhanced+TLS dicatat sebagai eksperimen
  Fase 2d, bukan janji 2b.

### 5.3 Komponen pengirim (sender) — kontrak implementasi

Satu komponen Kotlin bertanggung jawab untuk semua metode, supaya
perilaku split/delay konsisten:

```
SenderInput:  socket mentah, method, payloadTemplate?, akun (host/port/sni), requestAsli (WS upgrade / TLS ClientHello jalan normal)
SenderOutput: socket/stream yang sudah "bersih" — tahap berikutnya
              (WS / TLS / SSH handshake) tinggal jalan di atasnya.
```

Kontraknya:

1. `direct` → sender tidak mengirim apa-apa, langsung serahkan socket.
2. `payloadWebSocket` → build payload → kirim segmen per `[split]`
   dengan delay sesuai `[delay]` → serahkan socket; pemanggil mengirim
   upgrade WS bersih.
3. `payloadTls` → sender membantu urutan: TCP → TLS (SNI dari akun) →
   kirim payload CONNECT di dalam TLS → baca respon sampai
   `200` (atau baris kosong ganda) → serahkan stream TLS.
4. `payloadEnhanced` → kirim N blok decoy (masing-masing di-split/delay
   sesuai template) → serahkan socket; pemanggil mengirim request asli.
5. Semua pengiriman payload punya **timeout total** dan **batas ukuran**
   (mis. payload > 16 KB ditolak di editor) — payload bukan tempat
   membuang data sembarangan ke socket.

### 5.4 SlowDNS — dicatat, bukan sekarang

SlowDNS (DNS tunnel, biasanya di port 53 UDP/TCP ke resolver) pernah
dibahas owner untuk "menggendong" protokol lain. Kesimpulan yang sudah
terverifikasi dan **tetap berlaku**:

- SlowDNS praktis hanya mengangkut **TCP** (dan itu pun pelan, latensi
  tinggi, bandwidth kecil).
- MASQUE bawaan app ini (QUIC = UDP) **tidak bisa** digendong SlowDNS.
- Secara teori mode SSH (TCP) dan Xray-WS-over-TCP **bisa** dicoba
  digendong, dengan ekspektasi performa buruk dan timeout sering.

Maka SlowDNS dicatat sebagai **kemungkinan transport Fase 3** untuk
mode SSH/Xray-TCP saja, dengan status "eksperimen, bukan fitur yang
dijanjikan". Tidak ada yang di Fase 2 bergantung padanya.

---

## 6. Rencana UI — section "Inject"

Prinsip: **jangan bikin app kedua di dalam app.** Pakai pola layar,
komponen, dan state machine yang sudah ada.

### 6.1 Struktur

```
Home (existing)
  └─ Mode picker: [ MASQUE | Xray | SSH ]   ← segmented control di atas
                                               kartu status koneksi
Settings (existing)
  └─ "Inject" section (baru)
       ├─ Mode Xray: daftar akun Xray ──► detail/import
       ├─ Mode SSH:  daftar akun SSH  ──► detail/import
       └─ Payload presets (bersama, dipakai kedua mode)
```

- **Mode picker** di Home mengubah: akun yang ditampilkan tombol Connect,
  label tombol, dan backend yang akan dijalankan. Mengganti picker
  **tidak** langsung memutus koneksi aktif — kalau lagi connected di mode
  lain, picker menampilkan mode aktif sebagai terkunci + tombol
  Disconnect dulu. (Mencegah user memutus koneksinya sendiri tanpa sadar.)
- **Tombol Connect** tetap satu, tetap memakai state machine
  `EngineSnapshot` existing (preparing → connecting → connected/error +
  statistik yang tersedia). Backend Xray/SSH memetakan tahap-tahapnya ke
  phase yang sama:
  - Xray: preparing = generate config, connecting = start core + tunggu
    SOCKS, connected = SOCKS siap + uji koneksi ringan lolos.
  - SSH: preparing = buka transport (+payload), connecting = handshake +
    auth SSH, connected = SOCKS `-D` siap.

### 6.2 Daftar akun & import

Satu layar daftar per mode, pola visual mengikuti daftar profile
existing. Sumber import:

- **Paste link** (clipboard dideteksi otomatis: kalau clipboard berisi
  `vless://…` dst., tampilkan banner "Import dari clipboard?").
- **Scan QR** (kamera) — reuse izin & komponen yang ada kalau tersedia;
  kalau belum ada, ini item terpisah, bukan blocker 2a.
- **Subscription URL** (khusus Xray): field URL + tombol refresh;
  menampilkan jumlah link berhasil di-parse vs gagal (gagal tidak
  menyembunyikan error — ditampilkan sebagai baris "tidak valid").
- **Paste akun SSH** format bebas? **Tidak** untuk 2c awal — form SSH
  diisi manual (host/port/user/pass) + pilihan preset payload. Parser
  format akun SSH tempelan itu formatnya tidak standar; jangan ditebak.

Tiap baris akun menampilkan: remark, protokol/transport/security
(Xray) atau host:port (SSH), metode inject (badge: Direct / Payload /
TLS / Enhanced), dan badge peringatan kalau security `none` atau
algoritma lemah.

### 6.3 Editor payload

- Text field monospace multi-baris + deretan tombol sisip placeholder
  (`[host]`, `[host_port]`, `[crlf]`, `[split]`, `[delay]`, …) di
  atas keyboard — mengetik kurung siku manual di HP itu menyiksa.
- **Preset bawaan** (minimal 3): CONNECT standar, GET bug-host standar,
  Enhanced 1-blok (template + `[split]` + request-friendly). Preset =
  titik awal, bukan kunci — semua bisa diedit.
- **Preview hasil build:** tombol "Preview" menjalankan
  `PayloadTemplate.build()` dengan host/port akun terpilih dan
  menampilkan hasilnya dengan `\r\n` divisualkan (`␍␊`) — user bisa
  **melihat** payload-nya sebelum connect, bukan nebak.
- Validasi ringan saat simpan: kurung siku tidak tertutup, payload
  kosong untuk metode non-direct, total delay berlebihan → peringatan,
  bukan hard-block (kecuali payload kosong).

### 6.4 Field SNI / bug host

- Satu field jelas bernama **"SNI / Bug Host"** di form akun (kedua
  mode), dengan hint bahwa field ini yang tampil di ClientHello TLS.
- Untuk metode `payloadTls`, field ini **wajib**; untuk metode lain
  opsional (dipakai sebagai SNI kalau security TLS aktif di Xray).

---

## 7. Dampak build & CI

### 7.1 Ukuran APK (estimasi kasar, per-ABI split seperti rilis existing)

| Komponen baru | Estimasi tambahan |
|---------------|-------------------|
| xray-core binary `.so` (sudah strip) | ± 12–18 MB per ABI |
| hev-socks5-tunnel `.so` | ± 0,3–0,6 MB per ABI |
| SSH client (Kotlin/JVM, masuk DEX) | ± 1–2 MB (semua ABI, sekali) |
| UI + model Dart | dapat diabaikan (< 0,5 MB) |

Rilis existing sekarang ± 16 MB (arm64) / ± 15 MB (armv7).
Target realistis setelah Fase 2 lengkap: **± 30–35 MB per APK split**.
Masih wajar untuk kelas app VPN, tapi:

- **Jangan** pindah ke universal APK — split per-ABI existing dipertahankan,
  justru di sinilah gunanya.
- Kalau ukuran jadi masalah, opsi Fase 2d: unduh binary Xray saat
  pertama kali mode Xray dipakai (on-demand). Dicatat sebagai opsi,
  bukan keputusan sekarang (ada implikasi keamanan: wajib verifikasi
  checksum/signature unduhan).

### 7.2 jniLibs / AAR per ABI

- ABI yang didukung mengikuti rilis existing persis:
  **`arm64-v8a`** (POCO C75 owner) dan **`armeabi-v7a`**. Tidak nambah
  x86/x86_64 untuk rilis (emulator cukup dari build debug lokal/CI).
- Setiap binary native baru masuk repo sebagai artefak ter-pin + checksum
  SHA-256 tercatat; CI **gagal** kalau checksum tidak cocok. Tidak ada
  binary hasil build lokal yang di-commit tanpa checksum.
- Kalau jalur AAR (gomobile) yang akhirnya dipilih untuk Xray, AAR-nya
  juga ter-pin per versi dengan cara yang sama.

### 7.3 GitHub Actions (workflow "Build and Release APKs" existing)

Perubahan yang dibutuhkan, sekecil mungkin:

1. **Step baru (kondisional per fase):** unduh & verifikasi binary Xray
   dan hev-socks5-tunnel per-ABI dari rilis upstream ter-pin (atau dari
   artefak repo), letakkan ke `jniLibs`. Cache-kan supaya build tidak
   lambat permanen.
2. **Kalau jalur gomobile dipilih:** tambah setup Go + gomobile build
   step — ini menambah waktu build signifikan (estimasi +10–20 menit)
   dan merupakan argumen tambahan untuk memilih jalur binary `.so`.
3. **Smoke check baru di CI:** 
   - `dart analyze` lolos untuk file model baru (fondasi Fase 2 harus
     lolos dari hari pertama),
   - validasi 3–5 config JSON hasil generator contoh memakai
     `xray run -test` di runner (binary yang sama dengan yang di-embed)
     — pelajaran dari panel: config test pakai binary asli, bukan
     sekadar cek struktur JSON.
4. Penamaan artefak rilis tidak berubah (`app-arm64-v8a-release.apk`,
  `app-armeabi-v7a-release.apk`) supaya kebiasaan user tidak rusak.

### 7.4 Rollout bertahap

| Fase | Isi | Kriteria "selesai" |
|------|-----|---------------------|
| **2a** | Mode Xray: WS + TLS, direct saja. Import link + subscription panel. Mode-switcher + arbitrase TUN. | Connect ke panel owner via VLESS/VMess/Trojan WS-TLS dari /sub, trafik nyata lewat, ganti mode MASQUE↔Xray bersih |
| **2b** | Sistem payload: editor + preset + metode Payload+WS, Payload+TLS, **Enhanced** untuk mode Xray. | Konek lewat gateway `ws-xray.js` :8882 dengan config payload-enhanced; preview payload di UI cocok dengan yang terkirim |
| **2c** | Mode SSH: akun SSH, direct + WS transport (lewat :8880), payload untuk SSH, SOCKS `-D` + tun2socks. | Akun SSH panel owner connect (termasuk yang di belakang gateway WS), trafik lewat, reconnect patuh master gate |
| **2d** | Polish: XHTTP + HTTPUpgrade + gRPC (direct) + Reality lengkap, QR import, aturan routing sederhana, opsi binary on-demand kalau ukuran jadi isu. | Semua transport teruji satu-satu ke server nyata; gRPC hanya ditawarkan untuk server direct, **bukan** via /sub panel (§2.5) |

Setiap fase = rilis sendiri. Tidak ada fase yang menunggu fase
berikutnya untuk boleh dipakai.

---

## 8. Risiko & pertanyaan terbuka

### Risiko teknis

1. **Versi Xray client vs server.** Transport baru (XHTTP) berubah
   cepat antarversi. Mitigasi: pin versi, uji ulang per transport
   setiap naik versi (§2.5.4).
2. **Race saat ganti mode.** Stop backend lama yang menggantung
   (SSH tidak putus-putus, Xray tidak mau mati) bisa mengunci TUN.
   Mitigasi: timeout keras + paksa kill (§1.3), dan state service
   tidak bergantung pada backend untuk bisa kembali ke `disconnected`.
3. **Protect-loop.** Socket Xray/hev/SSH yang lupa di-`protect()` akan
   masuk TUN sendiri → koneksi muter-muter / langsung mati. Ini bug
   klasik tun2socks; wajib ada checklist + tes khusus (connect dengan
   rute TUN global dan pastikan handshake keluar lewat jaringan fisik).
4. **Payload enhanced itu timing-sensitive.** Jumlah blok, split, dan
   delay yang pas di satu gateway bisa gagal di gateway lain (timeout,
   batas ukuran scan). Mitigasi: default konservatif (1 blok, delay
   kecil), semua parameter kelihatan di UI, dan log diagnostik
   menampilkan berapa byte/blok yang terkirim.
5. **Kredensial SSH plaintext.** Risiko kalau penyimpanan aman
   dilewatkan demi cepat. Mitigasi: §3.2 — penyimpanan terenkripsi
   adalah syarat Fase 2c, bukan polish.
6. **Ukuran & waktu build CI membengkak** (terutama jalur gomobile).
   Mitigasi: jalur binary `.so` dulu, cache artefak.
7. **Kebijakan Play / sideload.** App ini didistribusikan sebagai APK
   rilis GitHub, bukan Play Store — tapi binary tambahan tetap harus
   jelas asal-usulnya (checksum, §7.2) supaya tidak jadi masalah
   kepercayaan user.
8. **Deteksi operator / bug host berubah.** Payload & bug adalah
   permainan kucing-tikus di luar kendali app. App hanya menyediakan
   alat edit yang bagus; tidak menjanjikan satu bug akan hidup lama.

### Pertanyaan terbuka (perlu jawaban owner sebelum fase terkait)

1. **(2a)** Link Xray pertama yang mau diuji: ambil dari /sub panel
   owner yang mana — VLESS-WS-TLS dulu sebagai patokan?
2. **(2a)** Mode frontend existing (SOCKS5/HTTP proxy tanpa TUN) perlu
   juga bisa dikeluarkan dari mode Xray, atau TUN saja dulu?
3. **(2b)** Preset payload bawaan: pakai template andalan owner yang
   mana saja (tempel contoh aslinya, jangan dari ingatan)?
4. **(2b)** `[delay]` perlu nilai yang bisa diatur per-marker
   (`[delay=500]`) atau satu nilai global per akun cukup?
5. **(2c)** Akun SSH utama buat pengujian: yang di belakang gateway WS
   :8880 (panel) atau SSH direct port 22/443?
6. **(2c)** Selain password, perlu auth SSH pakai key file sejak awal,
   atau password dulu?
7. **Umum** Saat mode Xray/SSH aktif, Auto IP Hunter (toggle airplane)
   mau berlaku juga, atau khusus MASQUE saja? (Dokumen ini mengasumsikan:
   berlaku per backend aktif, tunduk gate Fase 1 — koreksi kalau salah.)

---

## 9. Fondasi yang sudah disiapkan bersamaan dengan dokumen ini

`apps/usque_gui/lib/models/inject_models.dart` — model Dart murni
(tanpa package luar) berisi:

- `InjectMode { masque, xray, ssh }`
- `InjectMethod { direct, payloadWebSocket, payloadTls, payloadEnhanced }`
- `XrayLink` + `tryParse()` untuk `vless://`, `trojan://`, `vmess://`
- `SshAccount` (+ `toMap`/`fromMap`)
- `PayloadTemplate.build()` + `splitSegments()` sesuai kontrak §5.1

File itu sengaja berdiri sendiri dan konservatif: dia belum di-wire ke
UI atau controller mana pun. Wiring adalah langkah pertama Fase 2a —
setelah dokumen ini disetujui.

---

*Akhir dokumen. Koreksi & jawaban pertanyaan §8 langsung tulis di sini
atau sampaikan ke sesi berikutnya; dokumen ini yang jadi patokan
implementasi Fase 2.*
