// ============================================================
//  GreenFlow — Control Room Edition v5
//  Changes vs v4:
//   • Redesigned DashboardPage with semicircular needle gauge
//   • Fixed light/dark theme text colours (white on dark, dark on light)
//   • Mode-specific inline control panel on dashboard
//   • Dynamic alert banner based on moisture + connection state
//   • Smooth needle animation
// ============================================================

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kMqttHost = '16906af1bddc4f36af8ceb38bbab2ed0.s1.eu.hivemq.cloud';
const String kMqttUser = 'sasyarakshak';
const String kMqttPass = 'Saiteja3825';
const int kMqttPort = 8883;
const String kBase = 'greenflow';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF0D0F14),
  ));
  runApp(ChangeNotifierProvider(
    create: (_) => AppState()..init(),
    child: const GreenFlowApp(),
  ));
}

// ══ DESIGN TOKENS ══════════════════════════════════════════════
class T {
  // Backgrounds (dark)
  static const bg0 = Color(0xFF080A0F);
  static const bg1 = Color(0xFF0D0F14);
  static const bg2 = Color(0xFF12151C);
  static const bg3 = Color(0xFF181C25);
  static const border = Color(0xFF1F2435);

  // Accent colours
  static const blue = Color(0xFF3D8EFF);
  static const cyan = Color(0xFF00D4FF);
  static const green = Color(0xFF00C853);

  // Moisture states
  static const dry = Color(0xFFFF5252);
  static const mid = Color(0xFFFFAB00);
  static const good = Color(0xFF69C82A);
  static const wet = Color(0xFF00C853);
  static const motor = Color(0xFF00C853);
  static const off = Color(0xFF3D4459);

  // Text (dark mode)
  static const dText1 = Color(0xFFFFFFFF); // primary — pure white
  static const dText2 = Color(0xFFB0BAD0); // secondary
  static const dText3 = Color(0xFF5A6480); // tertiary / label

  // Text (light mode)
  static const lText1 = Color(0xFF0D1526); // primary — near black
  static const lText2 = Color(0xFF4A5470); // secondary
  static const lText3 = Color(0xFF9AA3BE); // tertiary / label

  // Surfaces (light)
  static const lBg = Color(0xFFF2F5FB);
  static const lCard = Colors.white;
  static const lBorder = Color(0xFFE4E9F5);

