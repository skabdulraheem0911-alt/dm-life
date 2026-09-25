import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DMLifeMasterApp());
}

enum AppLanguage { telugu, hindi, english, tamil, malayalam }
enum DmRole { citizen, responder, volunteer, dispatcher }

// 1. 18-BYTE BINARY SOS CODEC
class SosPacket {
  final double latitude;
  final double longitude;
  final int altitude;
  final int battery;
  final int triageCode;
  final String deviceId;

  SosPacket({
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.battery,
    required this.triageCode,
    required this.deviceId,
  });

  Uint8List toBytes() {
    final ByteData b = ByteData(18);
    b.setFloat32(0, latitude, Endian.big);
    b.setFloat32(4, longitude, Endian.big);
    b.setInt16(8, altitude, Endian.big);
    b.setUint8(10, battery.clamp(0, 100));
    b.setUint8(11, triageCode);
    final idBytes = deviceId.padRight(6, 'X').substring(0, 6).codeUnits;
    for (int i = 0; i < 6; i++) {
      b.setUint8(12 + i, idBytes[i]);
    }
    return b.buffer.asUint8List();
  }
}

// 2. OFFLINE SQLITE LOCAL DATABASE
class LocalDatabase {
  static final LocalDatabase instance = LocalDatabase._init();
  static Database? _database;
  LocalDatabase._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('dm_life_v1.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, filePath);
    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE incidents (
            id TEXT PRIMARY KEY,
            latitude REAL,
            longitude REAL,
            altitude INTEGER,
            battery INTEGER,
            triage_code INTEGER,
            timestamp INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE relief_depot (
            id TEXT PRIMARY KEY,
            name TEXT,
            water_liters INTEGER,
            food_packets INTEGER,
            medical_kits INTEGER,
            occupancy INTEGER
          )
        ''');
        await db.rawInsert('''
          INSERT INTO relief_depot VALUES ('depot_central', 'Central Relief Depot', 5000, 2000, 150, 280)
        ''');
        await db.rawInsert('''
          INSERT INTO incidents VALUES ('AP-901', 16.3080, 80.4375, 30, 22, 1, 1727180000000)
        ''');
        await db.rawInsert('''
          INSERT INTO incidents VALUES ('AP-412', 16.3115, 80.4420, 33, 78, 2, 1727180010000)
        ''');
      },
    );
  }

  Future<void> saveSos(SosPacket packet) async {
    final db = await instance.database;
    await db.insert(
      'incidents',
      {
        'id': packet.deviceId,
        'latitude': packet.latitude,
        'longitude': packet.longitude,
        'altitude': packet.altitude,
        'battery': packet.battery,
        'triage_code': packet.triageCode,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getIncidents() async {
    final db = await instance.database;
    return await db.query('incidents', orderBy: 'triage_code ASC');
  }

  Future<Map<String, dynamic>?> getDepot() async {
    final db = await instance.database;
    final res = await db.query('relief_depot', where: 'id = ?', whereArgs: ['depot_central']);
    return res.isNotEmpty ? res.first : null;
  }

  Future<void> updateSupply(String column, int delta) async {
    final db = await instance.database;
    await db.rawUpdate('UPDATE relief_depot SET $column = MAX(0, $column + ?) WHERE id = ?', [delta, 'depot_central']);
  }
}

// 3. MULTILINGUAL DICTIONARY
class DMLocale {
  static const Map<AppLanguage, Map<String, String>> dict = {
    AppLanguage.telugu: {
      'sos_tap': 'సహాయం కోసం నొక్కండి (SOS)',
      'sos_sub': '3 సెకన్లు నొక్కి పట్టుకోండి',
      'broadcasting': 'సహాయ సంకేతం వెళ్తోంది (MESH SOS)',
      'tap_stop': 'ఆపడానికి తాకండి',
      'im_safe': 'నేను క్షేమంగా ఉన్నాను',
      'shelters': 'రక్షణ శిబిరాలు',
      'flood': 'వరద రక్షణ',
      'flood_action': 'మెయిన్ కరెంట్ స్విచ్ ఆఫ్ చేయండి. వెంటనే ఎత్తైన ప్రదేశానికి వెళ్లండి. ప్రవహించే నీటిలోకి దిగవద్దు.',
      'earthquake': 'భూకంపం',
      'earthquake_action': 'వంగండి, బలమైన బల్ల కింద దాక్కోండి, పట్టుకోండి. కిటికీలు మరియు స్తంభాలకు దూరంగా ఉండండి.',
      'cyclone': 'తుఫాను',
      'cyclone_action': 'ఇంట్లోనే సురక్షితమైన గదిలో ఉండండి. కిటికీలు మూయండి. రేడియో ఆదేశాలు పాటించండి.',
      'firstaid': 'ప్రథమ చికిత్స',
      'firstaid_action': 'రక్తం కారుతున్న గాయంపై శుభ్రమైన గుడ్డతో గట్టిగా అదిమి పట్టుకోండి. కాలిన చోట చల్లటి నీరు పోయండి.',
      'wire': 'కరెంట్ వైరు ప్రమాదం',
      'wire_action': 'తెగిపడిన వైరుకు 10 మీటర్ల దూరంలో ఉండండి. కాళ్లు నేల నుంచి ఎత్తకుండా ఈడ్చుకుంటూ నడవండి.',
      'ai_title': 'రక్షణ AI అసిస్టెంట్ (ఆఫ్-లైన్)',
      'ai_hint': 'వరద, భూకంపం లేదా గాయాల గురించి అడగండి...',
      'listen': 'వినండి',
      'silence_siren': 'సైరన్ ఆపండి',
      'siren_title': 'అత్యవసర ప్రమాద హెచ్చరిక!',
      'marked_safe': 'మీరు సురక్షితంగా ఉన్నారని నమోదు చేయబడింది!',
      'ai_reject': 'నేను విపత్తులు మరియు ప్రథమ చికిత్స రక్షణ సూచనలు మాత్రమే చెప్పగలను.',
    },
    AppLanguage.hindi: {
      'sos_tap': 'मदद के लिए दबाइए (SOS)',
      'sos_sub': '3 सेकंड तक दबाकर रखें',
      'broadcasting': 'मदद संकेत प्रसारित हो रहा है',
      'tap_stop': 'रोकने के लिए छूएं',
      'im_safe': 'मैं सुरक्षित हूँ',
      'shelters': 'राहत शिविर',
      'flood': 'बाढ़ सुरक्षा',
      'flood_action': 'मुख्य बिजली स्विच बंद करें। छत पर जाएं। बहते पानी में न चलें।',
      'earthquake': 'भूकंप सुरक्षा',
      'earthquake_action': 'मजबूत मेज के नीचे झुकें और सिर ढकें। खिड़कियों से दूर रहें।',
      'cyclone': 'चक्रवात सुरक्षा',
      'cyclone_action': 'घर के अंदर रहें, सभी खिड़कियां बंद रखें। बिजली के खंभों से दूर रहें।',
      'firstaid': 'प्राथमिक उपचार',
      'firstaid_action': 'घाव पर साफ कपड़ा दबाएं। जले हुए स्थान पर 15 मिनट ठंडा पानी डालें।',
      'wire': 'बिजली का तार खतरा',
      'wire_action': 'गिरे हुए तार से 10 मीटर दूर रहें। पैर जमीन से घसीटते हुए चलें।',
      'ai_title': 'सुरक्षा AI सहायक (ऑफलाइन)',
      'ai_hint': 'बाढ़, भूकंप या प्राथमिक उपचार के बारे में पूछें...',
      'listen': 'सुनिए',
      'silence_siren': 'सायरन बंद करें',
      'siren_title': 'आपातकालीन चेतावनी सायरन!',
      'marked_safe': 'आपकी सुरक्षा की पुष्टि दर्ज कर ली गई है!',
      'ai_reject': 'मैं केवल आपदा और जीवन रक्षा प्राथमिक उपचार संबंधी उत्तर दे सकता हूँ।',
    },
    AppLanguage.english: {
      'sos_tap': 'HOLD FOR HELP (SOS)',
      'sos_sub': 'Press & hold 3 seconds',
      'broadcasting': 'BEACON BROADCASTING (MESH)',
      'tap_stop': 'Tap to Disarm',
      'im_safe': 'I AM SAFE',
      'shelters': 'SAFE SHELTERS',
      'flood': 'Flood Safety',
      'flood_action': 'Turn off main power breaker. Move to higher ground. Never walk in moving water.',
      'earthquake': 'Earthquake',
      'earthquake_action': 'DROP, COVER, and HOLD ON under a sturdy table. Stay away from windows.',
      'cyclone': 'Cyclone Alert',
      'cyclone_action': 'Stay indoors in a windowless room. Stay clear of power lines.',
      'firstaid': 'First Aid',
      'firstaid_action': 'Apply firm pressure on bleeding wounds. Cool burns under cold water.',
      'wire': 'Fallen Power Line',
      'wire_action': 'Stay at least 10 meters away. Shuffle feet together without lifting them.',
      'ai_title': 'SAFETY AI ASSISTANT (OFFLINE)',
      'ai_hint': 'Ask about floods, earthquakes, burns, wounds...',
      'listen': 'Listen',
      'silence_siren': 'SILENCE SIREN',
      'siren_title': 'EMERGENCY EVACUATION ALERT!',
      'marked_safe': 'You are marked SAFE! Relayed to nearby peers.',
      'ai_reject': 'I am strictly programmed for disaster safety and first-aid instructions only.',
    },
    AppLanguage.tamil: {
      'sos_tap': 'உதவிக்கு அழுத்தவும் (SOS)',
      'sos_sub': '3 வினாடிகள் அழுத்திப் பிடிக்கவும்',
      'broadcasting': 'உதவி சமிக்ஞை அனுப்பப்படுகிறது',
      'tap_stop': 'நிறுத்த தொடவும்',
      'im_safe': 'நான் பாதுகாப்பாக உள்ளேன்',
      'shelters': 'பாதுகாப்பு முகாம்கள்',
      'flood': 'வெள்ள பாதுகாப்பு',
      'flood_action': 'மெயின் சுவிட்சை அணைக்கவும். உடனடியாக மேல்தளத்திற்கு செல்லவும்.',
      'earthquake': 'நிலநடுக்கம்',
      'earthquake_action': 'உறுதியான மேசையின் கீழ் அமர்ந்து தலையை மூடிக் கொள்ளவும்.',
      'cyclone': 'புயல் பாதுகாப்பு',
      'cyclone_action': 'வீட்டிற்குள்ளேயே பாதுகாப்பாக இருக்கவும். ஜன்னல்களை மூடி வைக்கவும்.',
      'firstaid': 'முதலுதவி',
      'firstaid_action': 'காயத்தின் மீது சுத்தமான துணியை அழுத்திப் பிடிக்கவும்.',
      'wire': 'மின் கம்பி ஆபத்து',
      'wire_action': 'அறுந்து விழுந்த கம்பியிலிருந்து 10 மீட்டர் தள்ளி நிற்கவும்.',
      'ai_title': 'பாதுகாப்பு AI உதவியாளர்',
      'ai_hint': 'வெள்ளம், நிலநடுக்கம் பற்றி கேளுங்கள்...',
      'listen': 'கேளுங்கள்',
      'silence_siren': 'சைரனை நிறுத்து',
      'siren_title': 'அபாய எச்சரிக்கை சைரன்!',
      'marked_safe': 'பாதுகாப்பாக உள்ளீர்கள் என பதிவு செய்யப்பட்டது!',
      'ai_reject': 'பேரிடர் மற்றும் முதலுதவி கேள்விகளுக்கு மட்டுமே பதிலளிப்பேன்.',
    },
    AppLanguage.malayalam: {
      'sos_tap': 'സഹായത്തിനായി അമർത്തുക (SOS)',
      'sos_sub': '3 സെക്കൻഡ് അമർത്തിപ്പിടിക്കുക',
      'broadcasting': 'സന്ദേശം അയക്കുന്നു (MESH)',
      'tap_stop': 'നിർത്താൻ തൊടുക',
      'im_safe': 'ഞാൻ സുരക്ഷിതനാണ്',
      'shelters': 'ക്യാമ്പുകൾ',
      'flood': 'വെള്ളപ്പൊക്കം',
      'flood_action': 'മെയിൻ സ്വിച്ച് ഓഫ് ചെയ്യുക. മുകൾനിലയിലേക്ക് മാറുക.',
      'earthquake': 'ഭൂകമ്പം',
      'earthquake_action': 'മേശയുടെ അടിയിൽ ഇരിക്കുക, തല മറച്ചുപിടിക്കുക.',
      'cyclone': 'ചുഴലിക്കാറ്റ്',
      'cyclone_action': 'ജനലുകൾ അടച്ച് സുരക്ഷിതമായ മുറിയിൽ കഴിയുക.',
      'firstaid': 'പ്രഥമശുശ്രൂഷ',
      'firstaid_action': 'മുറിവിൽ വൃത്തിയുള്ള തുണി അമർത്തിപ്പിടിക്കുക.',
      'wire': 'വൈദ്യുതി കമ്പി അപകടം',
      'wire_action': 'കമ്പിയിൽ നിന്നും 10 മീറ്റർ എങ്കിലും ദൂരം പാലിക്കുക.',
      'ai_title': 'സുരക്ഷാ AI സഹായി (ഓഫ്‌ലൈൻ)',
      'ai_hint': 'വെള്ളപ്പൊക്കം, ഭൂകമ്പം ചോദിക്കാം...',
      'listen': 'കേൾക്കുക',
      'silence_siren': 'സൈറൺ നിർത്തുക',
      'siren_title': 'അടിയന്തര അപായ സൈറൺ!',
      'marked_safe': 'താങ്കൾ സുരക്ഷിതനാണ് എന്ന് രേഖപ്പെടുത്തി!',
      'ai_reject': 'ദുരന്ത നിവാരണ കാര്യങ്ങൾ മാത്രമേ ഞാൻ പറയൂ.',
    },
  };

  static String t(AppLanguage lang, String key) {
    return dict[lang]?[key] ?? dict[AppLanguage.english]![key] ?? key;
  }
}

// 4. SYNTHESIZED EMERGENCY SIREN
class EmergencySirenService {
  static final EmergencySirenService instance = EmergencySirenService._init();
  EmergencySirenService._init();

  final AudioPlayer _player = AudioPlayer();
  bool _isPlaying = false;
  bool get isPlaying => _isPlaying;

  Future<File> _generateSirenWav() async {
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/dmlife_siren.wav');
    if (await file.exists()) return file;

    const sampleRate = 44100;
    const duration = 2;
    const numSamples = sampleRate * duration;
    final samples = Int16List(numSamples);

    for (int i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      final freq = (t % 0.6 < 0.3) ? 853.0 : 960.0;
      samples[i] = (sin(2 * pi * freq * t) * 32767).toInt();
    }

    final byteData = ByteData(44 + samples.lengthInBytes);
    void writeStr(int offset, String s) {
      for (int i = 0; i < s.length; i++) {
        byteData.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    writeStr(0, 'RIFF');
    byteData.setUint32(4, 36 + samples.lengthInBytes, Endian.little);
    writeStr(8, 'WAVE');
    writeStr(12, 'fmt ');
    byteData.setUint32(16, 16, Endian.little);
    byteData.setUint16(20, 1, Endian.little);
    byteData.setUint16(22, 1, Endian.little);
    byteData.setUint32(24, sampleRate, Endian.little);
    byteData.setUint32(28, sampleRate * 2, Endian.little);
    byteData.setUint16(32, 2, Endian.little);
    byteData.setUint16(34, 16, Endian.little);
    writeStr(36, 'data');
    byteData.setUint32(40, samples.lengthInBytes, Endian.little);

    final outBytes = Uint8List(44 + samples.lengthInBytes);
    outBytes.setRange(0, 44, byteData.buffer.asUint8List());
    outBytes.setRange(44, outBytes.length, samples.buffer.asUint8List());

    await file.writeAsBytes(outBytes);
    return file;
  }

  Future<void> soundSiren() async {
    if (_isPlaying) return;
    _isPlaying = true;
    try {
      final file = await _generateSirenWav();
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.play(DeviceFileSource(file.path), volume: 1.0);
    } catch (_) {}
  }

  Future<void> stopSiren() async {
    _isPlaying = false;
    try {
      await _player.stop();
    } catch (_) {}
  }
}

// 5. APPLICATION SHELL
class DMLifeMasterApp extends StatefulWidget {
  const DMLifeMasterApp({super.key});

  @override
  State<DMLifeMasterApp> createState() => _DMLifeMasterAppState();
}

class _DMLifeMasterAppState extends State<DMLifeMasterApp> {
  bool _isBootComplete = false;
  AppLanguage _appLanguage = AppLanguage.telugu;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DM Life',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF2A2A),
          surface: Color(0xFF121212),
        ),
      ),
      home: _isBootComplete
          ? DMLifeMainDashboard(
              language: _appLanguage,
              onLanguageChanged: (l) => setState(() => _appLanguage = l),
            )
          : DMLifeTacticalBootScreen(
              onComplete: () => setState(() => _isBootComplete = true),
            ),
    );
  }
}

// 6. BOOT SCREEN
class DMLifeTacticalBootScreen extends StatefulWidget {
  final VoidCallback onComplete;
  const DMLifeTacticalBootScreen({super.key, required this.onComplete});

  @override
  State<DMLifeTacticalBootScreen> createState() => _DMLifeTacticalBootScreenState();
}

class _DMLifeTacticalBootScreenState extends State<DMLifeTacticalBootScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 2000), () {
      if (mounted) widget.onComplete();
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shield_rounded, size: 72, color: Colors.redAccent),
            SizedBox(height: 16),
            Text(
              'DM LIFE',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 4, color: Colors.white),
            ),
            SizedBox(height: 6),
            Text(
              'ZERO-NET DISASTER SAFETY MATRIX',
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 2, color: Colors.redAccent),
            ),
            SizedBox(height: 24),
            CircularProgressIndicator(strokeWidth: 2, color: Colors.redAccent),
          ],
        ),
      ),
    );
  }
}

// 7. MAIN DASHBOARD
class DMLifeMainDashboard extends StatefulWidget {
  final AppLanguage language;
  final ValueChanged<AppLanguage> onLanguageChanged;

  const DMLifeMainDashboard({super.key, required this.language, required this.onLanguageChanged});

  @override
  State<DMLifeMainDashboard> createState() => _DMLifeMainDashboardState();
}

class _DMLifeMainDashboardState extends State<DMLifeMainDashboard>
    with SingleTickerProviderStateMixin {
  DmRole _selectedRole = DmRole.citizen;
  bool _isSosActive = false;
  Position? _currentPos;
  int _battery = 100;
  List<Map<String, dynamic>> _incidents = [];
  Map<String, dynamic>? _depotData;

  String? _activeSirenDirective;
  late AnimationController _strobeAnim;
  StreamSubscription? _accelSub;

  final FlutterTts _tts = FlutterTts();
  final TextEditingController _aiInput = TextEditingController();
  final List<Map<String, String>> _aiChatHistory = [];
  bool _isSpeaking = false;

  @override
  void initState() {
    super.initState();
    _initHardwareTelemetry();
    _initAutonomousSensors();
    _refreshDb();

    _strobeAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 300))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _accelSub?.cancel();
    _strobeAnim.dispose();
    _aiInput.dispose();
    EmergencySirenService.instance.stopSiren();
    super.dispose();
  }

  Future<void> _initHardwareTelemetry() async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      final p = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 4),
      );
      final bat = await Battery().batteryLevel;
      if (mounted) setState(() { _currentPos = p; _battery = bat; });
    } catch (_) {
      if (mounted) {
        setState(() {
          _currentPos = Position(
            latitude: 16.3067,
            longitude: 80.4365,
            timestamp: DateTime.now(),
            accuracy: 4.0,
            altitude: 33.0,
            heading: 0,
            speed: 0,
            speedAccuracy: 0,
            altitudeAccuracy: 1,
            headingAccuracy: 1,
          );
        });
      }
    }
  }

  void _initAutonomousSensors() {
    try {
      _accelSub = accelerometerEventStream().listen((e) {
        final mag = sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
        if (mag > 14.5 && _activeSirenDirective == null) {
          _triggerSiren(
            'EARTHQUAKE DETECTED (భూకంపం)',
            DMLocale.t(widget.language, 'earthquake_action'),
          );
        }
      });
    } catch (_) {}
  }

  void _triggerSiren(String title, String action) {
    setState(() => _activeSirenDirective = '$title\n\n$action');
    EmergencySirenService.instance.soundSiren();
  }

  void _silenceSiren() {
    EmergencySirenService.instance.stopSiren();
    setState(() => _activeSirenDirective = null);
  }

  Future<void> _refreshDb() async {
    final inc = await LocalDatabase.instance.getIncidents();
    final dep = await LocalDatabase.instance.getDepot();
    if (mounted) setState(() { _incidents = inc; _depotData = dep; });
  }

  void _toggleSos() async {
    setState(() => _isSosActive = !_isSosActive);
    if (_isSosActive) {
      final packet = SosPacket(
        latitude: _currentPos?.latitude ?? 16.3067,
        longitude: _currentPos?.longitude ?? 80.4365,
        altitude: _currentPos?.altitude.toInt() ?? 33,
        battery: _battery,
        triageCode: 1,
        deviceId: 'MY-SOS',
      );
      await LocalDatabase.instance.saveSos(packet);
      _refreshDb();
    }
  }

  void _askAi(String text) {
    final q = text.toLowerCase().trim();
    if (q.isEmpty) return;

    final lang = widget.language;
    String answer = DMLocale.t(lang, 'ai_reject');

    if (q.contains('flood') || q.contains('water') || q.contains('వరద') || q.contains('నీరు') || q.contains('बाढ़') || q.contains('வெள்ளம்') || q.contains('വെള്ളപ്പൊക്കം')) {
      answer = DMLocale.t(lang, 'flood_action');
    } else if (q.contains('quake') || q.contains('shake') || q.contains('భూకంపం') || q.contains('भूकंप') || q.contains('நிலநடுக்கம்') || q.contains('ഭൂകമ്പം')) {
      answer = DMLocale.t(lang, 'earthquake_action');
    } else if (q.contains('cyclone') || q.contains('wind') || q.contains('తుఫాను') || q.contains('గాలి') || q.contains('तूफान') || q.contains('புயல்') || q.contains('ചുഴലിക്കാറ്റ്')) {
      answer = DMLocale.t(lang, 'cyclone_action');
    } else if (q.contains('burn') || q.contains('wound') || q.contains('blood') || q.contains('గాయం') || q.contains('కాలిన') || q.contains('चोट') || q.contains('காயம்') || q.contains('മുറിവ്')) {
      answer = DMLocale.t(lang, 'firstaid_action');
    } else if (q.contains('wire') || q.contains('electric') || q.contains('కరెంట్') || q.contains('వైరు') || q.contains('बिजली') || q.contains('तार') || q.contains('மின்சாரம்') || q.contains('വൈദ്യുതി')) {
      answer = DMLocale.t(lang, 'wire_action');
    }

    setState(() {
      _aiChatHistory.add({'q': text, 'a': answer});
      _aiInput.clear();
    });
  }

  Future<void> _speak(String text) async {
    if (_isSpeaking) {
      await _tts.stop();
      setState(() => _isSpeaking = false);
      return;
    }
    final codeMap = {
      AppLanguage.english: 'en-IN',
      AppLanguage.telugu: 'te-IN',
      AppLanguage.hindi: 'hi-IN',
      AppLanguage.tamil: 'ta-IN',
      AppLanguage.malayalam: 'ml-IN',
    };
    await _tts.setLanguage(codeMap[widget.language]!);
    setState(() => _isSpeaking = true);
    await _tts.speak(text);
  }

  @override
  Widget build(BuildContext context) {
    final lang = widget.language;
    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                _buildLanguageBar(),
                _buildTelemetryBar(lang),
                _buildRoleTabs(),
                Expanded(
                  child: IndexedStack(
                    index: _selectedRole.index,
                    children: [
                      _buildCitizenRole(lang),
                      _buildResponderRole(lang),
                      _buildVolunteerRole(lang),
                      _buildDispatcherRole(lang),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_activeSirenDirective != null) _buildSirenModal(lang),
        ],
      ),
    );
  }

  Widget _buildLanguageBar() {
    final langs = [
      {'code': AppLanguage.telugu, 'name': 'తెలుగు'},
      {'code': AppLanguage.hindi, 'name': 'हिन्दी'},
      {'code': AppLanguage.english, 'name': 'English'},
      {'code': AppLanguage.tamil, 'name': 'தமிழ்'},
      {'code': AppLanguage.malayalam, 'name': 'മലയാളം'},
    ];
    return Container(
      color: const Color(0xFF141414),
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        itemCount: langs.length,
        itemBuilder: (context, i) {
          final sel = widget.language == langs[i]['code'];
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              label: Text(
                langs[i]['name'] as String,
                style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: sel ? FontWeight.bold : FontWeight.normal),
              ),
              selected: sel,
              selectedColor: const Color(0xFFFF2A2A),
              backgroundColor: const Color(0xFF222222),
              onSelected: (_) => widget.onLanguageChanged(langs[i]['code'] as AppLanguage),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTelemetryBar(AppLanguage lang) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      color: const Color(0xFF0A0A0A),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            _currentPos != null
                ? 'GNSS: ${_currentPos!.latitude.toStringAsFixed(4)}°N, ${_currentPos!.longitude.toStringAsFixed(4)}°E'
                : 'Searching GNSS...',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.greenAccent),
          ),
          Row(
            children: [
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                icon: const Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 18),
                onPressed: () => _triggerSiren('TEST ALARM (డ్రిల్)', DMLocale.t(lang, 'cyclone_action')),
              ),
              const SizedBox(width: 8),
              Text('$_battery%', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
              const Icon(Icons.battery_charging_full_rounded, color: Colors.white70, size: 16),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildRoleTabs() {
    return Container(
      color: const Color(0xFF161616),
      height: 38,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: DmRole.values.map((r) {
          final isSel = _selectedRole == r;
          return GestureDetector(
            onTap: () => setState(() => _selectedRole = r),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: isSel ? Colors.redAccent : Colors.transparent, width: 2.5)),
              ),
              child: Text(
                r.name.toUpperCase(),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isSel ? FontWeight.w900 : FontWeight.w500,
                  color: isSel ? Colors.white : Colors.white38,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildCitizenRole(AppLanguage lang) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          GestureDetector(
            onLongPress: _toggleSos,
            child: Container(
              width: 170,
              height: 170,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isSosActive ? Colors.red.shade900 : const Color(0xFFFF2A2A),
                boxShadow: [
                  BoxShadow(
                    color: Colors.red.withOpacity(_isSosActive ? 0.9 : 0.4),
                    blurRadius: 25,
                    spreadRadius: 4,
                  ),
                ],
              ),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(_isSosActive ? Icons.wifi_tethering_rounded : Icons.sos_rounded, size: 54, color: Colors.white),
                    const SizedBox(height: 6),
                    Text(
                      _isSosActive ? DMLocale.t(lang, 'broadcasting') : DMLocale.t(lang, 'sos_tap'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    Text(
                      _isSosActive ? DMLocale.t(lang, 'tap_stop') : DMLocale.t(lang, 'sos_sub'),
                      style: const TextStyle(color: Colors.white70, fontSize: 10),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00C853), padding: const EdgeInsets.symmetric(vertical: 14)),
                  icon: const Icon(Icons.check_circle_rounded, color: Colors.white),
                  label: Text(DMLocale.t(lang, 'im_safe'), style: const TextStyle(fontWeight: FontWeight.bold)),
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(backgroundColor: Colors.green.shade900, content: Text(DMLocale.t(lang, 'marked_safe'))),
                    );
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1565C0), padding: const EdgeInsets.symmetric(vertical: 14)),
                  icon: const Icon(Icons.home_work_rounded, color: Colors.white),
                  label: Text(DMLocale.t(lang, 'shelters'), style: const TextStyle(fontWeight: FontWeight.bold)),
                  onPressed: () {},
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _buildQuickActionGrid(lang),
          const SizedBox(height: 20),
          _buildAiAssistantBox(lang),
        ],
      ),
    );
  }

  Widget _buildQuickActionGrid(AppLanguage lang) {
    final items = [
      {'title': DMLocale.t(lang, 'flood'), 'body': DMLocale.t(lang, 'flood_action'), 'icon': Icons.flood_rounded, 'color': Colors.blue},
      {'title': DMLocale.t(lang, 'earthquake'), 'body': DMLocale.t(lang, 'earthquake_action'), 'icon': Icons.vibration_rounded, 'color': Colors.orange},
      {'title': DMLocale.t(lang, 'cyclone'), 'body': DMLocale.t(lang, 'cyclone_action'), 'icon': Icons.cyclone_rounded, 'color': Colors.cyan},
      {'title': DMLocale.t(lang, 'firstaid'), 'body': DMLocale.t(lang, 'firstaid_action'), 'icon': Icons.medical_services_rounded, 'color': Colors.red},
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 1.4,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final it = items[i];
        return InkWell(
          onTap: () {
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: const Color(0xFF1E1E1E),
                title: Text(it['title'] as String),
                content: Text(it['body'] as String),
                actions: [
                  TextButton.icon(
                    icon: const Icon(Icons.volume_up, color: Colors.amberAccent),
                    label: Text(DMLocale.t(lang, 'listen')),
                    onPressed: () => _speak(it['body'] as String),
                  ),
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
                ],
              ),
            );
          },
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF181818),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: (it['color'] as Color).withOpacity(0.4)),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(it['icon'] as IconData, size: 30, color: it['color'] as Color),
                const SizedBox(height: 4),
                Text(it['title'] as String, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAiAssistantBox(AppLanguage lang) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.smart_toy_rounded, color: Colors.redAccent, size: 18),
              const SizedBox(width: 8),
              Text(DMLocale.t(lang, 'ai_title'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 8),
          if (_aiChatHistory.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: const Color(0xFF202020), borderRadius: BorderRadius.circular(6)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_aiChatHistory.last['a']!, style: const TextStyle(fontSize: 12, height: 1.4)),
                  TextButton.icon(
                    icon: const Icon(Icons.volume_up, size: 16),
                    label: Text(DMLocale.t(lang, 'listen')),
                    onPressed: () => _speak(_aiChatHistory.last['a']!),
                  )
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _aiInput,
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    hintText: DMLocale.t(lang, 'ai_hint'),
                    hintStyle: const TextStyle(fontSize: 11, color: Colors.white30),
                    filled: true,
                    fillColor: const Color(0xFF0F0F0F),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                  ),
                  onSubmitted: _askAi,
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                style: IconButton.styleFrom(backgroundColor: const Color(0xFFFF2A2A)),
                icon: const Icon(Icons.send, size: 16, color: Colors.white),
                onPressed: () => _askAi(_aiInput.text),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildResponderRole(AppLanguage lang) {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _incidents.length,
      itemBuilder: (context, i) {
        final inc = _incidents[i];
        final code = inc['triage_code'] ?? 1;
        final col = code == 1 ? Colors.red : Colors.orange;
        return Card(
          color: const Color(0xFF161616),
          shape: RoundedRectangleBorder(side: BorderSide(color: col, width: 1.2), borderRadius: BorderRadius.circular(6)),
          child: ListTile(
            leading: Icon(Icons.person_pin_circle_rounded, color: col, size: 32),
            title: Text('ID: ${inc['id']} (Code $code)', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            subtitle: Text('GNSS: ${inc['latitude']}, ${inc['longitude']} • Batt: ${inc['battery']}%', style: const TextStyle(fontSize: 11, color: Colors.white60)),
            trailing: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: col),
              onPressed: () {},
              child: const Text('RESCUE', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 11)),
            ),
          ),
        );
      },
    );
  }

  Widget _buildVolunteerRole(AppLanguage lang) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_depotData?['name'] ?? 'Relief Camp Depot', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          const Text('Local Inventory • Offline State', style: TextStyle(fontSize: 10, color: Colors.white38)),
          const SizedBox(height: 12),
          _buildSupplyTile('Clean Drinking Water (L)', _depotData?['water_liters'] ?? 0, 'water_liters'),
          _buildSupplyTile('Emergency Food Rations', _depotData?['food_packets'] ?? 0, 'food_packets'),
          _buildSupplyTile('First Aid & Trauma Kits', _depotData?['medical_kits'] ?? 0, 'medical_kits'),
          _buildSupplyTile('Shelter Occupants', _depotData?['occupancy'] ?? 0, 'occupancy'),
        ],
      ),
    );
  }

  Widget _buildSupplyTile(String title, int count, String col) {
    return Card(
      color: const Color(0xFF161616),
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline, size: 18),
                  onPressed: () async {
                    await LocalDatabase.instance.updateSupply(col, -10);
                    _refreshDb();
                  },
                ),
                Text('$count', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline, color: Colors.greenAccent, size: 18),
                  onPressed: () async {
                    await LocalDatabase.instance.updateSupply(col, 10);
                    _refreshDb();
                  },
                ),
              ],
            )
          ],
        ),
      ),
    );
  }

  Widget _buildDispatcherRole(AppLanguage lang) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('SITUATION MATRIX', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Row(
            children: [
              _buildStatBox('CRITICAL RED', '${_incidents.where((i) => i['triage_code'] == 1).length}', Colors.red),
              const SizedBox(width: 8),
              _buildStatBox('SHELTER OCCUPANTS', '${_depotData?['occupancy'] ?? 0}', Colors.blueAccent),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Container(
              decoration: BoxDecoration(color: const Color(0xFF101010), borderRadius: BorderRadius.circular(8)),
              child: const Center(
                child: Text('Offline Tactical Mesh Matrix • 100% Air-Gapped', style: TextStyle(color: Colors.white38, fontSize: 11)),
              ),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildStatBox(String title, String val, Color c) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: const Color(0xFF161616), borderRadius: BorderRadius.circular(6), border: Border.all(color: c.withOpacity(0.5))),
        child: Column(
          children: [
            Text(title, style: TextStyle(color: c, fontSize: 10, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(val, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _buildSirenModal(AppLanguage lang) {
    return AnimatedBuilder(
      animation: _strobeAnim,
      builder: (context, _) {
        final isRed = _strobeAnim.value > 0.5;
        return Container(
          color: isRed ? const Color(0xFFFF0000) : const Color(0xFF350000),
          width: double.infinity,
          height: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                DMLocale.t(lang, 'siren_title'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Colors.white),
              ),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(10)),
                child: Text(
                  _activeSirenDirective ?? '',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
                icon: const Icon(Icons.volume_off_rounded),
                label: Text(DMLocale.t(lang, 'silence_siren'), style: const TextStyle(fontWeight: FontWeight.bold)),
                onPressed: _silenceSiren,
              ),
            ],
          ),
        );
      },
    );
  }
}
