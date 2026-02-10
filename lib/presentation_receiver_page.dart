import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';
import 'services/http_server.dart';
import 'pages/qr_waiting_page.dart';

class PresentationReceiverPage extends StatefulWidget {
  const PresentationReceiverPage({super.key});

  @override
  State<PresentationReceiverPage> createState() =>
      _PresentationReceiverPageState();
}

class _PresentationReceiverPageState extends State<PresentationReceiverPage> {
  bool _listening = true;
  bool _downloading = false;
  bool _isLoadingPages = false;
  String? _pdfPath;
  RawDatagramSocket? _socket;
  Timer? _beaconTimer; // Таймер для отправки beacon на телефон-хотспот

  // PDF document and page cache
  PdfDocument? _doc;
  final Map<int, PdfPageImage?> _pageCache = {};
  int _currentPage = 0;
  int _pageCount = 0;

  // 🔍 DEBUG: Логи для диагностики
  final List<String> _debugLogs = [];
  bool _showDebugPanel = false;

  void _log(String message) {
    final timestamp = DateTime.now().toString().substring(11, 19);
    final logEntry = '[$timestamp] $message';
    debugPrint(logEntry);
    if (mounted) {
      setState(() {
        _debugLogs.add(logEntry);
        if (_debugLogs.length > 50) {
          _debugLogs.removeAt(0);
        }
      });
    }
  }

  void _hideDebugPanel() {
    setState(() => _showDebugPanel = false);
  }

  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _portController =
      TextEditingController(text: "8080");

  final ProjectorHttpServer _httpServer = ProjectorHttpServer();

  @override
  void initState() {
    super.initState();
    _startHttpServer();
    _startListeningForServer();
  }

  /// Обработка PDF байтов, полученных напрямую через HTTP (офлайн режим)
  Future<void> _handleDirectPdfBytes(Uint8List pdfBytes) async {
    _log('HTTP Direct: PDF received, ${pdfBytes.length} bytes');

    setState(() {
      _listening = false;
      _downloading = true;
    });

    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/presentation.pdf');
      await file.create(recursive: true);
      await file.writeAsBytes(pdfBytes);

      _log('HTTP Direct: PDF saved to ${file.path}');

      setState(() {
        _pdfPath = file.path;
        _downloading = false;
      });

      await _openDocument(file.path);
    } catch (e) {
      _log('HTTP Direct: Error saving PDF: $e');
      setState(() {
        _downloading = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка сохранения PDF: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _startHttpServer() async {
    setState(() => _listening = true);

    _httpServer.onPdfUrlReceived = (pdfUrl) {
      debugPrint('📥 Получен PDF URL через HTTP: $pdfUrl');
      _downloadPdfFromUrl(pdfUrl);
    };

    // Обработчик для приёма PDF байтов напрямую (офлайн режим)
    _httpServer.onPdfBytesReceived = (pdfBytes) {
      debugPrint('📥 Получены PDF байты напрямую: ${pdfBytes.length} bytes');
      _handleDirectPdfBytes(pdfBytes);
    };

    final started = await _httpServer.start(port: 8081);

    if (mounted) {
      setState(() {});
    }

    if (!started) {
      debugPrint('❌ Не удалось запустить HTTP-сервер');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ошибка запуска сервера'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _startListeningForServer() async {
    try {
      _socket?.close();
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 54545);
      debugPrint('📡 UDP слушатель запущен на порту 54545');
      setState(() => _listening = true);

      _socket!.listen((e) async {
        if (e == RawSocketEvent.read) {
          final datagram = _socket!.receive();
          if (datagram != null) {
            final senderIp = datagram.address.address;
            final senderPort = datagram.port;
            final msg = String.fromCharCodes(datagram.data);
            debugPrint('📥 UDP пакет от $senderIp:$senderPort');
            debugPrint('   Содержимое: $msg');

            if (msg.startsWith("RoboShareServer:")) {
              final parts = msg.split(":");
              if (parts.length >= 3) {
                final ip = parts[1];
                final port = parts[2];
                debugPrint('✅ Распознан сервер: $ip:$port');
                _socket!.close();
                await _downloadAndShowPdf(ip, port);
              } else {
                debugPrint('❌ Неверный формат сообщения: недостаточно частей');
              }
            } else {
              debugPrint('⚠️ Неизвестный формат сообщения');
            }
          }
        }
      });
    } catch (e) {
      debugPrint("❌ UDP error: $e");
    }

    // Запускаем отправку beacon для случая когда телефон - хотспот
    _startBeaconBroadcast();
  }

  /// Отправляем UDP beacon на gateway (телефон-хотспот) каждые 2 секунды
  /// Это нужно потому что Android блокирует UDP broadcast ОТ хотспота к клиентам,
  /// но разрешает UDP от клиентов К хотспоту
  void _startBeaconBroadcast() {
    _beaconTimer?.cancel();

    _beaconTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!_listening) {
        timer.cancel();
        return;
      }

      try {
        final ip = _httpServer.ipAddress;
        final port = _httpServer.port;

        if (ip == null || port == null) return;

        // Определяем gateway (телефон-хотспот) - обычно .1 в подсети
        final parts = ip.split('.');
        if (parts.length != 4) return;

        final gatewayIp = '${parts[0]}.${parts[1]}.${parts[2]}.1';

        // Если мы сами gateway (.1), не отправляем beacon
        if (ip == gatewayIp) return;

        // Отправляем beacon на gateway
        final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        final message = 'RoboShareProjector:$ip:$port';

        socket.send(
          message.codeUnits,
          InternetAddress(gatewayIp),
          54546, // Другой порт для beacon от проектора
        );

        socket.close();
        debugPrint('📡 Beacon отправлен на $gatewayIp:54546 ($message)');
      } catch (e) {
        // Игнорируем ошибки beacon
      }
    });
  }