  static const blueGrad = LinearGradient(
      colors: [Color(0xFF3D8EFF), Color(0xFF00D4FF)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight);
  static const motorGrad = LinearGradient(
      colors: [Color(0xFF00A844), Color(0xFF00C853)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight);

  static Color moisture(int pct) {
    if (pct < 30) return dry;
    if (pct < 55) return mid;
    if (pct < 75) return good;
    return wet;
  }

  // Helpers that respect theme
  static Color text1(bool dark) => dark ? dText1 : lText1;
  static Color text2(bool dark) => dark ? dText2 : lText2;
  static Color text3(bool dark) => dark ? dText3 : lText3;
  static Color card(bool dark) => dark ? bg2 : lCard;
  static Color cardBorder(bool dark) => dark ? border : lBorder;
  static Color surface(bool dark) => dark ? bg1 : lBg;
}

enum IrrigationMode { manual, automatic, schedule }

enum MqttStatus { disconnected, connecting, connected, error }

extension ModeX on IrrigationMode {
  String get label => ['Manual', 'Automatic', 'Schedule'][index];
  String get desc => ['Direct control', 'Sensor-based', 'Time-based'][index];
  IconData get icon => [
        Icons.touch_app_rounded,
        Icons.auto_mode_rounded,
        Icons.schedule_rounded,
      ][index];
}

// ══ APP STATE ══════════════════════════════════════════════════
class AppState extends ChangeNotifier {
  MqttServerClient? _client;
  MqttStatus mqttStatus = MqttStatus.disconnected;
  String mqttError = '';
  List<int> moisture = [0, 0, 0, 0];
  List<bool> sensorOnline = [false, false, false, false];
  bool motorOn = false;
  IrrigationMode mode = IrrigationMode.automatic;
  int thresholdOn = 30;
  int thresholdOff = 70;
  int schedStartSec = 6 * 3600;
  int schedStopSec = 7 * 3600;
  int sensorCount = 4;
  ThemeMode themeMode = ThemeMode.dark;

  double get avgMoisture {
    final on = [
      for (int i = 0; i < sensorCount; i++)
        if (sensorOnline[i]) moisture[i]
    ];
    return on.isEmpty ? 0 : on.reduce((a, b) => a + b) / on.length;
  }

  int get onlineSensors =>
      List.generate(sensorCount, (i) => sensorOnline[i]).where((v) => v).length;
  bool get isConnected => mqttStatus == MqttStatus.connected;

  Future<void> init() async {
    await _loadPrefs();
    await _connect();
  }

  Future<void> _connect() async {
    mqttStatus = MqttStatus.connecting;
    notifyListeners();
    _client = MqttServerClient(kMqttHost, 'greenflow_app');
    _client!.port = kMqttPort;
    _client!.secure = true;
    _client!.securityContext = SecurityContext.defaultContext;
    _client!.keepAlivePeriod = 30;
    _client!.onBadCertificate = (dynamic cert) => true;
    _client!.onDisconnected = () {
      mqttStatus = MqttStatus.disconnected;
      notifyListeners();
    };
    _client!.onConnected = () {
      mqttStatus = MqttStatus.connected;
      notifyListeners();
    };
    final conn = MqttConnectMessage()
        .withClientIdentifier('greenflow_app')
        .authenticateAs(kMqttUser, kMqttPass)
        .startClean();
    _client!.connectionMessage = conn;
    try {
      await _client!.connect();
      if (_client!.connectionStatus?.state == MqttConnectionState.connected) {
        _client!.subscribe('$kBase/#', MqttQos.atMostOnce);
        _client!.updates!.listen(_onMessage);
        mqttStatus = MqttStatus.connected;
      } else {
        mqttStatus = MqttStatus.error;
        mqttError = 'rc=${_client!.connectionStatus?.returnCode}';
        _client!.disconnect();
      }
    } catch (e) {
      mqttStatus = MqttStatus.error;
      mqttError = e.toString();
      _client!.disconnect();
    }
    notifyListeners();
  }

  Future<void> reconnect() async {
    _client?.disconnect();
    await Future.delayed(const Duration(milliseconds: 400));
    await _connect();
  }

  void _onMessage(List<MqttReceivedMessage<MqttMessage>> msgs) {
    for (final msg in msgs) {
      final topic = msg.topic;
      final payload = MqttPublishPayload.bytesToStringAsString(
              (msg.payload as MqttPublishMessage).payload.message)
          .trim();
      if (topic.startsWith('$kBase/sensors/')) {
        final idx = int.tryParse(topic.split('/').last);
        if (idx != null && idx >= 1 && idx <= 4) {
          moisture[idx - 1] = (int.tryParse(payload) ?? 0).clamp(0, 100);
        }
      } else if (topic.startsWith('$kBase/sensor_conn/')) {
        final idx = int.tryParse(topic.split('/').last);
        if (idx != null && idx >= 1 && idx <= 4) {
          sensorOnline[idx - 1] = payload == '1';
        }
      } else if (topic == '$kBase/motor/state') {
        motorOn = payload == '1';
      } else if (topic == '$kBase/mode') {
        final m = int.tryParse(payload);
        if (m != null) mode = IrrigationMode.values[m.clamp(0, 2)];
      } else if (topic == '$kBase/threshold/on') {
        thresholdOn = (int.tryParse(payload) ?? 30).clamp(0, 100);
      } else if (topic == '$kBase/threshold/off') {
        thresholdOff = (int.tryParse(payload) ?? 70).clamp(0, 100);
      } else if (topic == '$kBase/schedule/start') {
        schedStartSec = int.tryParse(payload) ?? schedStartSec;
      } else if (topic == '$kBase/schedule/stop') {
        schedStopSec = int.tryParse(payload) ?? schedStopSec;
      } else if (topic == '$kBase/sensor_count') {
        sensorCount = (int.tryParse(payload) ?? 4).clamp(1, 4);
      }
      notifyListeners();
    }
  }

  void _pub(String topic, String payload) {
    if (_client?.connectionStatus?.state != MqttConnectionState.connected) {
      return;
    }
    final b = MqttClientPayloadBuilder()..addString(payload);
    _client!
        .publishMessage(topic, MqttQos.atMostOnce, b.payload!, retain: true);
  }

  void setMotor(bool on) {
    motorOn = on;
    _pub('$kBase/cmd/motor', on ? '1' : '0');
    notifyListeners();
  }

  void setMode(IrrigationMode m) {
    mode = m;
    _pub('$kBase/cmd/mode', m.index.toString());
    notifyListeners();
  }

  void setThresholdOn(int v) {
    thresholdOn = v;
    _pub('$kBase/cmd/threshold/on', v.toString());
    notifyListeners();
  }

  void setThresholdOff(int v) {
    thresholdOff = v;
    _pub('$kBase/cmd/threshold/off', v.toString());
    notifyListeners();
  }

  void setSchedStart(int s) {
    schedStartSec = s;
    _pub('$kBase/cmd/schedule/start', s.toString());
    notifyListeners();
  }

  void setSchedStop(int s) {
    schedStopSec = s;
    _pub('$kBase/cmd/schedule/stop', s.toString());
    notifyListeners();
  }

  void setSensorCount(int c) {
    sensorCount = c;
    _pub('$kBase/cmd/sensor_count', c.toString());
    notifyListeners();
  }

  void setTheme(ThemeMode t) {
    themeMode = t;
    _savePrefs();
    notifyListeners();
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    themeMode = ThemeMode.values[(p.getInt('theme') ?? 1).clamp(0, 2)];
  }

  Future<void> _savePrefs() async =>
      (await SharedPreferences.getInstance()).setInt('theme', themeMode.index);

  @override
  void dispose() {
    _client?.disconnect();
    super.dispose();
  }
}

// ══ ROOT APP ═══════════════════════════════════════════════════
class GreenFlowApp extends StatelessWidget {
  const GreenFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeMode = context.select<AppState, ThemeMode>((s) => s.themeMode);
    return MaterialApp(
      title: 'GreenFlow',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: const RootShell(),
    );
  }

  ThemeData _theme(Brightness b) {
    final dark = b == Brightness.dark;
    // Primary text colour for this brightness
    final text1 = dark ? T.dText1 : T.lText1;
    final text2 = dark ? T.dText2 : T.lText2;
    final text3 = dark ? T.dText3 : T.lText3;

    return ThemeData(
      useMaterial3: true,
      brightness: b,
      scaffoldBackgroundColor: dark ? T.bg1 : T.lBg,
      colorScheme: ColorScheme.fromSeed(
        seedColor: T.blue,
        brightness: b,
        primary: T.blue,
        secondary: T.cyan,
        surface: dark ? T.bg2 : T.lCard,
        background: dark ? T.bg1 : T.lBg,
      ),
      textTheme: TextTheme(
        displayLarge: TextStyle(
            fontSize: 52,
            fontWeight: FontWeight.w900,
            color: text1,
            letterSpacing: -2.5,
            height: 1),
        headlineLarge: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            color: text1,
            letterSpacing: -0.8),
        headlineMedium: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: text1,
            letterSpacing: -0.4),
        headlineSmall:
            TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: text1),
        titleLarge:
            TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: text1),
        titleMedium:
            TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: text1),
        bodyLarge: TextStyle(fontSize: 15, color: text2),
        bodyMedium: TextStyle(fontSize: 14, color: text2),
        labelLarge: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: text3,
            letterSpacing: 1.2),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        systemOverlayStyle:
            dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
        iconTheme: IconThemeData(color: text1, size: 22),
        titleTextStyle: TextStyle(
            color: text1,
            fontSize: 20,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: dark ? T.bg2 : T.lCard,
        height: 66,
        indicatorColor: T.blue.withOpacity(0.12),
        iconTheme: MaterialStateProperty.resolveWith((st) => IconThemeData(
            size: 24,
            color: st.contains(MaterialState.selected) ? T.blue : text3)),
        labelTextStyle: MaterialStateProperty.resolveWith((st) => TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: st.contains(MaterialState.selected) ? T.blue : text3)),
      ),
      cardTheme: CardTheme(
        color: dark ? T.bg2 : T.lCard,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: dark ? T.border : T.lBorder)),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: T.blue,
        thumbColor: T.blue,
        inactiveTrackColor: T.blue.withOpacity(0.15),
        overlayColor: T.blue.withOpacity(0.1),
        trackHeight: 5,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 11),
      ),
    );
  }
}

// ══ ROOT SHELL ═════════════════════════════════════════════════
class RootShell extends StatefulWidget {
  const RootShell({super.key});
  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: T.surface(dark),
      body: IndexedStack(
          index: _tab,
          children: const [DashboardPage(), ControlsPage(), SettingsPage()]),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
            border: Border(top: BorderSide(color: T.cardBorder(dark)))),
        child: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: const [
            NavigationDestination(
                icon: Icon(Icons.grid_view_rounded),
                selectedIcon: Icon(Icons.grid_view_rounded),
                label: 'Dashboard'),
            NavigationDestination(
                icon: Icon(Icons.tune_rounded),
                selectedIcon: Icon(Icons.tune_rounded),
                label: 'Controls'),
            NavigationDestination(
                icon: Icon(Icons.manage_accounts_outlined),
                selectedIcon: Icon(Icons.manage_accounts_rounded),
                label: 'Settings'),
          ],
        ),
      ),
    );
  }
}

// ══ DASHBOARD PAGE ═════════════════════════════════════════════
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final sensorCount = context.select<AppState, int>((s) => s.sensorCount);

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        // ── App Bar ──────────────────────────────────────────
        SliverToBoxAdapter(child: _DashAppBar(dark: dark)),

        // ── Main Moisture Card (gauge + sensor strip) ─────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _MoistureCard(dark: dark, sensorCount: sensorCount),
          ),
        ),

        // ── Motor Status + Current Mode ───────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: _MotorModeRow(dark: dark),
          ),
        ),

        // ── Alert Banner ──────────────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: _AlertBanner(dark: dark),
          ),
        ),

        // ── Mode-specific Controls ────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
            child: _ModeControlPanel(dark: dark),
          ),
        ),
      ],
    );
  }
}

// ── Dashboard App Bar ─────────────────────────────────────────
class _DashAppBar extends StatelessWidget {
  final bool dark;
  const _DashAppBar({required this.dark});

