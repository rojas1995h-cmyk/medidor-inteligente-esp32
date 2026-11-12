import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');

  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
  );

  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'corte_ciclo_channel',
    'Alertas de Facturación y Corte',
    description: 'Disparos automáticos al cumplirse el ciclo de 30 días',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
  );

  final AndroidFlutterLocalNotificationsPlugin? androidPlugin =
      flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  if (androidPlugin != null) {
    await androidPlugin.createNotificationChannel(channel);
    await androidPlugin.requestNotificationsPermission();
  }

  runApp(const SmartEnergyApp());
}

class SmartEnergyApp extends StatelessWidget {
  const SmartEnergyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Medidor Inteligente',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF070A11),
        fontFamily: 'sans-serif',
      ),
      home: const MainScreen(),
    );
  }
}

// ==========================================================
// MODELOS DE DATOS
// ==========================================================
class DptoModel {
  final bool rele;
  final double corriente;
  final double potencia;
  final double energia;
  final double monto;
  final bool mesFinalizado;

  DptoModel({
    required this.rele,
    required this.corriente,
    required this.potencia,
    required this.energia,
    required this.monto,
    required this.mesFinalizado,
  });

  factory DptoModel.fromJson(Map<String, dynamic> json) {
    return DptoModel(
      rele: json['rele'] ?? false,
      corriente: (json['corriente'] as num?)?.toDouble() ?? 0.0,
      potencia: (json['potencia'] as num?)?.toDouble() ?? 0.0,
      energia: (json['energia'] as num?)?.toDouble() ?? 0.0,
      monto: (json['monto'] as num?)?.toDouble() ?? 0.0,
      mesFinalizado: json['mesFinalizado'] ?? false,
    );
  }

  factory DptoModel.initial() => DptoModel(
        rele: false,
        corriente: 0.0,
        potencia: 0.0,
        energia: 0.0,
        monto: 0.0,
        mesFinalizado: false,
      );
}

class StatusModel {
  final String hora;
  final int dia;
  final bool hayRed;
  final double vRed;
  final bool sistemaEncendido;
  final double pTotal;
  final double montoTotal;
  final bool alertaBuzzer;
  final DptoModel dpto1;
  final DptoModel dpto2;

  StatusModel({
    required this.hora,
    required this.dia,
    required this.hayRed,
    required this.vRed,
    required this.sistemaEncendido,
    required this.pTotal,
    required this.montoTotal,
    required this.alertaBuzzer,
    required this.dpto1,
    required this.dpto2,
  });

  factory StatusModel.fromJson(Map<String, dynamic> json) {
    return StatusModel(
      hora: json['hora'] ?? '--:--:--',
      dia: json['dia'] ?? 1,
      hayRed: json['hayRed'] ?? false,
      vRed: (json['vRed'] as num?)?.toDouble() ?? 0.0,
      sistemaEncendido: json['sistemaEncendido'] ?? false,
      pTotal: (json['pTotal'] as num?)?.toDouble() ?? 0.0,
      montoTotal: (json['montoTotal'] as num?)?.toDouble() ?? 0.0,
      alertaBuzzer: json['alertaBuzzer'] ?? false,
      dpto1: DptoModel.fromJson(json['dpto1'] ?? {}),
      dpto2: DptoModel.fromJson(json['dpto2'] ?? {}),
    );
  }

  factory StatusModel.initial() => StatusModel(
        hora: '--:--:--',
        dia: 1,
        hayRed: false,
        vRed: 0.0,
        sistemaEncendido: false,
        pTotal: 0.0,
        montoTotal: 0.0,
        alertaBuzzer: false,
        dpto1: DptoModel.initial(),
        dpto2: DptoModel.initial(),
      );
}

// ==========================================================
// SERVICIO API REST (ESP32 SOFT-AP)
// ==========================================================
class Esp32Service {
  static const String baseUrl = 'http://192.168.4.1/api';

