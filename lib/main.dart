import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:vibration/vibration.dart';
import 'package:audioplayers/audioplayers.dart';

void main() => runApp(const SmartLevelApp());

// ======================= LOGIKA =======================
// Tanda x dan y bisa beda antar HP, tes langsung lalu sesuaikan.
String tentukanStatus(double x, double y) {
  const batas = 2.0;
  if (x > batas) return 'Miring Kiri';
  if (x < -batas) return 'Miring Kanan';
  if (y < -batas) return 'Miring Depan';
  if (y > batas) return 'Miring Belakang';
  return 'Seimbang';
}

Color warnaStatus(String s) {
  switch (s) {
    case 'Seimbang':
      return const Color(0xFF2E9E5B);
    case 'Miring Kiri':
      return const Color(0xFFE67E22);
    case 'Miring Kanan':
      return const Color(0xFF2980B9);
    case 'Miring Depan':
      return const Color(0xFF8E44AD);
    default:
      return const Color(0xFFC0392B);
  }
}

IconData ikonStatus(String s) {
  switch (s) {
    case 'Seimbang':
      return Icons.check_circle;
    case 'Miring Kiri':
      return Icons.arrow_back;
    case 'Miring Kanan':
      return Icons.arrow_forward;
    case 'Miring Depan':
      return Icons.arrow_upward;
    default:
      return Icons.arrow_downward;
  }
}

// Generator bunyi beep (WAV dibuat lewat kode, tanpa file mp3)
Uint8List buatBeep({int hz = 880, int ms = 300}) {
  const sr = 44100;
  final n = sr * ms ~/ 1000;
  final d = ByteData(44 + n * 2);
  void str(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      d.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  d.setUint32(4, 36 + n * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  d.setUint32(16, 16, Endian.little);
  d.setUint16(20, 1, Endian.little);
  d.setUint16(22, 1, Endian.little);
  d.setUint32(24, sr, Endian.little);
  d.setUint32(28, sr * 2, Endian.little);
  d.setUint16(32, 2, Endian.little);
  d.setUint16(34, 16, Endian.little);
  str(36, 'data');
  d.setUint32(40, n * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    final s = (sin(2 * pi * hz * i / sr) * 0.8 * 32767).toInt();
    d.setInt16(44 + i * 2, s, Endian.little);
  }
  return d.buffer.asUint8List();
}

// ======================= CONTROLLER =======================
class TiltController extends ChangeNotifier {
  StreamSubscription<AccelerometerEvent>? _sub;
  final List<double> _bx = [], _by = [];
  final AudioPlayer _player = AudioPlayer();
  final Uint8List _beep = buatBeep();

  double x = 0, y = 0, z = 9.8;
  String status = 'Seimbang';
  String? error;
  bool aktif = false;
  bool? sensorTersedia; // null = sedang dicek
  bool getarOn = true;
  bool suaraOn = true;
  int jumlahPemicu = 0;

  Future<void> cekSensor() async {
    sensorTersedia = null;
    notifyListeners();
    try {
      await accelerometerEventStream()
          .first
          .timeout(const Duration(seconds: 2));
      sensorTersedia = true;
    } catch (_) {
      sensorTersedia = false;
    }
    notifyListeners();
  }

  void mulai() {
    if (aktif) return;
    error = null;
    aktif = true;
    _sub = accelerometerEventStream().listen(
      _onData,
      onError: (_) => _sensorError(),
    );
    notifyListeners();
  }

  void stop({bool notify = true}) {
    _sub?.cancel(); // hemat baterai
    _sub = null;
    aktif = false;
    if (notify) notifyListeners();
  }

  // Dipanggil otomatis kalau stream sensor mengirim error
  void _sensorError() {
    stop(notify: false);
    error = 'Sensor tidak tersedia atau tidak ada data';
    notifyListeners();
  }

  double _rata(List<double> l, double v) {
    l.add(v);
    if (l.length > 5) l.removeAt(0);
    return l.reduce((a, b) => a + b) / l.length;
  }

  Future<void> _aktuator() async {
    try {
      if (getarOn) {
        if (await Vibration.hasVibrator() == true) {
          Vibration.vibrate(duration: 300);
        } else {
          HapticFeedback.heavyImpact();
        }
      }
      if (suaraOn) {
        await _player.stop();
        await _player.play(BytesSource(_beep));
      }
    } catch (_) {
      // abaikan error aktuator supaya aplikasi tidak crash
    }
  }

  void _onData(AccelerometerEvent e) {
    x = _rata(_bx, e.x);
    y = _rata(_by, e.y);
    z = e.z;
    final baru = tentukanStatus(x, y);
    if (baru != status) {
      status = baru;
      if (baru != 'Seimbang') {
        jumlahPemicu++;
        _aktuator();
      }
    }
    notifyListeners();
  }

  // Tombol "Tes Respons": selalu getar dan bunyi walau switch mati
  void ujiGetar() async {
    try {
      Vibration.vibrate(duration: 300);
      await _player.stop();
      await _player.play(BytesSource(_beep));
    } catch (_) {}
  }

  void setGetar(bool v) {
    getarOn = v;
    notifyListeners();
  }

  void setSuara(bool v) {
    suaraOn = v;
    notifyListeners();
  }

  void reset() {
    jumlahPemicu = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _player.dispose();
    super.dispose();
  }
}

// ======================= APP =======================
class SmartLevelApp extends StatelessWidget {
  const SmartLevelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Smart Level Mobile',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF1565C0),
      ),
      home: const HomeScreen(),
    );
  }
}