  @override
  Widget build(BuildContext context) {
    final status = context.select<AppState, MqttStatus>((s) => s.mqttStatus);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Row(
          children: [
            // Menu icon
            Icon(Icons.menu_rounded, color: T.text1(dark), size: 26),
            const SizedBox(width: 14),
            // Title block
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('GreenFlow',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          color: T.text1(dark),
                          letterSpacing: -0.4)),
                  Text('Farm Zone 1',
                      style: TextStyle(
                          fontSize: 13,
                          color: T.text2(dark),
                          fontWeight: FontWeight.w500)),
                ],
              ),
            ),
            // MQTT chip
            _MqttChip(
                status: status,
                onRetry: () => context.read<AppState>().reconnect()),
            const SizedBox(width: 10),
            // Theme toggle
            GestureDetector(
              onTap: () => context
                  .read<AppState>()
                  .setTheme(dark ? ThemeMode.light : ThemeMode.dark),
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                    color: T.card(dark),
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(color: T.cardBorder(dark))),
                child: Icon(
                    dark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                    color: T.text2(dark),
                    size: 19),
              ),
            ),
            const SizedBox(width: 8),
            // Bell
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                  color: T.card(dark),
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: T.cardBorder(dark))),
              child: Icon(Icons.notifications_outlined,
                  color: T.text2(dark), size: 19),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Main Moisture Card ────────────────────────────────────────
class _MoistureCard extends StatelessWidget {
  final bool dark;
  final int sensorCount;
  const _MoistureCard({required this.dark, required this.sensorCount});

  @override
  Widget build(BuildContext context) {
    final avg = context.select<AppState, double>((s) => s.avgMoisture);
    final online = context.select<AppState, int>((s) => s.onlineSensors);

    return Container(
      decoration: BoxDecoration(
          color: T.card(dark),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: T.cardBorder(dark))),
      child: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.eco_rounded, color: T.green, size: 18),
                const SizedBox(width: 8),
                Text('Average Soil Moisture',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: T.text1(dark))),
              ],
            ),
          ),
          Text('( $sensorCount Sensors )',
              style: TextStyle(fontSize: 13, color: T.text2(dark))),
          const SizedBox(height: 4),

          // Semicircular gauge
          _SemiGauge(
              value: online > 0 ? avg / 100.0 : 0,
              avg: avg,
              online: online,
              dark: dark),

          // Divider
          Divider(height: 1, color: T.cardBorder(dark)),

          // Sensor strip
          _SensorStrip(dark: dark, sensorCount: sensorCount),
        ],
      ),
    );
  }
}

// ── Semicircular Needle Gauge ─────────────────────────────────
class _SemiGauge extends StatefulWidget {
  final double value; // 0.0 – 1.0
  final double avg;
  final int online;
  final bool dark;
  const _SemiGauge(
      {required this.value,
      required this.avg,
      required this.online,
      required this.dark});

  @override
  State<_SemiGauge> createState() => _SemiGaugeState();
}

class _SemiGaugeState extends State<_SemiGauge>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200));
    _anim = Tween<double>(begin: 0, end: widget.value)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    _ctrl.forward();
  }

  @override
  void didUpdateWidget(_SemiGauge old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      _anim = Tween<double>(begin: _anim.value, end: widget.value)
          .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
      _ctrl
        ..reset()
        ..forward();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String get _statusLabel {
    if (widget.online == 0) return 'NO SENSORS';
    final p = widget.avg;
    if (p < 30) return 'CRITICALLY DRY';
    if (p < 55) return 'MODERATE';
    if (p < 75) return 'OPTIMAL';
    return 'SATURATED';
  }

  Color get _statusColor {
    if (widget.online == 0) return T.off;
    return T.moisture(widget.avg.round());
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) {
        return SizedBox(
          height: 220,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Gauge painter
              Positioned.fill(
                child: CustomPaint(
                  painter:
                      _SemiGaugePainter(value: _anim.value, dark: widget.dark),
                ),
              ),
              // Centre readout — positioned in lower half of the semicircle
              Positioned(
                bottom: 28,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.online > 0 ? '${widget.avg.round()}%' : '--',
                      style: TextStyle(
                          fontSize: 54,
                          fontWeight: FontWeight.w900,
                          color: T.text1(widget.dark),
                          height: 1,
                          letterSpacing: -2),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _statusLabel,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: _statusColor,
                          letterSpacing: 0.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SemiGaugePainter extends CustomPainter {
  final double value; // 0.0 – 1.0
  final bool dark;
  _SemiGaugePainter({required this.value, required this.dark});

  // Arc spans from 180° to 0° (left to right across top)
  static const double _startAngle = pi; // 180°
  static const double _sweepAngle = pi; // semicircle
  static const double _arcRadius = 100.0;
  static const double _trackWidth = 14.0;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height - 30; // anchor the base of the semicircle
    final center = Offset(cx, cy);
    final rect = Rect.fromCircle(center: center, radius: _arcRadius);

    // ── Track (background arc) ────────────────────────────────
    final trackPaint = Paint()
      ..color = (dark ? Colors.white : Colors.black).withOpacity(0.07)
      ..strokeWidth = _trackWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, _startAngle, _sweepAngle, false, trackPaint);

    // ── Gradient filled arc ───────────────────────────────────
    // Colours: red (0%) → orange → yellow → yellow-green → green (100%)
    const gradColors = [
      Color(0xFFFF3B30), // 0%   — red
      Color(0xFFFF9500), // 33%  — orange
      Color(0xFFFFCC00), // 50%  — yellow
      Color(0xFF8BC34A), // 70%  — yellow-green
      Color(0xFF00C853), // 100% — green
    ];
    final gradStops = [0.0, 0.33, 0.5, 0.7, 1.0];

    final gradPaint = Paint()
      ..shader = SweepGradient(
              colors: gradColors,
              stops: gradStops,
              startAngle: _startAngle,
              endAngle: _startAngle + _sweepAngle,
              tileMode: TileMode.clamp)
          .createShader(rect)
      ..strokeWidth = _trackWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    // Draw full gradient arc always so the colour band is always visible
    canvas.drawArc(rect, _startAngle, _sweepAngle, false, gradPaint);

    // ── Dim the portion past current value ────────────────────
    // Draw an overlay on the "future" portion so unlit section looks muted
    if (value < 1.0) {
      final dimAngle = _sweepAngle * value;
      final dimPaint = Paint()
        ..color = (dark ? T.bg2 : T.lCard).withOpacity(0.72)
        ..strokeWidth = _trackWidth
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(rect, _startAngle + dimAngle, _sweepAngle * (1 - value),
          false, dimPaint);
    }

    // ── Needle ────────────────────────────────────────────────
    final needleAngle = _startAngle + _sweepAngle * value;
    final needleLength = _arcRadius - 4.0;
    final needleTip = Offset(center.dx + needleLength * cos(needleAngle),
        center.dy + needleLength * sin(needleAngle));

    // Needle shadow
    canvas.drawLine(
        center,
        needleTip,
        Paint()
          ..color = Colors.black.withOpacity(0.18)
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round);

    // Needle body — colour matches current moisture
    final needleColor = _moistureColor(value);
    canvas.drawLine(
        center,
        needleTip,
        Paint()
          ..color = needleColor
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round);

    // Needle pivot circle
    canvas.drawCircle(
        center, 8, Paint()..color = dark ? T.bg3 : const Color(0xFFEDF0F8));
    canvas.drawCircle(center, 5, Paint()..color = needleColor);
    canvas.drawCircle(center, 2.5, Paint()..color = Colors.white);
  }

  Color _moistureColor(double v) {
    if (v < 0.3) return const Color(0xFFFF3B30);
    if (v < 0.55) return const Color(0xFFFFAB00);
    if (v < 0.75) return const Color(0xFF8BC34A);
    return const Color(0xFF00C853);
  }

  @override
  bool shouldRepaint(_SemiGaugePainter old) =>
      old.value != value || old.dark != dark;
}

// ── Sensor Strip (below gauge inside card) ────────────────────
class _SensorStrip extends StatelessWidget {
  final bool dark;
  final int sensorCount;
  const _SensorStrip({required this.dark, required this.sensorCount});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: List.generate(sensorCount, (i) {
          return Expanded(
            child: _SensorStripCell(
                index: i, dark: dark, isLast: i == sensorCount - 1),
          );
        }),
      ),
    );
  }
}