  static Future<StatusModel?> fetchStatus() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/status'))
          .timeout(const Duration(milliseconds: 750));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return StatusModel.fromJson(data);
      }
    } catch (_) {}
    return null;
  }

  static Future<bool> sendControl(String accion) async {
    try {
      final response = await http
          .post(Uri.parse('$baseUrl/control?accion=$accion'))
          .timeout(const Duration(milliseconds: 900));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

// ==========================================================
// PANTALLA PRINCIPAL
// ==========================================================
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;
  Timer? _pollingTimer;
  StatusModel _status = StatusModel.initial();
  bool _isConnected = false;

  bool _notificacionEnviadaDpto1 = false;
  bool _notificacionEnviadaDpto2 = false;

  @override
  void initState() {
    super.initState();
    _startPolling();
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _pollingTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      final newStatus = await Esp32Service.fetchStatus();
      if (!mounted) return;

      if (newStatus != null) {
        setState(() {
          _status = newStatus;
          _isConnected = true;
        });
        _evaluarNotificaciones(newStatus);
      } else {
        if (_isConnected) {
          setState(() {
            _isConnected = false;
          });
        }
      }
    });
  }

  void _evaluarNotificaciones(StatusModel s) {
    if (s.dpto1.mesFinalizado) {
      if (!_notificacionEnviadaDpto1) {
        _dispararNotificacionLocal(
          id: 1,
          titulo: '⚠️ Fin de Ciclo (30 Días) - Dpto 1',
          cuerpo:
              'Corte automático aplicado en Dpto 1. Monto a liquidar: S/. ${s.dpto1.monto.toStringAsFixed(2)}',
        );
        _notificacionEnviadaDpto1 = true;
      }
    } else {
      _notificacionEnviadaDpto1 = false;
    }

    if (s.dpto2.mesFinalizado) {
      if (!_notificacionEnviadaDpto2) {
        _dispararNotificacionLocal(
          id: 2,
          titulo: '⚠️ Fin de Ciclo (30 Días) - Dpto 2',
          cuerpo:
              'Corte automático aplicado en Dpto 2. Monto a liquidar: S/. ${s.dpto2.monto.toStringAsFixed(2)}',
        );
        _notificacionEnviadaDpto2 = true;
      }
    } else {
      _notificacionEnviadaDpto2 = false;
    }
  }

  Future<void> _dispararNotificacionLocal({
    required int id,
    required String titulo,
    required String cuerpo,
  }) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'corte_ciclo_channel',
      'Alertas de Facturación y Corte',
      channelDescription: 'Disparos automáticos al cumplirse el ciclo de 30 días',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'ticker',
      playSound: true,
      enableVibration: true,
    );

    const NotificationDetails generalNotificationDetails = NotificationDetails(
      android: androidDetails,
    );

    await flutterLocalNotificationsPlugin.show(
      id,
      titulo,
      cuerpo,
      generalNotificationDetails,
    );
  }

  Future<void> _ejecutarComando(String accion) async {
    final ok = await Esp32Service.sendControl(accion);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Error al enviar comando al ESP32. Verifica conexión Wi-Fi.'),
          backgroundColor: Color(0xFFFF1744),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  void _mostrarDialogoConfirmacion({
    required String titulo,
    required String mensaje,
    required VoidCallback onConfirm,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141A29),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0xFF29354D)),
        ),
        title: Text(
          titulo,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Text(
          mensaje,
          style: const TextStyle(color: Color(0xFFB0BEC5), fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CANCELAR', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00E676),
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              onConfirm();
            },
            child: const Text('CONFIRMAR', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _mostrarModalPagoExitoso({
    required String linea1,
    required String linea2,
    required String linea3,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: Color(0xFF00E676),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline, color: Colors.black, size: 60),
            const SizedBox(height: 12),
            Text(
              linea1,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 22,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              linea2,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              linea3,
              style: const TextStyle(
                color: Colors.black87,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black,
                  foregroundColor: const Color(0xFF00E676),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => Navigator.pop(ctx),
                child: const Text('ACEPTAR', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            )
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildPersistentHeader(),
            if (_status.alertaBuzzer ||
                _status.dpto1.mesFinalizado ||
                _status.dpto2.mesFinalizado)
              _buildBlinkingAlertBanner(),
            Expanded(
              child: IndexedStack(
                index: _currentIndex,
                children: [
                  _buildVistaPanelGeneral(),
                  _buildVistaDptoRecibo(dptoId: 1),
                  _buildVistaDptoRecibo(dptoId: 2),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF0B0F19),
          border: Border(top: BorderSide(color: Color(0xFF1E283D), width: 1)),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          backgroundColor: Colors.transparent,
          elevation: 0,
          selectedItemColor: const Color(0xFF00E676),
          unselectedItemColor: const Color(0xFF60728F),
          selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          onTap: (index) {
            setState(() {
              _currentIndex = index;
            });
          },
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.dashboard_outlined),
              activeIcon: Icon(Icons.dashboard),
              label: 'General',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.bolt_outlined),
              activeIcon: Icon(Icons.bolt),
              label: 'Dpto 1',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.flash_on_outlined),
              activeIcon: Icon(Icons.flash_on),
              label: 'Dpto 2',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPersistentHeader() {
    final double progresoCiclo = (_status.dia / 30.0).clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFF0B0F19),
        border: Border(bottom: BorderSide(color: Color(0xFF1C2436), width: 1)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _isConnected
                      ? const Color(0xFF00E676).withOpacity(0.12)
                      : const Color(0xFFFF1744).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: _isConnected ? const Color(0xFF00E676) : const Color(0xFFFF1744),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _isConnected ? Icons.wifi : Icons.wifi_off,
                      size: 14,
                      color: _isConnected ? const Color(0xFF00E676) : const Color(0xFFFF1744),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _isConnected ? 'ESP32 AP' : 'SIN CONEXIÓN',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: _isConnected ? const Color(0xFF00E676) : const Color(0xFFFF1744),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                _status.hora,
                style: const TextStyle(
                  color: Color(0xFFFFEA00),
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF00FFFF), width: 1.2),
                ),
                child: Text(
                  'DÍA: ${_status.dia.toString().padLeft(2, '0')}/30',
                  style: const TextStyle(
                    color: Color(0xFF00FFFF),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.power_settings_new,
                  color: _status.sistemaEncendido
                      ? const Color(0xFF00E676)
                      : const Color(0xFFFF1744),
                  size: 26,
                ),
                onPressed: () {
                  _mostrarDialogoConfirmacion(
                    titulo: _status.sistemaEncendido
                        ? '¿Apagar Sistema Completo?'
                        : '¿Encender Sistema Completo?',
                    mensaje: _status.sistemaEncendido
                        ? 'Se desactivarán ambos relés y se suspenderá la telemetría activa.'
                        : 'Se restaurará la energía y lógica del panel de control.',
                    onConfirm: () => _ejecutarComando('toggle_sistema'),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progresoCiclo,
                    backgroundColor: const Color(0xFF1E283D),
                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00FFFF)),
                    minHeight: 4,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                _status.hayRed ? 'Red AC: 220V OK' : 'Red AC: SIN RED',
                style: TextStyle(
                  color: _status.hayRed ? const Color(0xFF00E676) : const Color(0xFFFF1744),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBlinkingAlertBanner() {
    return Container(
      width: double.infinity,
      color: const Color(0xFFFF1744),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 22),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'FIN DE CICLO (30 DÍAS) - BUZZER ACTIVO',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: const Color(0xFFFF1744),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minimumSize: Size.zero,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            onPressed: () {
              if (_status.dpto1.mesFinalizado) {
                setState(() => _currentIndex = 1);
              } else if (_status.dpto2.mesFinalizado) {
                setState(() => _currentIndex = 2);
              }
            },
            child: const Text('LIQUIDAR', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildVistaPanelGeneral() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          const Text(
            'PANEL GENERAL',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.white,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 160,
            child: CustomPaint(
              painter: TacometroSemicircularPainter(
                valor: _status.sistemaEncendido ? _status.pTotal : 0.0,
                maxValor: 3000.0,
                colorFijo: const Color(0xFF00E676),
                esMulticolor: true,
              ),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _status.sistemaEncendido
                            ? '${_status.pTotal.toStringAsFixed(0)} W'
                            : '0 W',
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                        ),
                      ),
                      const Text(
                        '/ 3000 W',
                        style: TextStyle(fontSize: 12, color: Color(0xFFB0BEC5)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _buildTarjetaDptoGeneral(
                  titulo: 'DPTO 1',
                  colorAcento: const Color(0xFF00FFFF),
                  dpto: _status.dpto1,
                  sistemaEncendido: _status.sistemaEncendido,
                  onToggle: () => _ejecutarComando('toggle_rele1'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildTarjetaDptoGeneral(
                  titulo: 'DPTO 2',
                  colorAcento: const Color(0xFFFF00FF),
                  dpto: _status.dpto2,
                  sistemaEncendido: _status.sistemaEncendido,
                  onToggle: () => _ejecutarComando('toggle_rele2'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF00E676),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'TOTAL A LIQUIDAR:',
                      style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      'S/. ${_status.montoTotal.toStringAsFixed(2)}',
                      style: const TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.w900,
                        fontSize: 22,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black,
                      foregroundColor: const Color(0xFF00E676),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: () {
                      _mostrarDialogoConfirmacion(
                        titulo: 'Registrar Pago Total',
                        mensaje:
                            '¿Desea registrar el pago total de S/. ${_status.montoTotal.toStringAsFixed(2)}? Se restablecerán ambos departamentos a cero y se reiniciará el mes.',
                        onConfirm: () async {
                          await _ejecutarComando('reset_total');
                          _mostrarModalPagoExitoso(
                            linea1: 'PAGO REGISTRADO',
                            linea2: 'TOTAL CANCELADO',
                            linea3: 'NUEVO MES: S/. 0.00',
                          );
                        },
                      );
                    },
                    child: const Text(
                      'REGISTRAR PAGO TOTAL (RESET GENERAL)',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTarjetaDptoGeneral({
    required String titulo,
    required Color colorAcento,
    required DptoModel dpto,
    required bool sistemaEncendido,
    required VoidCallback onToggle,
  }) {
    final bool activo = sistemaEncendido && dpto.rele;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF101624),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorAcento, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                titulo,
                style: TextStyle(
                  color: colorAcento,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              Text(
                activo ? '(ON)' : '(OFF)',
                style: TextStyle(
                  color: activo ? const Color(0xFF00E676) : const Color(0xFFFF1744),
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${activo ? dpto.corriente.toStringAsFixed(1) : "0.0"} A',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          Text(
            '${activo ? dpto.potencia.toStringAsFixed(0) : "0"} W',
            style: const TextStyle(fontSize: 15, color: Colors.white70),
          ),
          const SizedBox(height: 6),
          Text(
            'S/. ${dpto.monto.toStringAsFixed(2)}',
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: Color(0xFFFFEA00),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: dpto.mesFinalizado
                    ? const Color(0xFF29354D)
                    : (activo ? const Color(0xFFFF1744) : colorAcento),
                foregroundColor: (activo || dpto.mesFinalizado) ? Colors.white : Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
              onPressed: dpto.mesFinalizado ? null : onToggle,
              child: Text(
                dpto.mesFinalizado
                    ? 'BLOQUEADO'
                    : (activo ? 'CORTAR' : 'ACTIVAR'),
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildVistaDptoRecibo({required int dptoId}) {
    final bool esDpto1 = (dptoId == 1);
    final String titulo = esDpto1 ? 'DPTO 1: RECIBO' : 'DPTO 2: RECIBO';
    final Color colorAcento = esDpto1 ? const Color(0xFF00FFFF) : const Color(0xFFFF00FF);
    final DptoModel dpto = esDpto1 ? _status.dpto1 : _status.dpto2;
    final bool activo = _status.sistemaEncendido && dpto.rele;
    final String toggleCmd = esDpto1 ? 'toggle_rele1' : 'toggle_rele2';
    final String resetCmd = esDpto1 ? 'reset_dpto1' : 'reset_dpto2';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Text(
            titulo,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: colorAcento,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 160,
            child: CustomPaint(
              painter: TacometroSemicircularPainter(
                valor: activo ? dpto.corriente : 0.0,
                maxValor: 15.0,
                colorFijo: colorAcento,
                esMulticolor: false,
              ),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${activo ? dpto.corriente.toStringAsFixed(2) : "0.00"} A',
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                        ),
                      ),
                      const Text(
                        '/ 15.00 A MAX',
                        style: TextStyle(fontSize: 12, color: Color(0xFFB0BEC5)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF101624),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E283D)),
            ),
            child: Column(
              children: [
                _buildFilaParametro(
                  'ESTADO:',
                  activo ? 'CONECTADO' : 'CORTADO',
                  activo ? const Color(0xFF00E676) : const Color(0xFFFF1744),
                ),
                const Divider(color: Color(0xFF1A2333)),
                _buildFilaParametro(
                  'VOLTAJE:',
                  '${_status.vRed.toStringAsFixed(1)} V',
                  Colors.white,
                ),
                const Divider(color: Color(0xFF1A2333)),
                _buildFilaParametro(
                  'CORRIENTE:',
                  '${activo ? dpto.corriente.toStringAsFixed(2) : "0.00"} A',
                  Colors.white,
                ),
                const Divider(color: Color(0xFF1A2333)),
                _buildFilaParametro(
                  'POTENCIA:',
                  '${activo ? dpto.potencia.toStringAsFixed(0) : "0"} W',
                  Colors.white,
                ),
                const Divider(color: Color(0xFF1A2333)),
                _buildFilaParametro(
                  'ENERGIA:',
                  '${dpto.energia.toStringAsFixed(2)} kWh',
                  Colors.white,
                ),
                const Divider(color: Color(0xFF1A2333)),
                _buildFilaParametro(
                  'TARIFA:',
                  'S/. 0.85 / kWh',
                  const Color(0xFFB0BEC5),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF0F1726),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colorAcento, width: 1.5),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'TOTAL A PAGAR:',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white70,
                  ),
                ),
                Text(
                  'S/. ${dpto.monto.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF00E676),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: activo ? const Color(0xFFFF1744) : colorAcento,
                      foregroundColor: activo ? Colors.white : Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: dpto.mesFinalizado
                        ? null
                        : () => _ejecutarComando(toggleCmd),
                    child: Text(
                      activo ? 'CORTAR SUMINISTRO' : 'ACTIVAR SUMINISTRO',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00E676),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () {
                      _mostrarDialogoConfirmacion(
                        titulo: 'Registrar Pago Dpto $dptoId',
                        mensaje:
                            '¿Confirmas la liquidación de S/. ${dpto.monto.toStringAsFixed(2)} para el Dpto $dptoId? Se reiniciará su acumulador y se levantará el corte.',
                        onConfirm: () async {
                          await _ejecutarComando(resetCmd);
                          _mostrarModalPagoExitoso(
                            linea1: 'PAGO REGISTRADO',
                            linea2: 'DPTO $dptoId: S/. 0.00',
                            linea3: 'NUEVO CICLO DE MEDICION',
                          );
                        },
                      );
                    },
                    child: const Text(
                      'REGISTRAR PAGO',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFilaParametro(String label, String valor, Color valorColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 13, color: Color(0xFFB0BEC5), fontWeight: FontWeight.w600),
          ),
          Text(
            valor,
            style: TextStyle(fontSize: 14, color: valorColor, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

// ==========================================================
// CUSTOM PAINTER: TACÓMETRO SEMICIRCULAR
// ==========================================================
class TacometroSemicircularPainter extends CustomPainter {
  final double valor;
  final double maxValor;
  final Color colorFijo;
  final bool esMulticolor;

  TacometroSemicircularPainter({
    required this.valor,
    required this.maxValor,
    required this.colorFijo,
    required this.esMulticolor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double cx = size.width / 2;
    final double cy = size.height * 0.85;
    final double radioExt = size.width * 0.42;
    final double radioInt = size.width * 0.33;

    final double fraccion = (valor / maxValor).clamp(0.0, 1.0);
    final int anguloCorte = 180 - (fraccion * 180.0).toInt();

    final Paint paintSegmento = Paint()
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;

    for (int deg = 180; deg >= 0; deg -= 2) {
      final double rad = deg * (math.pi / 180.0);
      final double cosA = math.cos(rad);
      final double sinA = math.sin(rad);

      Color color;
      if (deg >= anguloCorte) {
        if (esMulticolor) {
          if (deg > 115) {
            color = const Color(0xFF00E676);
          } else if (deg > 55) {
            color = const Color(0xFFFFEA00);
          } else {
            color = const Color(0xFFFF1744);
          }
        } else {
          color = colorFijo;
        }
      } else {
        color = const Color(0xFF1E283D);
      }

      paintSegmento.color = color;

      final Offset p1 = Offset(cx - (radioInt * cosA), cy - (radioInt * sinA));
      final Offset p2 = Offset(cx - (radioExt * cosA), cy - (radioExt * sinA));

      canvas.drawLine(p1, p2, paintSegmento);
    }
  }

  @override
  bool shouldRepaint(covariant TacometroSemicircularPainter oldDelegate) {
    return oldDelegate.valor != valor ||
        oldDelegate.maxValor != maxValor ||
        oldDelegate.colorFijo != colorFijo ||
        oldDelegate.esMulticolor != esMulticolor;
  }
}