// ======================= SCREEN 1: HOME =======================
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final c = TiltController();

  @override
  void initState() {
    super.initState();
    c.cekSensor();
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  void _mulai() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => LevelShell(c: c)),
    ).then((_) => c.cekSensor());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0D47A1), Color(0xFF42A5F5)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ListenableBuilder(
              listenable: c,
              builder: (context, _) {
                final cek = c.sensorTersedia;
                final teks = cek == null
                    ? 'Mengecek sensor...'
                    : cek
                        ? 'Accelerometer tersedia'
                        : 'Accelerometer tidak tersedia';
                final warna = cek == null
                    ? Colors.amber
                    : cek
                        ? Colors.greenAccent
                        : Colors.redAccent;
                return Column(
                  children: [
                    const Spacer(),
                    const Icon(Icons.straighten, size: 96, color: Colors.white),
                    const SizedBox(height: 16),
                    const Text(
                      'Smart Level Mobile',
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Mendeteksi kemiringan smartphone (kiri, kanan, depan, belakang) memakai sensor accelerometer.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70, fontSize: 15),
                    ),
                    const SizedBox(height: 24),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(30),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.circle, size: 12, color: warna),
                          const SizedBox(width: 8),
                          Text(teks,
                              style: const TextStyle(color: Colors.white)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Card(
                      color: Colors.white24,
                      elevation: 0,
                      child: Padding(
                        padding: EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Icon(Icons.privacy_tip, color: Colors.white),
                            SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Izin akses: accelerometer tidak membutuhkan izin khusus. Getaran memakai izin VIBRATE (izin normal, tanpa pop-up). Tidak ada data yang dikirim keluar perangkat.',
                                style: TextStyle(
                                    color: Colors.white, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFF0D47A1),
                        ),
                        onPressed: _mulai,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Mulai',
                            style: TextStyle(fontSize: 18)),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

// ======================= SHELL (3 screen dengan tab bawah) =======================
class LevelShell extends StatefulWidget {
  final TiltController c;
  const LevelShell({super.key, required this.c});

  @override
  State<LevelShell> createState() => _LevelShellState();
}

class _LevelShellState extends State<LevelShell> {
  int index = 0;

  @override
  void initState() {
    super.initState();
    widget.c.mulai(); // sensor aktif saat masuk
  }

  @override
  void dispose() {
    widget.c.stop(notify: false); // sensor mati saat keluar
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final judul = ['Data Sensor', 'Hasil Status', 'Respons'][index];
    return Scaffold(
      appBar: AppBar(
        title: Text(judul),
        actions: [
          ListenableBuilder(
            listenable: c,
            builder: (_, __) => TextButton.icon(
              onPressed: c.aktif ? c.stop : c.mulai,
              icon: Icon(c.aktif ? Icons.stop_circle : Icons.play_circle),
              label: Text(c.aktif ? 'Stop' : 'Mulai'),
            ),
          ),
        ],
      ),
      body: IndexedStack(
        index: index,
        children: [
          SensorScreen(c: c),
          ResultScreen(c: c),
          ResponseScreen(c: c),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => setState(() => index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.sensors), label: 'Sensor'),
          NavigationDestination(icon: Icon(Icons.rule), label: 'Hasil'),
          NavigationDestination(
              icon: Icon(Icons.vibration), label: 'Respons'),
        ],
      ),
    );
  }
}

// ======================= SCREEN 2: SENSOR =======================
class SensorScreen extends StatelessWidget {
  final TiltController c;
  const SensorScreen({super.key, required this.c});

  Widget _baris(String label, double nilai, Color warna) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: warna,
          child: Text(label, style: const TextStyle(color: Colors.white)),
        ),
        title: Text('Sumbu $label'),
        trailing: Text(
          '${nilai.toStringAsFixed(2)} m/s²',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (_, __) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: ListTile(
              leading: const Icon(Icons.screen_rotation),
              title: const Text('Accelerometer'),
              subtitle: Text(c.aktif ? 'Sensor aktif' : 'Sensor berhenti'),
              trailing: Icon(
                Icons.circle,
                color: c.aktif ? Colors.green : Colors.grey,
                size: 14,
              ),
            ),
          ),
          // Pesan error: tampil kalau sensor error, atau sensor dimatikan (tombol Stop)
          if (c.error != null || !c.aktif)
            Card(
              color: Colors.red.shade100,
              child: ListTile(
                leading: const Icon(Icons.error, color: Colors.red),
                title: Text(
                  c.error ?? 'Sensor dimatikan, tidak ada data yang dibaca',
                  style: const TextStyle(color: Colors.black87),
                ),
                subtitle: const Text(
                  'Tekan Mulai di pojok kanan atas untuk mengaktifkan lagi',
                  style: TextStyle(color: Colors.black54),
                ),
              ),
            ),
          const SizedBox(height: 4),
          _baris('X', c.x, Colors.red),
          _baris('Y', c.y, Colors.green),
          _baris('Z', c.z, Colors.blue),
          const SizedBox(height: 8),
          const Text(
            'Saat HP rebahan datar, nilai Z mendekati 9.8 (gravitasi).',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

// ======================= SCREEN 3: HASIL =======================
class ResultScreen extends StatelessWidget {
  final TiltController c;
  const ResultScreen({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (_, __) {
        final warna = warnaStatus(c.status);
        // Gelembung bergerak ke sisi yang lebih tinggi
        final ax = (c.x / 6).clamp(-1.0, 1.0);
        final ay = (-c.y / 6).clamp(-1.0, 1.0);

        // LayoutBuilder + scroll: latar mengisi seluruh layar,
        // dan isi tidak terpotong di HP berlayar pendek
        return LayoutBuilder(
          builder: (context, box) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: box.maxHeight),
                child: Container(
                  color: warna.withValues(alpha: 0.12),
                  padding: const EdgeInsets.all(20),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        c.status,
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          color: warna,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        c.status == 'Seimbang'
                            ? 'Perangkat relatif datar'
                            : 'Kemiringan melewati batas',
                      ),
                      const SizedBox(height: 24),
                      Container(
                        width: 260,
                        height: 260,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                          border: Border.all(color: warna, width: 6),
                        ),
                        child: Stack(
                          children: [
                            Center(
                              child: Container(
                                width: 70,
                                height: 70,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: Colors.black26, width: 2),
                                ),
                              ),
                            ),
                            Center(
                                child: Container(
                                    width: 1,
                                    height: 260,
                                    color: Colors.black12)),
                            Center(
                                child: Container(
                                    width: 260,
                                    height: 1,
                                    color: Colors.black12)),
                            AnimatedAlign(
                              duration: const Duration(milliseconds: 120),
                              alignment: Alignment(ax, ay) * 0.75,
                              child: Container(
                                width: 50,
                                height: 50,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: warna,
                                  boxShadow: const [
                                    BoxShadow(
                                        blurRadius: 6, color: Colors.black26)
                                  ],
                                ),
                                child: Icon(ikonStatus(c.status),
                                    color: Colors.white, size: 26),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'X: ${c.x.toStringAsFixed(2)}   Y: ${c.y.toStringAsFixed(2)}   Z: ${c.z.toStringAsFixed(2)}',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        c.aktif
                            ? 'Sensor aktif'
                            : 'Sensor berhenti, tekan Mulai',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ======================= SCREEN 4: RESPONS =======================
class ResponseScreen extends StatelessWidget {
  final TiltController c;
  const ResponseScreen({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (_, __) {
        final warna = warnaStatus(c.status);
        final miring = c.status != 'Seimbang';
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: warna,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: [
                  Icon(
                    miring ? Icons.warning_amber_rounded : Icons.check_circle,
                    size: 72,
                    color: Colors.white,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    miring ? 'PERINGATAN: ${c.status}' : 'Kondisi Aman',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    miring
                        ? 'Getar dan suara aktif sesuai pengaturan'
                        : 'Tidak ada respons yang dipicu',
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.vibration),
                    title: const Text('Getaran'),
                    subtitle: const Text('Getar saat status berubah ke miring'),
                    value: c.getarOn,
                    onChanged: c.setGetar,
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    secondary: const Icon(Icons.volume_up),
                    title: const Text('Suara'),
                    subtitle: const Text('Bunyi beep peringatan'),
                    value: c.suaraOn,
                    onChanged: c.setSuara,
                  ),
                ],
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.notifications_active),
                title: const Text('Jumlah pemicu'),
                trailing: Text(
                  '${c.jumlahPemicu}',
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: c.ujiGetar,
                    icon: const Icon(Icons.touch_app),
                    label: const Text('Tes Respons'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: c.reset,
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Reset'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}