class _SensorStripCell extends StatelessWidget {
  final int index;
  final bool dark;
  final bool isLast;
  const _SensorStripCell(
      {required this.index, required this.dark, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final pct = context.select<AppState, int>((s) => s.moisture[index]);
    final online = context.select<AppState, bool>((s) => s.sensorOnline[index]);
    final color = online ? T.moisture(pct) : T.off;

    return Container(
      decoration: BoxDecoration(
          border: Border(
              right: isLast
                  ? BorderSide.none
                  : BorderSide(color: T.cardBorder(dark)))),
      child: Column(children: [
        // WiFi / connectivity icon
        Icon(online ? Icons.wifi_rounded : Icons.wifi_off_rounded,
            size: 14, color: online ? T.green : T.off),
        const SizedBox(height: 4),
        Text('Sensor ${index + 1}',
            style: TextStyle(
                fontSize: 11,
                color: T.text2(dark),
                fontWeight: FontWeight.w500)),
        const SizedBox(height: 4),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(online ? '$pct%' : '--',
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: T.text1(dark))),
          const SizedBox(width: 4),
          Icon(Icons.water_drop_rounded, size: 13, color: color),
        ]),
      ]),
    );
  }
}

// ── Motor + Mode Row ──────────────────────────────────────────
class _MotorModeRow extends StatelessWidget {
  final bool dark;
  const _MotorModeRow({required this.dark});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _MotorStatusCard(dark: dark)),
        const SizedBox(width: 12),
        Expanded(child: _CurrentModeCard(dark: dark)),
      ],
    );
  }
}

class _MotorStatusCard extends StatefulWidget {
  final bool dark;
  const _MotorStatusCard({required this.dark});
  @override
  State<_MotorStatusCard> createState() => _MotorStatusCardState();
}

class _MotorStatusCardState extends State<_MotorStatusCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _blink;

  @override
  void initState() {
    super.initState();
    _blink = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final on = context.select<AppState, bool>((s) => s.motorOn);
    return AnimatedBuilder(
      animation: _blink,
      builder: (_, __) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
            color: T.card(widget.dark),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: T.cardBorder(widget.dark))),
        child: Column(
          children: [
            Text('Motor Status',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: T.text1(widget.dark))),
            const SizedBox(height: 14),
            // Motor icon with glow when on
            Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: on
                      ? T.motor.withOpacity(0.1 + _blink.value * 0.06)
                      : (widget.dark ? T.bg3 : const Color(0xFFF0F4FF)),
                  border: Border.all(
                      color: on
                          ? T.motor.withOpacity(0.4)
                          : T.cardBorder(widget.dark))),
              child: Icon(
                  on ? Icons.water_drop_rounded : Icons.water_drop_outlined,
                  color: on ? T.motor : T.off,
                  size: 28),
            ),
            const SizedBox(height: 12),
            // ON / OFF badge
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
              decoration: BoxDecoration(
                  gradient: on ? T.motorGrad : null,
                  color: on
                      ? null
                      : (widget.dark ? T.bg3 : const Color(0xFFEEF2FC)),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(
                      color:
                          on ? Colors.transparent : T.cardBorder(widget.dark))),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: on ? Colors.white : T.off)),
                const SizedBox(width: 7),
                Text(on ? 'ON' : 'OFF',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        color: on ? Colors.white : T.text2(widget.dark),
                        letterSpacing: 1)),
              ]),
            ),
            const SizedBox(height: 8),
            Text(on ? 'Running' : 'Stopped',
                style: TextStyle(
                    fontSize: 13,
                    color: on ? T.motor : T.text2(widget.dark),
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

class _CurrentModeCard extends StatelessWidget {
  final bool dark;
  const _CurrentModeCard({required this.dark});

  @override
  Widget build(BuildContext context) {
    final mode = context.select<AppState, IrrigationMode>((s) => s.mode);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
          color: T.card(dark),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: T.cardBorder(dark))),
      child: Column(
        children: [
          Text('Current Mode',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: T.text1(dark))),
          const SizedBox(height: 14),
          // Mode icon circle
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: T.green.withOpacity(0.1),
                border: Border.all(color: T.green.withOpacity(0.3))),
            child: Icon(mode.icon, color: T.green, size: 28),
          ),
          const SizedBox(height: 12),
          Text(mode.label.toUpperCase(),
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: T.green,
                  letterSpacing: 0.5)),
          const SizedBox(height: 4),
          Text(mode.desc,
              style: TextStyle(fontSize: 12, color: T.text2(dark)),
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ── Alert Banner ──────────────────────────────────────────────
class _AlertBanner extends StatelessWidget {
  final bool dark;
  const _AlertBanner({required this.dark});

  @override
  Widget build(BuildContext context) {
    final avg = context.select<AppState, double>((s) => s.avgMoisture);
    final online = context.select<AppState, int>((s) => s.onlineSensors);
    final connected = context.select<AppState, bool>((s) => s.isConnected);

    final (icon, title, subtitle, color) = _content(avg, online, connected);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
          color: color.withOpacity(dark ? 0.1 : 0.07),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withOpacity(0.25))),
      child: Row(children: [
        Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
                shape: BoxShape.circle, color: color.withOpacity(0.15)),
            child: Icon(icon, color: color, size: 22)),
        const SizedBox(width: 14),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: T.text1(dark))),
          const SizedBox(height: 2),
          Text(subtitle, style: TextStyle(fontSize: 13, color: T.text2(dark))),
        ])),
        Icon(Icons.chevron_right_rounded, color: T.text3(dark), size: 20),
      ]),
    );
  }

  (IconData, String, String, Color) _content(
      double avg, int online, bool connected) {
    if (!connected) {
      return (
        Icons.cloud_off_rounded,
        'Not Connected',
        'Tap the status chip to reconnect.',
        T.off
      );
    }
    if (online == 0) {
      return (
        Icons.sensors_off_rounded,
        'No Sensors Online',
        'Check hardware connections.',
        T.dry
      );
    }
    final p = avg.round();
    if (p < 30) {
      return (
        Icons.warning_amber_rounded,
        'Soil is Very Dry!',
        'Consider turning on irrigation now.',
        T.dry
      );
    }
    if (p < 55) {
      return (
        Icons.water_drop_outlined,
        'Moderate Moisture',
        'Monitor levels — may need irrigation soon.',
        T.mid
      );
    }
    if (p < 75) {
      return (
        Icons.check_circle_outline_rounded,
        'All Good!',
        'Soil moisture is in optimal range.',
        T.good
      );
    }
    return (
      Icons.opacity_rounded,
      'Soil is Saturated',
      'No irrigation needed right now.',
      T.wet
    );
  }
}