  Future<void> _downloadPdfFromUrl(String pdfUrl) async {
    setState(() {
      _listening = false;
      _downloading = true;
    });

    _log('📥 Начало загрузки PDF');
    _log('URL: ${pdfUrl.length > 60 ? '${pdfUrl.substring(0, 60)}...' : pdfUrl}');

    try {
      final resp = await http.get(Uri.parse(pdfUrl)).timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          throw Exception('Timeout: сервер не отвечает более 60 секунд');
        },
      );

      _log('✅ HTTP ${resp.statusCode}');
      _log('Body size: ${resp.bodyBytes.length} bytes');

      if (resp.statusCode == 200) {
        final header = String.fromCharCodes(resp.bodyBytes.take(10));
        _log('File header: "$header"');

        if (!header.startsWith('%PDF-')) {
          _log('❌ NOT A PDF FILE!');
          throw Exception('Файл не является PDF! Заголовок: $header');
        }

        final dir = await getApplicationSupportDirectory();
        final file = File('${dir.path}/presentation.pdf');
        await file.create(recursive: true);
        await file.writeAsBytes(resp.bodyBytes);
        _log('💾 Saved: ${await file.length()} bytes');

        setState(() {
          _pdfPath = file.path;
          _downloading = false;
        });

        await _openDocument(file.path);
      } else {
        _log('❌ HTTP Error: ${resp.statusCode}');
        throw Exception("Ошибка загрузки (${resp.statusCode})");
      }
    } catch (e, st) {
      _log("❌ EXCEPTION: $e");
      _log("Stack: ${st.toString().split('\n').take(3).join(' | ')}");
      setState(() => _downloading = false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка загрузки PDF: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 10),
          ),
        );
      }
    }
  }

  Future<void> _downloadAndShowPdf(String ip, String port) async {
    setState(() {
      _listening = false;
      _downloading = true;
    });

    final url = "http://$ip:$port/pdf";
    debugPrint('📥 Начало загрузки PDF с $url');

    try {
      final resp = await http.get(Uri.parse(url)).timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw Exception('Timeout: сервер не отвечает более 30 секунд');
        },
      );

      debugPrint('✅ Ответ получен: ${resp.statusCode}');

      if (resp.statusCode == 200) {
        final header = String.fromCharCodes(resp.bodyBytes.take(5));

        if (!header.startsWith('%PDF-')) {
          throw Exception('Файл не является PDF! Заголовок: $header');
        }

        final dir = await getApplicationSupportDirectory();
        final file = File('${dir.path}/presentation.pdf');
        await file.create(recursive: true);
        await file.writeAsBytes(resp.bodyBytes);
        debugPrint('💾 PDF сохранён в ${file.path}');

        setState(() {
          _pdfPath = file.path;
          _downloading = false;
        });

        await _openDocument(file.path);
      } else {
        throw Exception("Ошибка загрузки (${resp.statusCode})");
      }
    } catch (e, st) {
      debugPrint("❌ Ошибка загрузки: $e");
      debugPrint("Stack trace: $st");
      setState(() => _downloading = false);

      String errorMessage = 'Ошибка загрузки: $e';

      if (e.toString().contains('No route to host')) {
        errorMessage = 'Не удается подключиться к $ip:$port\n\n'
            'Проверьте:\n'
            '• Проектор и телефон в одной сети?\n'
            '• IP адрес телефона: $ip\n'
            '• Попробуйте подключиться вручную';
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 10),
            action: SnackBarAction(
              label: 'Вручную',
              textColor: Colors.white,
              onPressed: _manualConnectDialog,
            ),
          ),
        );
      }
    }
  }

  Future<void> _openDocument(String path) async {
    _log('📖 Opening PDF: $path');
    setState(() => _isLoadingPages = true);

    try {
      final doc = await PdfDocument.openFile(path);
      _doc = doc;
      final count = doc.pagesCount;
      _log('📄 PDF has $count pages');

      setState(() {
        _pageCount = count;
        _currentPage = 0;
      });

      // Render first page immediately
      await _renderPage(0);

      setState(() => _isLoadingPages = false);

      // Render remaining pages in background
      _renderRemainingPages();
    } catch (e) {
      _log('❌ Error opening PDF: $e');
      setState(() => _isLoadingPages = false);
    }
  }

  Future<void> _renderPage(int pageNum) async {
    final doc = _doc;
    if (doc == null || pageNum < 0 || pageNum >= _pageCount) return;
    if (_pageCache.containsKey(pageNum)) return;

    _log('📄 Rendering page ${pageNum + 1}/$_pageCount...');

    PdfPage? page;
    try {
      // Check before getting page
      if (_doc != doc) return;

      page = await doc.getPage(pageNum + 1);

      // Check before rendering
      if (_doc != doc) {
        await page.close();
        return;
      }

      final img = await page.render(
        width: page.width * 2,
        height: page.height * 2,
        format: PdfPageImageFormat.png,
        backgroundColor: '#FFFFFF',
      );

      await page.close();
      page = null;

      // Check after rendering
      if (_doc != doc) return;

      if (mounted) {
        setState(() {
          _pageCache[pageNum] = img;
        });
      }
    } catch (e) {
      // Ignore "document already closed" errors - it's expected when switching documents
      final errorStr = e.toString();
      if (!errorStr.contains('AlreadyClosed') && !errorStr.contains('already closed')) {
        _log('❌ Page ${pageNum + 1} ERROR: $e');
      }
      // Try to close page if it was opened
      try {
        await page?.close();
      } catch (_) {}
    }
  }

  Future<void> _renderRemainingPages() async {
    final doc = _doc;
    if (doc == null) return;

    final count = _pageCount;
    for (int i = 1; i < count; i++) {
      // Check if document changed before each page
      if (_doc != doc || !mounted) {
        _log('⏹️ Stopped background rendering (document changed)');
        break;
      }
      if (!_pageCache.containsKey(i)) {
        await _renderPage(i);
        // Small delay to avoid blocking UI
        await Future.delayed(const Duration(milliseconds: 10));
      }
    }

    if (_doc == doc && mounted) {
      _log('✅ All $_pageCount pages rendered');
    }
  }

  void _goToPage(int pageNum) {
    if (pageNum >= 0 && pageNum < _pageCount) {
      setState(() => _currentPage = pageNum);
      // Ensure page is rendered
      if (!_pageCache.containsKey(pageNum)) {
        _renderPage(pageNum);
      }
    }
  }

  Future<void> _cleanupAndRestart() async {
    _log('🔄 Cleaning up and restarting...');

    // First, clear _doc to signal background rendering to stop
    final doc = _doc;
    _doc = null;

    // Clear cache immediately
    _pageCache.clear();

    // Update UI state
    setState(() {
      _pdfPath = null;
      _listening = true;
      _currentPage = 0;
      _pageCount = 0;
      _isLoadingPages = false;
    });

    // Wait a bit for any in-progress rendering to notice _doc is null
    await Future.delayed(const Duration(milliseconds: 100));

    // Now safely close the document
    if (doc != null) {
      try {
        await doc.close();
        _log('✅ Document closed');
      } catch (e) {
        _log('⚠️ Document close error (ignored): $e');
      }
    }

    // Delete the file
    if (_pdfPath != null) {
      try {
        final file = File(_pdfPath!);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }

    _log('🔄 Returning to waiting screen');
    _startListeningForServer();
  }

  Future<void> _manualConnectDialog() async {
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Подключение вручную'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _ipController,
              decoration: const InputDecoration(
                labelText: 'IP телефона (например 192.168.1.5)',
              ),
              keyboardType: TextInputType.number,
            ),
            TextField(
              controller: _portController,
              decoration:
                  const InputDecoration(labelText: 'Порт (обычно 8080)'),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () async {
              final ip = _ipController.text.trim();
              final port = _portController.text.trim();
              if (ip.isNotEmpty) {
                Navigator.pop(ctx);
                await _downloadAndShowPdf(ip, port);
              }
            },
            child: const Text('Подключиться'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _beaconTimer?.cancel();
    _socket?.close();
    _httpServer.stop();
    _doc?.close();
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget body;

    if (_listening) {
      body = QRWaitingPage(server: _httpServer);
    } else if (_downloading || _isLoadingPages) {
      String statusText;
      double? progressValue;

      if (_isLoadingPages) {
        statusText = 'Подготовка страниц...';
        progressValue = _pageCache.isNotEmpty ? _pageCache.length / _pageCount : null;
      } else {
        statusText = 'Загрузка презентации...';
      }

      body = Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              color: Colors.orangeAccent,
              value: progressValue,
            ),
            const SizedBox(height: 16),
            Text(
              statusText,
              style: const TextStyle(fontSize: 18, color: Colors.white),
            ),
            if (progressValue != null && progressValue > 0) ...[
              const SizedBox(height: 8),
              Text(
                '${(progressValue * 100).toInt()}%',
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.orangeAccent,
                ),
              ),
            ],
          ],
        ),
      );
    } else if (_pdfPath != null && _pageCache.isNotEmpty) {
      final currentPageImage = _pageCache[_currentPage];

      body = Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
                _currentPage < _pageCount - 1) {
              _goToPage(_currentPage + 1);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
                _currentPage > 0) {
              _goToPage(_currentPage - 1);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.escape ||
                event.logicalKey == LogicalKeyboardKey.select) {
              _cleanupAndRestart();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.keyD) {
              setState(() => _showDebugPanel = !_showDebugPanel);
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Stack(
          children: [
            // PDF Page
            Center(
              child: currentPageImage != null
                  ? Image.memory(
                      currentPageImage.bytes,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    )
                  : const CircularProgressIndicator(color: Colors.orangeAccent),
            ),
            // Debug panel
            if (_showDebugPanel)
              Positioned(
                top: 0,
                right: 0,
                bottom: 0,
                width: MediaQuery.of(context).size.width * 0.5,
                child: GestureDetector(
                  onTap: _hideDebugPanel,
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.85),
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text(
                              '🔍 DEBUG LOGS',
                              style: TextStyle(
                                color: Colors.greenAccent,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            const Text(
                              '(tap to hide)',
                              style: TextStyle(color: Colors.white54, fontSize: 10),
                            ),
                          ],
                        ),
                        const Divider(color: Colors.grey),
                        Expanded(
                          child: ListView.builder(
                            itemCount: _debugLogs.length,
                            itemBuilder: (ctx, i) {
                              final log = _debugLogs[_debugLogs.length - 1 - i];
                              Color color = Colors.white70;
                              if (log.contains('❌')) color = Colors.redAccent;
                              if (log.contains('✅')) color = Colors.greenAccent;
                              if (log.contains('⚠️')) color = Colors.orangeAccent;
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 2),
                                child: Text(
                                  log,
                                  style: TextStyle(
                                    color: color,
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // Navigation controls
            Positioned(
              bottom: 20,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _NavigationButton(
                    icon: Icons.chevron_left,
                    onTap: _currentPage > 0
                        ? () => _goToPage(_currentPage - 1)
                        : null,
                  ),
                  const SizedBox(width: 8),
                  _NavigationButton(
                    icon: Icons.close,
                    onTap: () => _cleanupAndRestart(),
                  ),
                  const SizedBox(width: 8),
                  _NavigationButton(
                    icon: Icons.chevron_right,
                    onTap: _currentPage < _pageCount - 1
                        ? () => _goToPage(_currentPage + 1)
                        : null,
                  ),
                  const SizedBox(width: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.grey.shade400, width: 1.5),
                    ),
                    child: Text(
                      '${_currentPage + 1} / $_pageCount',
                      style: TextStyle(
                        color: Colors.grey.shade700,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  GestureDetector(
                    onTap: () => setState(() => _showDebugPanel = !_showDebugPanel),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: _showDebugPanel ? Colors.green : Colors.grey,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        'DEBUG',
                        style: TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    } else {
      body = const Center(
        child: Text(
          'Ошибка загрузки или отсутствует файл',
          style: TextStyle(fontSize: 16, color: Colors.red),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: body,
    );
  }
}

class _NavigationButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _NavigationButton({
    required this.icon,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDisabled = onTap == null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: isDisabled
              ? Colors.grey.withValues(alpha: 0.3)
              : Colors.white.withValues(alpha: 0.7),
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.grey.withValues(alpha: 0.4),
            width: 1,
          ),
        ),
        child: Icon(
          icon,
          color: isDisabled
              ? Colors.grey.withValues(alpha: 0.5)
              : Colors.grey.shade600,
          size: 24,
        ),
      ),
    );
  }
}
