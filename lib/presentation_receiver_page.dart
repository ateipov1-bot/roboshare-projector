import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  String? _pdfPath;
  RawDatagramSocket? _socket;

  PdfDocument? _doc;
  final Map<int, PdfPageImage> _pageCache = {}; // 🚀 Кеш всех страниц
  int _currentPage = 1;
  int _pageCount = 1;
  bool _isLoadingPages = false;

  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _portController =
      TextEditingController(text: "8080");

  // Новый HTTP сервер для приёма команд
  final ProjectorHttpServer _httpServer = ProjectorHttpServer();

  @override
  void initState() {
    super.initState();
    // Запускаем оба режима одновременно
    _startHttpServer();  // QR режим (HTTP)
    _startListeningForServer();  // UDP режим (старый способ)
  }

  /// 🌐 Запуск HTTP-сервера для QR режима
  Future<void> _startHttpServer() async {
    setState(() => _listening = true);

    // Устанавливаем callback для получения PDF URL
    _httpServer.onPdfUrlReceived = (pdfUrl) {
      debugPrint('📥 Получен PDF URL через HTTP: $pdfUrl');
      _downloadPdfFromUrl(pdfUrl);
    };

    // Запускаем сервер
    final started = await _httpServer.start(port: 8081);

    // Обновляем UI для отображения диагностики
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

  /// 📡 Слушаем UDP-пакеты от телефона
  Future<void> _startListeningForServer() async {
    try {
      _socket?.close();
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 54545);
      setState(() => _listening = true);

      _socket!.listen((e) async {
        if (e == RawSocketEvent.read) {
          final datagram = _socket!.receive();
          if (datagram != null) {
            final msg = String.fromCharCodes(datagram.data);
            if (msg.startsWith("RoboShareServer:")) {
              final parts = msg.split(":");
              if (parts.length >= 3) {
                final ip = parts[1];
                final port = parts[2];
                _socket!.close();
                await _downloadAndShowPdf(ip, port);
              }
            }
          }
        }
      });
    } catch (e) {
      debugPrint("UDP error: $e");
    }
  }

  /// ⬇️ Скачиваем PDF по URL (для QR режима)
  Future<void> _downloadPdfFromUrl(String pdfUrl) async {
    setState(() {
      _listening = false;
      _downloading = true;
    });

    debugPrint('📥 Начало загрузки PDF с $pdfUrl');

    try {
      final resp = await http.get(Uri.parse(pdfUrl)).timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          throw Exception('Timeout: сервер не отвечает более 60 секунд');
        },
      );

      debugPrint('✅ Ответ получен: ${resp.statusCode}');
      debugPrint('   Content-Type: ${resp.headers['content-type']}');
      debugPrint('   Content-Length: ${resp.headers['content-length']}');
      debugPrint('   Размер тела: ${resp.bodyBytes.length} байт');

      if (resp.statusCode == 200) {
        // Проверяем что это действительно PDF
        final header = String.fromCharCodes(resp.bodyBytes.take(5));
        debugPrint('   Заголовок файла: $header');

        if (!header.startsWith('%PDF-')) {
          throw Exception('Файл не является PDF! Заголовок: $header');
        }

        final dir = await getApplicationSupportDirectory();
        final file = File('${dir.path}/presentation.pdf');
        await file.create(recursive: true);
        await file.writeAsBytes(resp.bodyBytes);
        debugPrint('💾 PDF сохранён в ${file.path}');
        debugPrint('   Размер файла: ${await file.length()} байт');

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

  /// ⬇️ Скачиваем PDF (для UDP режима)
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
      debugPrint('   Content-Type: ${resp.headers['content-type']}');
      debugPrint('   Content-Length: ${resp.headers['content-length']}');
      debugPrint('   Размер тела: ${resp.bodyBytes.length} байт');

      if (resp.statusCode == 200) {
        // Проверяем что это действительно PDF
        final header = String.fromCharCodes(resp.bodyBytes.take(5));
        debugPrint('   Заголовок файла: $header');

        if (!header.startsWith('%PDF-')) {
          throw Exception('Файл не является PDF! Заголовок: $header');
        }

        final dir = await getApplicationSupportDirectory();
        final file = File('${dir.path}/presentation.pdf');
        await file.create(recursive: true);
        await file.writeAsBytes(resp.bodyBytes);
        debugPrint('💾 PDF сохранён в ${file.path}');
        debugPrint('   Размер файла: ${await file.length()} байт');

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

      // Показываем детальную ошибку пользователю
      String errorMessage = 'Ошибка загрузки: $e';

      // Специальная обработка для "No route to host"
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

  /// 📄 Открываем документ и предзагружаем все страницы
  Future<void> _openDocument(String path) async {
    try {
      debugPrint('📄 Открытие PDF документа: $path');
      setState(() => _isLoadingPages = true);

      _doc = await PdfDocument.openFile(path);
      _pageCount = _doc!.pagesCount;
      debugPrint('✅ PDF открыт, страниц: $_pageCount');

      // 🚀 Предзагружаем ВСЕ страницы в кеш
      for (int i = 1; i <= _pageCount; i++) {
        debugPrint('🖼️  Рендеринг страницы $i/$_pageCount...');
        final page = await _doc!.getPage(i);
        final img = await page.render(
          width: page.width * 3, // Увеличил множитель для лучшего качества
          height: page.height * 3,
        );
        await page.close();
        if (img != null) {
          _pageCache[i] = img;
          debugPrint('   ✅ Страница $i загружена (${img.bytes.length} байт)');
        } else {
          debugPrint('   ⚠️  Страница $i вернула null');
        }

        // Обновляем UI чтобы показать прогресс
        if (i == 1) {
          setState(() {
            _currentPage = 1;
            _isLoadingPages = false;
          });
        }
      }

      debugPrint("✅ Все $_pageCount страниц предзагружены!");
      debugPrint("   Кеш содержит: ${_pageCache.length} страниц");
    } catch (e, st) {
      debugPrint("❌ Ошибка открытия документа: $e");
      debugPrint("Stack trace: $st");
      setState(() => _isLoadingPages = false);
      // Показываем ошибку пользователю
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка открытия PDF: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  /// 🖼️ Переключение страницы (мгновенное, из кеша)
  void _goToPage(int pageNum) {
    if (_pageCache.containsKey(pageNum)) {
      setState(() {
        _currentPage = pageNum;
      });
    }
  }

  /// 🧹 Очистка
  Future<void> _cleanupAndRestart() async {
    if (_pdfPath != null) {
      try {
        final file = File(_pdfPath!);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    await _doc?.close();
    _pageCache.clear(); // Очищаем кеш
    setState(() {
      _pdfPath = null;
      _listening = true;
      _currentPage = 1;
      _pageCount = 1;
    });

    // Перезапускаем оба режима
    // HTTP сервер уже запущен, просто ждём новых подключений
    debugPrint('🔄 Возврат к экрану ожидания (QR + UDP)');
    _startListeningForServer(); // Перезапускаем UDP listener
  }

  /// 🔌 Подключение вручную
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
    _socket?.close();
    _doc?.close();
    _httpServer.stop();
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget body;

    if (_listening) {
      // Показываем QR-код (оба режима работают одновременно: QR + UDP)
      body = QRWaitingPage(server: _httpServer);
    } else if (_downloading || _isLoadingPages) {
      body = Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: Colors.orangeAccent),
            const SizedBox(height: 16),
            Text(
              _downloading
                ? 'Загрузка презентации...'
                : 'Предзагрузка страниц: ${_pageCache.length}/$_pageCount',
              style: const TextStyle(fontSize: 18),
            ),
          ],
        ),
      );
    } else if (_pageCache.isNotEmpty) {
      final currentImage = _pageCache[_currentPage];
      body = Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          // ✅ Обрабатываем только нажатия клавиш
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
                _currentPage < _pageCount) {
              _goToPage(_currentPage + 1);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
                _currentPage > 1) {
              _goToPage(_currentPage - 1);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.escape ||
                event.logicalKey == LogicalKeyboardKey.select) {
              _cleanupAndRestart();
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Stack(
          children: [
            // 🚀 Мгновенное переключение без анимации
            if (currentImage != null)
              Center(
                child: Image.memory(
                  currentImage.bytes,
                  fit: BoxFit.contain,
                ),
              ),
            // 🔢 Индикатор страниц
            Positioned(
              bottom: 30,
              left: 0,
              right: 0,
              child: Text(
                '$_currentPage / $_pageCount',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
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