// ── Mode-specific Control Panel ───────────────────────────────
class _ModeControlPanel extends StatelessWidget {
  final bool dark;
  const _ModeControlPanel({required this.dark});

  @override
  Widget build(BuildContext context) {
    final mode = context.select<AppState, IrrigationMode>((s) => s.mode);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text('Controls',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: T.text1(dark))),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          switchInCurve: Curves.easeOutCubic,
          transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                  position: Tween<Offset>(
                          begin: const Offset(0, 0.06), end: Offset.zero)
                      .animate(anim),
                  child: child)),
          child: switch (mode) {
            IrrigationMode.manual =>
              _ManualControls(dark: dark, key: const ValueKey('manual')),
            IrrigationMode.automatic =>
              _AutoControls(dark: dark, key: const ValueKey('auto')),
            IrrigationMode.schedule =>
              _ScheduleControls(dark: dark, key: const ValueKey('sched')),
          },
        ),
      ],
    );
  }
}

// Manual controls — big ON / OFF buttons
class _ManualControls extends StatelessWidget {
  final bool dark;
  const _ManualControls({required this.dark, super.key});

  @override
  Widget build(BuildContext context) {
    final on = context.select<AppState, bool>((s) => s.motorOn);
    final connected = context.select<AppState, bool>((s) => s.isConnected);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: T.card(dark),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: T.cardBorder(dark))),
      child: Column(children: [
        Text('Manual Motor Control',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: T.text1(dark))),
        const SizedBox(height: 6),
        Text('Tap a button to control the motor directly.',
            style: TextStyle(fontSize: 13, color: T.text2(dark)),
            textAlign: TextAlign.center),
        const SizedBox(height: 20),
        Row(children: [
          // START button
          Expanded(
            child: GestureDetector(
              onTap: (connected && !on)
                  ? () => context.read<AppState>().setMotor(true)
                  : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                height: 54,
                decoration: BoxDecoration(
                    gradient: (!on && connected) ? T.motorGrad : null,
                    color: (on || !connected)
                        ? (dark ? T.bg3 : const Color(0xFFF0F4FF))
                        : null,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: (!on && connected)
                            ? Colors.transparent
                            : T.cardBorder(dark)),
                    boxShadow: (!on && connected)
                        ? [
                            BoxShadow(
                                color: T.motor.withOpacity(0.35),
                                blurRadius: 16,
                                offset: const Offset(0, 4))
                          ]
                        : null),
                child:
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.play_circle_rounded,
                      color: (!on && connected) ? Colors.white : T.text3(dark),
                      size: 20),
                  const SizedBox(width: 8),
                  Text('Start Motor',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: (!on && connected)
                              ? Colors.white
                              : T.text3(dark))),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // STOP button
          Expanded(
            child: GestureDetector(
              onTap: (connected && on)
                  ? () => context.read<AppState>().setMotor(false)
                  : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                height: 54,
                decoration: BoxDecoration(
                    color: (on && connected)
                        ? T.dry.withOpacity(0.12)
                        : (dark ? T.bg3 : const Color(0xFFF0F4FF)),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: (on && connected)
                            ? T.dry.withOpacity(0.4)
                            : T.cardBorder(dark))),
                child:
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.stop_circle_rounded,
                      color: (on && connected) ? T.dry : T.text3(dark),
                      size: 20),
                  const SizedBox(width: 8),
                  Text('Stop Motor',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: (on && connected) ? T.dry : T.text3(dark))),
                ]),
              ),
            ),
          ),
        ]),
      ]),
    );
  }
}

// Automatic controls — threshold sliders
class _AutoControls extends StatefulWidget {
  final bool dark;
  const _AutoControls({required this.dark, super.key});
  @override
  State<_AutoControls> createState() => _AutoControlsState();
}

class _AutoControlsState extends State<_AutoControls> {
  double? _on, _off;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    _on ??= s.thresholdOn.toDouble();
    _off ??= s.thresholdOff.toDouble();

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: T.card(widget.dark),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: T.cardBorder(widget.dark))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Auto Threshold Settings',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: T.text1(widget.dark))),
        const SizedBox(height: 4),
        Text(
            'Motor turns ON below the ON threshold and OFF above the OFF threshold.',
            style: TextStyle(fontSize: 12, color: T.text2(widget.dark))),
        const SizedBox(height: 18),

        // ON threshold
        _ThresholdRow(
            label: 'Motor ON Below',
            value: _on!,
            color: T.dry,
            icon: Icons.power_settings_new_rounded,
            min: 10,
            max: 60,
            dark: widget.dark,
            enabled: s.isConnected,
            onChange: (v) => setState(() => _on = v),
            onEnd: (v) {
              final c = v.round().clamp(10, _off!.round() - 5);
              setState(() => _on = c.toDouble());
              s.setThresholdOn(c);
            }),
        const SizedBox(height: 14),

        // OFF threshold
        _ThresholdRow(
            label: 'Motor OFF Above',
            value: _off!,
            color: T.wet,
            icon: Icons.stop_circle_outlined,
            min: 40,
            max: 95,
            dark: widget.dark,
            enabled: s.isConnected,
            onChange: (v) => setState(() => _off = v),
            onEnd: (v) {
              final c = v.round().clamp(_on!.round() + 5, 95);
              setState(() => _off = c.toDouble());
              s.setThresholdOff(c);
            }),

        const SizedBox(height: 18),
        // Hysteresis mini-bar
        _HysteresisBar(on: _on!.round(), off: _off!.round(), dark: widget.dark),
      ]),
    );
  }
}

class _ThresholdRow extends StatelessWidget {
  final String label;
  final double value, min, max;
  final Color color;
  final IconData icon;
  final bool dark, enabled;
  final ValueChanged<double> onChange, onEnd;
  const _ThresholdRow(
      {required this.label,
      required this.value,
      required this.color,
      required this.icon,
      required this.min,
      required this.max,
      required this.dark,
      required this.enabled,
      required this.onChange,
      required this.onEnd});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Row(children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 7),
          Text(label,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: T.text1(dark))),
        ]),
        Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: color.withOpacity(0.25))),
            child: Text('${value.round()}%',
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w900, color: color))),
      ]),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
            activeTrackColor: color,
            thumbColor: color,
            inactiveTrackColor: color.withOpacity(0.1),
            overlayColor: color.withOpacity(0.08),
            trackHeight: 5,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 11)),
        child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: (max - min).round(),
            onChanged: enabled ? onChange : null,
            onChangeEnd: enabled ? onEnd : null),
      ),
    ]);
  }
}

