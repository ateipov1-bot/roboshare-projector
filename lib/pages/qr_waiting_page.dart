import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:package_info_plus/package_info_plus.dart';
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
  bool _refreshing = false;
  String _version = '';
  String _buildNumber = '';

  @override
  void initState() {
    super.initState();
    _getWifiName();
    _loadAppVersion();
  }

  /// Загрузить версию приложения
  Future<void> _loadAppVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          _version = packageInfo.version;
          _buildNumber = packageInfo.buildNumber;
        });
      }
    } catch (e) {
      debugPrint('❌ Ошибка получения версии приложения: $e');
    }
  }

  /// Переопределить IP (при смене сети)
  Future<void> _refreshIp() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);

    await widget.server.refreshIpAddress();
    await _getWifiName();

    if (mounted) {
      setState(() => _refreshing = false);
    }
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

    // Возвращаем просто контент без Scaffold (Scaffold уже в родителе)
    return Center(
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

                // Название Wi-Fi сети или режим хотспота
                Builder(
                  builder: (context) {
                    final ip = widget.server.ipAddress;
                    // Проверяем различные диапазоны хотспота
                    final isHotspot = ip != null && (
                      ip.startsWith('192.168.43.') ||  // Android standard
                      ip.startsWith('192.168.49.') ||  // Samsung
                      ip.startsWith('192.168.44.') ||  // Alternative
                      ip.startsWith('172.20.10.') ||   // iOS
                      (ip.endsWith('.1') && (ip.startsWith('192.168.') || ip.startsWith('172.')))  // Gateway IP
                    );
                    // Соединение есть если IP определён
                    final hasConnection = ip != null;

                    // Определяем что показывать
                    String connectionLabel;
                    String connectionValue;
                    IconData connectionIcon;
                    Color connectionColor;

                    if (isHotspot) {
                      connectionLabel = 'Режим точки доступа';
                      connectionValue = 'Hotspot';
                      connectionIcon = Icons.wifi_tethering;
                      connectionColor = Colors.blue;
                    } else if (ip != null) {
                      connectionLabel = 'Wi-Fi сеть';
                      // Показываем имя сети или "Подключено" если имя не получено
                      connectionValue = _wifiName ?? 'Подключено';
                      connectionIcon = Icons.wifi;
                      connectionColor = Colors.orange;
                    } else {
                      connectionLabel = 'Wi-Fi сеть';
                      connectionValue = 'Не подключен';
                      connectionIcon = Icons.wifi_off;
                      connectionColor = Colors.red;
                    }

                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: hasConnection
                            ? connectionColor.withValues(alpha: 0.25)
                            : Colors.red.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: hasConnection
                              ? connectionColor.withValues(alpha: 0.5)
                              : Colors.red.withValues(alpha: 0.5),
                          width: 2,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            connectionIcon,
                            color: connectionColor,
                            size: 28,
                          ),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                connectionLabel,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.white60,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                connectionValue,
                                style: TextStyle(
                                  fontSize: isHotspot ? 16 : 20,
                                  color: hasConnection ? Colors.white : Colors.red.shade100,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 16),
                          // Кнопка обновления IP
                          IconButton(
                            onPressed: _refreshing ? null : _refreshIp,
                            icon: _refreshing
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white54,
                                    ),
                                  )
                                : const Icon(Icons.refresh, color: Colors.white70, size: 24),
                            tooltip: 'Обновить IP',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ],
                      ),
                    );
                  },
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
                if (ip != null && port != null) ...[
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
                  ),
                ]
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

                // Версия приложения
                const SizedBox(height: 30),
                if (_version.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.2),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      'Версия: $_version (Build $_buildNumber)',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white70,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),

                // Отступ снизу для статуса Bluetooth
                const SizedBox(height: 30),
              ],
            ),
          ),
        ),
      );
  }
}
