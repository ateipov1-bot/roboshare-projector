import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';

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
  PdfPageImage? _pageImage;
  int _currentPage = 1;
  int _pageCount = 1;

  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _portController =
      TextEditingController(text: "8080");

  @override
  void initState() {
    super.initState();
    _startListeningForServer();
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

  /// ⬇️ Скачиваем PDF
  Future<void> _downloadAndShowPdf(String ip, String port) async {
    setState(() {
      _listening = false;
      _downloading = true;
    });

    final url = "http://$ip:$port/pdf";

    try {
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode == 200) {
        final dir = await getApplicationSupportDirectory();
        final file = File('${dir.path}/presentation.pdf');
        await file.create(recursive: true);
        await file.writeAsBytes(resp.bodyBytes);
        setState(() {
          _pdfPath = file.path;
          _downloading = false;
        });
        await _openDocument(file.path);
      } else {
        throw Exception("Ошибка загрузки (${resp.statusCode})");
      }
    } catch (e) {
      debugPrint("Ошибка загрузки: $e");
      setState(() => _downloading = false);
    }
  }

  /// 📄 Открываем документ
  Future<void> _openDocument(String path) async {
    try {
      _doc = await PdfDocument.openFile(path);
      _pageCount = _doc!.pagesCount;
      await _renderPage(1);
    } catch (e) {
      debugPrint("Ошибка открытия документа: $e");
    }
  }

  /// 🖼️ Рендер одной страницы
  Future<void> _renderPage(int pageNum) async {
    if (_doc == null) return;
    try {
      final page = await _doc!.getPage(pageNum);
      final img = await page.render(
        width: page.width * 2,
        height: page.height * 2,
      );
      await page.close();

      setState(() {
        _currentPage = pageNum;
        _pageImage = img;
      });
    } catch (e) {
      debugPrint("Ошибка рендера: $e");
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
    setState(() {
      _pdfPath = null;
      _pageImage = null;
      _listening = true;
    });
    _startListeningForServer();
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
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget body;

    if (_listening) {
      body = Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.wifi, size: 64, color: Colors.orange),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _manualConnectDialog,
              icon: const Icon(Icons.link),
              label: const Text("Подключиться вручную"),
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orangeAccent),
            ),
            const SizedBox(height: 16),
            const Text(
              'Ожидание сигнала от телефона...',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18),
            ),
          ],
        ),
      );
    } else if (_downloading) {
      body = const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.orangeAccent),
            SizedBox(height: 16),
            Text('Загрузка презентации...', style: TextStyle(fontSize: 18)),
          ],
        ),
      );
    } else if (_pageImage != null) {
      body = Focus(
        autofocus: true,
        onKey: (node, event) {
          // ✅ фильтруем дублирующиеся события
          if (event is RawKeyDownEvent && !event.repeat) {
            if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
                _currentPage < _pageCount) {
              _renderPage(_currentPage + 1);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
                _currentPage > 1) {
              _renderPage(_currentPage - 1);
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
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Center(
                key: ValueKey(_currentPage),
                child: Image.memory(
                  _pageImage!.bytes,
                  fit: BoxFit.contain,
                ),
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