class _HysteresisBar extends StatelessWidget {
  final int on, off;
  final bool dark;
  const _HysteresisBar(
      {required this.on, required this.off, required this.dark});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('Hysteresis Band',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: T.text2(dark))),
        Text('$on% → $off%',
            style: TextStyle(fontSize: 13, color: T.text2(dark))),
      ]),
      const SizedBox(height: 8),
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          height: 20,
          child: Row(children: [
            Flexible(
                flex: on,
                child: Container(
                    color: T.dry.withOpacity(0.75),
                    alignment: Alignment.center,
                    child: on > 14
                        ? const Text('MOTOR ON',
                            style: TextStyle(
                                fontSize: 8,
                                fontWeight: FontWeight.w900,
                                color: Colors.white,
                                letterSpacing: 0.5))
                        : null)),
            Flexible(
                flex: (off - on).clamp(1, 100),
                child: Container(
                    color: T.mid.withOpacity(0.6),
                    alignment: Alignment.center,
                    child: const Text('HOLD',
                        style: TextStyle(
                            fontSize: 8,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                            letterSpacing: 0.5)))),
            Flexible(
                flex: (100 - off).clamp(1, 100),
                child: Container(
                    color: T.wet.withOpacity(0.65),
                    alignment: Alignment.center,
                    child: (100 - off) > 12
                        ? const Text('MOTOR OFF',
                            style: TextStyle(
                                fontSize: 8,
                                fontWeight: FontWeight.w900,
                                color: Colors.white,
                                letterSpacing: 0.5))
                        : null)),
          ]),
        ),
      ),
    ]);
  }
}

// Schedule controls — time tiles + daily period display
class _ScheduleControls extends StatelessWidget {
  final bool dark;
  const _ScheduleControls({required this.dark, super.key});

  String _fmt(int s) => '${((s ~/ 3600) % 24).toString().padLeft(2, '0')}:'
      '${((s % 3600) ~/ 60).toString().padLeft(2, '0')}';

  TimeOfDay _tod(int s) =>
      TimeOfDay(hour: (s ~/ 3600) % 24, minute: (s % 3600) ~/ 60);

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: T.card(dark),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: T.cardBorder(dark))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Daily Schedule',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: T.text1(dark))),
        const SizedBox(height: 4),
        Text('Motor runs every day between the start and stop times.',
            style: TextStyle(fontSize: 12, color: T.text2(dark))),
        const SizedBox(height: 18),

        Row(children: [
          // START tile
          Expanded(
              child: _SchedTimeTile(
                  label: 'START',
                  time: _fmt(s.schedStartSec),
                  color: T.wet,
                  icon: Icons.play_circle_rounded,
                  dark: dark,
                  enabled: s.isConnected,
                  onTap: () async {
                    final t = await showTimePicker(
                        context: context, initialTime: _tod(s.schedStartSec));
                    if (t != null) {
                      s.setSchedStart(t.hour * 3600 + t.minute * 60);
                    }
                  })),
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Icon(Icons.arrow_forward_rounded,
                  color: T.text3(dark), size: 18)),
          // STOP tile
          Expanded(
              child: _SchedTimeTile(
                  label: 'STOP',
                  time: _fmt(s.schedStopSec),
                  color: T.dry,
                  icon: Icons.stop_circle_rounded,
                  dark: dark,
                  enabled: s.isConnected,
                  onTap: () async {
                    final t = await showTimePicker(
                        context: context, initialTime: _tod(s.schedStopSec));
                    if (t != null) {
                      s.setSchedStop(t.hour * 3600 + t.minute * 60);
                    }
                  })),
        ]),

        const SizedBox(height: 16),

        // Daily active period summary
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: T.blue.withOpacity(0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: T.blue.withOpacity(0.18))),
          child: Row(children: [
            Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                    gradient: T.blueGrad,
                    borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.timer_rounded,
                    color: Colors.white, size: 20)),
            const SizedBox(width: 14),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Daily Active Period',
                  style: TextStyle(fontSize: 12, color: T.text2(dark))),
              const SizedBox(height: 2),
              Text('${_fmt(s.schedStartSec)}  →  ${_fmt(s.schedStopSec)}',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.5,
                      color: T.text1(dark))),
            ]),
          ]),
        ),
      ]),
    );
  }
}

class _SchedTimeTile extends StatelessWidget {
  final String label, time;
  final Color color;
  final IconData icon;
  final bool dark, enabled;
  final VoidCallback onTap;
  const _SchedTimeTile(
      {required this.label,
      required this.time,
      required this.color,
      required this.icon,
      required this.dark,
      required this.enabled,
      required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: color.withOpacity(0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color:
                      enabled ? color.withOpacity(0.3) : T.cardBorder(dark))),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, color: color, size: 14),
              const SizedBox(width: 5),
              Text(label,
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: color,
                      letterSpacing: 1.2)),
            ]),
            const SizedBox(height: 8),
            Text(time,
                style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    color: T.text1(dark),
                    letterSpacing: -1.5,
                    height: 1)),
            const SizedBox(height: 4),
            Text(enabled ? 'Tap to change' : 'Connect first',
                style: TextStyle(fontSize: 11, color: T.text3(dark))),
          ])));
}

// ══ CONTROLS PAGE ══════════════════════════════════════════════
class ControlsPage extends StatelessWidget {
  const ControlsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final dark = Theme.of(context).brightness == Brightness.dark;
    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverAppBar(
            floating: true,
            snap: true,
            title: const Text('Controls'),
            bottom: PreferredSize(
                preferredSize: const Size.fromHeight(1),
                child: Divider(height: 1, color: T.cardBorder(dark)))),
        SliverPadding(
          padding: const EdgeInsets.all(20),
          sliver: SliverList(
              delegate: SliverChildListDelegate([
            _Lbl('OPERATION MODE', dark),
            const SizedBox(height: 10),
            _ModePicker(state: s, dark: dark),
            const SizedBox(height: 24),
            _Lbl('ACTIVE ZONES', dark),
            const SizedBox(height: 10),
            _ZonePicker(state: s, dark: dark),
            const SizedBox(height: 28),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              switchInCurve: Curves.easeOutCubic,
              transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                      position: Tween<Offset>(
                              begin: const Offset(0, 0.06), end: Offset.zero)
                          .animate(anim),
                      child: child)),
              child: s.mode == IrrigationMode.automatic
                  ? _AutoSection(
                      state: s, dark: dark, key: const ValueKey('auto'))
                  : s.mode == IrrigationMode.schedule
                      ? _SchedSection(
                          state: s, dark: dark, key: const ValueKey('sched'))
                      : _ManualSection(
                          dark: dark, key: const ValueKey('manual')),
            ),
            const SizedBox(height: 40),
          ])),
        ),
      ],
    );
  }
}

class _Lbl extends StatelessWidget {
  final String t;
  final bool dark;
  const _Lbl(this.t, this.dark);
  @override
  Widget build(BuildContext ctx) => Text(t,
      style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: T.text3(dark),
          letterSpacing: 1.2));
}

class _ModePicker extends StatelessWidget {
  final AppState state;
  final bool dark;
  const _ModePicker({required this.state, required this.dark});
  @override
  Widget build(BuildContext context) => Row(
        children: IrrigationMode.values.map((m) {
          final sel = m == state.mode;
          return Expanded(
              child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: GestureDetector(
              onTap: state.isConnected ? () => state.setMode(m) : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    gradient: sel ? T.blueGrad : null,
                    color:
                        sel ? null : (dark ? T.bg3 : const Color(0xFFF4F7FF)),
                    border: Border.all(
                        color: sel ? Colors.transparent : T.cardBorder(dark)),
                    boxShadow: sel
                        ? [
                            BoxShadow(
                                color: T.blue.withOpacity(0.35),
                                blurRadius: 16,
                                offset: const Offset(0, 4))
                          ]
                        : null),
                child: Column(children: [
                  Icon(m.icon,
                      size: 24, color: sel ? Colors.white : T.text2(dark)),
                  const SizedBox(height: 8),
                  Text(m.label,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: sel ? Colors.white : T.text2(dark))),
                  const SizedBox(height: 2),
                  Text(m.desc,
                      style: TextStyle(
                          fontSize: 10,
                          color: sel
                              ? Colors.white.withOpacity(0.6)
                              : T.text3(dark)),
                      textAlign: TextAlign.center),
                ]),
              ),
            ),
          ));
        }).toList(),
      );
}

