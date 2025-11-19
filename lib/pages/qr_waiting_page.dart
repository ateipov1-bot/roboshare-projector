import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/http_server.dart';

class QRWaitingPage extends StatefulWidget {
  final ProjectorHttpServer server;

  const QRWaitingPage({
    super.key,
    required this.server,
  });

  @override
  State<QRWaitingPage> createState() => _QRWaitingPageState();
}

class _QRWaitingPageState extends State<QRWaitingPage> {
  String? _wifiName;

  @override
  void initState() {
    super.initState();
    _getWifiName();
  }

  /// Получить название Wi-Fi сети
  Future<void> _getWifiName() async {
    try {
      // Запрашиваем разрешение на доступ к местоположению (требуется для получения Wi-Fi на Android 10+)
      final status = await Permission.locationWhenInUse.request();
      debugPrint('📍 Статус разрешения на местоположение: $status');

      if (status.isGranted || status.isLimited) {
        final info = NetworkInfo();
        final wifiName = await info.getWifiName();
        debugPrint('🔍 Получено название Wi-Fi: $wifiName');
        if (mounted) {
          setState(() {
            _wifiName = wifiName?.replaceAll('"', ''); // Убираем кавычки
          });
          debugPrint('✅ Wi-Fi название установлено: $_wifiName');
        }
      } else {
        debugPrint('⚠️ Разрешение на местоположение не получено: $status');
        if (mounted) {
          setState(() {
            _wifiName = null; // Показываем "Не подключен"
          });
        }
      }
    } catch (e) {
      debugPrint('❌ Ошибка получения Wi-Fi: $e');
      if (mounted) {
        setState(() {
          _wifiName = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ip = widget.server.ipAddress;
    final port = widget.server.port;

    // Формируем данные для QR кода
    final qrData = ip != null && port != null
        ? 'roboshare://connect?ip=$ip&port=$port'
        : 'error';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 30),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Заголовок
                const Text(
                  'RoboShare Projector',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.orange,
                  ),
                ),
                const SizedBox(height: 20),

                // Название Wi-Fi сети (крупно сверху)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: _wifiName != null
                        ? Colors.orange.withValues(alpha: 0.25)
                        : Colors.red.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _wifiName != null
                          ? Colors.orange.withValues(alpha: 0.5)
                          : Colors.red.withValues(alpha: 0.5),
                      width: 2,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _wifiName != null ? Icons.wifi : Icons.wifi_off,
                        color: _wifiName != null ? Colors.orange : Colors.red,
                        size: 28,
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Wi-Fi сеть',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white60,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _wifiName ?? 'Не подключен',
                            style: TextStyle(
                              fontSize: 20,
                              color: _wifiName != null ? Colors.white : Colors.red.shade100,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

                // Инструкция
                const Text(
                  'Отсканируйте QR-код с мобильного приложения',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 15),

                // QR код или ошибка
                if (ip != null && port != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: QrImageView(
                      data: qrData,
                      version: QrVersions.auto,
                      size: 200,
                      backgroundColor: Colors.white,
                    ),
                  )
                else
                  Container(
                    width: 400,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.shade900,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.error_outline,
                          size: 28,
                          color: Colors.white,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Ошибка получения IP адреса',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Divider(color: Colors.white30),
                        const SizedBox(height: 8),
                        const Text(
                          'Диагностика:',
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.white70,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          constraints: const BoxConstraints(maxHeight: 120),
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: widget.server.diagnosticLogs.map((log) {
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 1),
                                  child: Text(
                                    log,
                                    style: const TextStyle(
                                      fontSize: 8,
                                      color: Colors.white,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                const SizedBox(height: 15),

                // Индикатор ожидания
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.orange),
                      ),
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Ожидание подключения...',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white54,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