class _ZonePicker extends StatelessWidget {
  final AppState state;
  final bool dark;
  const _ZonePicker({required this.state, required this.dark});
  @override
  Widget build(BuildContext context) => Row(
        children: List.generate(4, (i) {
          final val = i + 1;
          final sel = val == state.sensorCount;
          return Expanded(
              child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: GestureDetector(
              onTap: state.isConnected ? () => state.setSensorCount(val) : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: 62,
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    gradient: sel ? T.blueGrad : null,
                    color:
                        sel ? null : (dark ? T.bg3 : const Color(0xFFF4F7FF)),
                    border: Border.all(
                        color: sel ? Colors.transparent : T.cardBorder(dark)),
                    boxShadow: sel
                        ? [
                            BoxShadow(
                                color: T.blue.withOpacity(0.3), blurRadius: 14)
                          ]
                        : null),
                child: Center(
                    child: Text('$val',
                        style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                            color: sel ? Colors.white : T.text2(dark)))),
              ),
            ),
          ));
        }),
      );
}

class _AutoSection extends StatefulWidget {
  final AppState state;
  final bool dark;
  const _AutoSection({required this.state, required this.dark, super.key});
  @override
  State<_AutoSection> createState() => _AutoSectionState();
}

class _AutoSectionState extends State<_AutoSection> {
  late double _on, _off;
  bool _init = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_init) {
      _on = widget.state.thresholdOn.toDouble();
      _off = widget.state.thresholdOff.toDouble();
      _init = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _Lbl('MOISTURE THRESHOLDS', widget.dark),
      const SizedBox(height: 10),
      _InfoBox(
          icon: Icons.auto_mode_rounded,
          dark: widget.dark,
          text:
              'Motor turns ON when moisture is below the ON threshold and turns OFF when it rises above the OFF threshold.'),
      const SizedBox(height: 14),
      _SliderTile(
          l: 'Motor ON Below',
          value: _on,
          color: T.dry,
          icon: Icons.power_settings_new_rounded,
          min: 10,
          max: 60,
          enabled: widget.state.isConnected,
          dark: widget.dark,
          onChange: (v) => setState(() => _on = v),
          onEnd: (v) {
            final c = v.round().clamp(10, _off.round() - 5);
            setState(() => _on = c.toDouble());
            widget.state.setThresholdOn(c);
          }),
      const SizedBox(height: 12),
      _SliderTile(
          l: 'Motor OFF Above',
          value: _off,
          color: T.wet,
          icon: Icons.stop_circle_outlined,
          min: 40,
          max: 95,
          enabled: widget.state.isConnected,
          dark: widget.dark,
          onChange: (v) => setState(() => _off = v),
          onEnd: (v) {
            final c = v.round().clamp(_on.round() + 5, 95);
            setState(() => _off = c.toDouble());
            widget.state.setThresholdOff(c);
          }),
      const SizedBox(height: 14),
      _HysteresisBar(on: _on.round(), off: _off.round(), dark: widget.dark),
    ]);
  }
}

class _SliderTile extends StatelessWidget {
  final String l;
  final double value;
  final Color color;
  final IconData icon;
  final double min, max;
  final bool enabled, dark;
  final ValueChanged<double> onChange, onEnd;
  const _SliderTile(
      {required this.l,
      required this.value,
      required this.color,
      required this.icon,
      required this.min,
      required this.max,
      required this.enabled,
      required this.dark,
      required this.onChange,
      required this.onEnd});

  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
      decoration: BoxDecoration(
          color: T.card(dark),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: T.cardBorder(dark))),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Row(children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 8),
            Text(l,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: T.text1(dark)))
          ]),
          Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: color.withOpacity(0.25))),
              child: Text('${value.round()}%',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                      color: color))),
        ]),
        const SizedBox(height: 2),
        SliderTheme(
            data: SliderTheme.of(context).copyWith(
                activeTrackColor: color,
                thumbColor: color,
                inactiveTrackColor: color.withOpacity(0.1),
                overlayColor: color.withOpacity(0.08),
                trackHeight: 5,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 11)),
            child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: (max - min).round(),
                onChanged: enabled ? onChange : null,
                onChangeEnd: enabled ? onEnd : null)),
      ]));
}

class _SchedSection extends StatelessWidget {
  final AppState state;
  final bool dark;
  const _SchedSection({required this.state, required this.dark, super.key});
  String _fmt(int s) => '${((s ~/ 3600) % 24).toString().padLeft(2, '0')}:'
      '${((s % 3600) ~/ 60).toString().padLeft(2, '0')}';
  TimeOfDay _tod(int s) =>
      TimeOfDay(hour: (s ~/ 3600) % 24, minute: (s % 3600) ~/ 60);

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _Lbl('DAILY SCHEDULE', dark),
        const SizedBox(height: 10),
        _InfoBox(
            icon: Icons.schedule_rounded,
            dark: dark,
            text:
                'Motor runs every day between start and stop time. Midnight-wrap is supported.'),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
              child: _TimeTile(
                  lbl: 'START',
                  time: _fmt(state.schedStartSec),
                  color: T.wet,
                  icon: Icons.play_circle_rounded,
                  enabled: state.isConnected,
                  dark: dark,
                  onTap: () async {
                    final t = await showTimePicker(
                        context: context,
                        initialTime: _tod(state.schedStartSec));
                    if (t != null) {
                      state.setSchedStart(t.hour * 3600 + t.minute * 60);
                    }
                  })),
          const SizedBox(width: 12),
          Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dark ? T.bg3 : const Color(0xFFF4F7FF),
                  border: Border.all(color: T.cardBorder(dark))),
              child: Icon(Icons.arrow_forward_rounded,
                  color: T.text3(dark), size: 16)),
          const SizedBox(width: 12),
          Expanded(
              child: _TimeTile(
                  lbl: 'STOP',
                  time: _fmt(state.schedStopSec),
                  color: T.dry,
                  icon: Icons.stop_circle_rounded,
                  enabled: state.isConnected,
                  dark: dark,
                  onTap: () async {
                    final t = await showTimePicker(
                        context: context,
                        initialTime: _tod(state.schedStopSec));
                    if (t != null) {
                      state.setSchedStop(t.hour * 3600 + t.minute * 60);
                    }
                  })),
        ]),
        const SizedBox(height: 12),
        Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
                color: T.card(dark),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: T.cardBorder(dark))),
            child: Row(children: [
              Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                      gradient: T.blueGrad,
                      borderRadius: BorderRadius.circular(13)),
                  child: const Icon(Icons.timer_rounded,
                      color: Colors.white, size: 23)),
              const SizedBox(width: 14),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Daily Active Period',
                    style: TextStyle(
                        fontSize: 13,
                        color: T.text2(dark),
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 3),
                Text(
                    '${_fmt(state.schedStartSec)}  →  ${_fmt(state.schedStopSec)}',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5,
                        color: T.text1(dark))),
              ]),
            ])),
      ]);
}

class _TimeTile extends StatelessWidget {
  final String lbl, time;
  final Color color;
  final IconData icon;
  final bool enabled, dark;
  final VoidCallback onTap;
  const _TimeTile(
      {required this.lbl,
      required this.time,
      required this.color,
      required this.icon,
      required this.enabled,
      required this.dark,
      required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
              color: T.card(dark),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color:
                      enabled ? color.withOpacity(0.3) : T.cardBorder(dark))),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 6),
              Text(lbl,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: color,
                      letterSpacing: 1.2))
            ]),
            const SizedBox(height: 10),
            Text(time,
                style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w900,
                    color: T.text1(dark),
                    letterSpacing: -1.5,
                    height: 1)),
            const SizedBox(height: 5),
            Text(enabled ? 'Tap to change' : 'Connect first',
                style: TextStyle(fontSize: 12, color: T.text3(dark))),
          ])));
}

class _ManualSection extends StatelessWidget {
  final bool dark;
  const _ManualSection({required this.dark, super.key});
  @override
  Widget build(BuildContext context) => _InfoBox(
      icon: Icons.touch_app_rounded,
      dark: dark,
      text:
          'Manual mode active. Use the motor ON/OFF buttons on the Dashboard tab to control irrigation directly.');
}

class _InfoBox extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool dark;
  const _InfoBox({required this.icon, required this.text, required this.dark});

  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: T.blue.withOpacity(0.06),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: T.blue.withOpacity(0.15))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: T.blue, size: 19),
        const SizedBox(width: 12),
        Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 14, color: T.text2(dark), height: 1.5))),
      ]));
}

// ══ SETTINGS PAGE ══════════════════════════════════════════════
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final dark = Theme.of(context).brightness == Brightness.dark;
    return CustomScrollView(physics: const BouncingScrollPhysics(), slivers: [
      SliverAppBar(
          floating: true,
          snap: true,
          title: const Text('Settings'),
          bottom: PreferredSize(
              preferredSize: const Size.fromHeight(1),
              child: Divider(height: 1, color: T.cardBorder(dark)))),
      SliverPadding(
          padding: const EdgeInsets.all(20),
          sliver: SliverList(
              delegate: SliverChildListDelegate([
            _Lbl('APPEARANCE', dark),
            const SizedBox(height: 10),
            _SCard(dark: dark, children: [
              _SRow(
                  icon: Icons.palette_outlined,
                  label: 'Theme',
                  sub: s.themeMode == ThemeMode.dark
                      ? 'Dark'
                      : s.themeMode == ThemeMode.light
                          ? 'Light'
                          : 'System',
                  dark: dark,
                  trail: SegmentedButton<ThemeMode>(
                      segments: const [
                        ButtonSegment(
                            value: ThemeMode.light,
                            icon: Icon(Icons.light_mode_rounded, size: 15)),
                        ButtonSegment(
                            value: ThemeMode.system,
                            icon:
                                Icon(Icons.brightness_auto_rounded, size: 15)),
                        ButtonSegment(
                            value: ThemeMode.dark,
                            icon: Icon(Icons.dark_mode_rounded, size: 15)),
                      ],
                      selected: {
                        s.themeMode
                      },
                      onSelectionChanged: (v) => s.setTheme(v.first),
                      style: const ButtonStyle(
                          visualDensity: VisualDensity.compact))),
            ]),
            const SizedBox(height: 20),
            _Lbl('CONNECTION', dark),
            const SizedBox(height: 10),
            _SCard(dark: dark, children: [
              _SRow(
                  icon: s.isConnected
                      ? Icons.cloud_done_rounded
                      : Icons.cloud_off_rounded,
                  iconColor: s.isConnected ? T.wet : T.dry,
                  label: s.isConnected
                      ? 'Connected'
                      : s.mqttStatus == MqttStatus.connecting
                          ? 'Connecting…'
                          : 'Disconnected',
                  sub: kMqttHost,
                  dark: dark),
              if (!s.isConnected)
                Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                    child: SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton.icon(
                            onPressed: s.reconnect,
                            icon: const Icon(Icons.refresh_rounded, size: 18),
                            label: const Text('Reconnect',
                                style: TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w700)),
                            style: ElevatedButton.styleFrom(
                                backgroundColor: T.blue,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                    borderRadius:
                                        BorderRadius.circular(14)))))),
            ]),
            const SizedBox(height: 20),
            _Lbl('ABOUT', dark),
            const SizedBox(height: 10),
            _SCard(dark: dark, children: [
              _SRow(
                  icon: Icons.water_drop_rounded,
                  iconColor: T.blue,
                  label: 'GreenFlow',
                  sub: 'v5.0 — Control Room Edition',
                  dark: dark),
              _SRow(
                  icon: Icons.memory_rounded,
                  iconColor: T.cyan,
                  label: 'Hardware',
                  sub: 'ESP32 · ILI9341 · 4× Moisture Sensors',
                  dark: dark),
              _SRow(
                  icon: Icons.wifi_rounded,
                  iconColor: T.blue,
                  label: 'Protocol',
                  sub: 'MQTT over TLS (port 8883)',
                  dark: dark),
            ]),
            const SizedBox(height: 40),
          ]))),
    ]);
  }
}

class _SCard extends StatelessWidget {
  final List<Widget> children;
  final bool dark;
  const _SCard({required this.children, required this.dark});

  @override
  Widget build(BuildContext context) => Container(
      decoration: BoxDecoration(
          color: T.card(dark),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: T.cardBorder(dark))),
      child: Column(children: children));
}

class _SRow extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String label, sub;
  final bool dark;
  final Widget? trail;
  const _SRow(
      {required this.icon,
      required this.label,
      required this.sub,
      required this.dark,
      this.iconColor,
      this.trail});

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(children: [
        Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
                color: (iconColor ?? T.blue).withOpacity(0.1),
                borderRadius: BorderRadius.circular(11)),
            child: Icon(icon, color: iconColor ?? T.blue, size: 20)),
        const SizedBox(width: 14),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: T.text1(dark))),
          Text(sub, style: TextStyle(fontSize: 13, color: T.text2(dark))),
        ])),
        if (trail != null) trail!,
      ]));
}

// ══ MQTT STATUS CHIP ═══════════════════════════════════════════
class _MqttChip extends StatefulWidget {
  final MqttStatus status;
  final VoidCallback onRetry;
  const _MqttChip({required this.status, required this.onRetry});

  @override
  State<_MqttChip> createState() => _MqttChipState();
}

class _MqttChipState extends State<_MqttChip>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (widget.status) {
      MqttStatus.connected => (T.wet, 'Live'),
      MqttStatus.connecting => (T.mid, 'Connecting'),
      MqttStatus.error => (T.dry, 'Error'),
      _ => (T.off, 'Offline'),
    };
    return GestureDetector(
        onTap: widget.status != MqttStatus.connected ? widget.onRetry : null,
        child: AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) => Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                    color: color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: color.withOpacity(0.25))),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: color,
                          boxShadow: widget.status == MqttStatus.connected
                              ? [
                                  BoxShadow(
                                      color: color.withOpacity(
                                          0.35 + _ctrl.value * 0.35),
                                      blurRadius: 7)
                                ]
                              : null)),
                  const SizedBox(width: 7),
                  Text(label,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: color)),
                ]))));
  }
}
