import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

class ProjectorHttpServer {
  HttpServer? _server;
  int? _port;
  String? _cachedIp;
  Function(String)? onPdfUrlReceived;
  Function(Uint8List)? onPdfBytesReceived; // Callback для приёма байтов PDF

  // Диагностическая информация для отображения на экране
  List<String> diagnosticLogs = [];

  int? get port => _port;
  String? get ipAddress => _cachedIp;

  /// Переопределить IP адрес (при смене сети/хотспота)
  Future<void> refreshIpAddress() async {
    debugPrint('🔄 Переопределение IP адреса...');
    _cachedIp = await _getLocalIpAddressAsync();
    debugPrint('📍 Новый IP адрес: ${_cachedIp ?? "не определён"}');
  }

  /// Запускаем HTTP-сервер на указанном порту
  Future<bool> start({int port = 8081}) async {
    try {
      // Сначала получаем IP адрес
      _cachedIp = await _getLocalIpAddressAsync();

      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _port = port;

      debugPrint('🌐 HTTP-сервер запущен на порту $_port');
      debugPrint('📍 IP адрес: ${ipAddress ?? "не определён"}');

      _server!.listen((HttpRequest request) {
        _handleRequest(request);
      });

      return true;
    } catch (e) {
      debugPrint('❌ Ошибка запуска HTTP-сервера: $e');
      return false;
    }
  }

  /// Обработка входящих запросов
  void _handleRequest(HttpRequest request) async {
    debugPrint('📥 Получен запрос: ${request.method} ${request.uri.path}');

    // CORS headers для поддержки запросов с мобильного приложения
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers.add('Access-Control-Allow-Methods', 'POST, GET, OPTIONS');
    request.response.headers.add('Access-Control-Allow-Headers', 'Content-Type');

    // Обработка OPTIONS запроса (preflight)
    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }

    // Endpoint для получения презентации по URL (старый метод)
    if (request.method == 'POST' && request.uri.path == '/receive-presentation') {
      await _handleReceivePresentation(request);
    }
    // Endpoint для получения презентации напрямую байтами (новый метод - офлайн)
    else if (request.method == 'POST' && request.uri.path == '/receive-presentation-bytes') {
      await _handleReceivePresentationBytes(request);
    } else {
      // 404 для неизвестных путей
      request.response.statusCode = HttpStatus.notFound;
      request.response.write(json.encode({
        'status': 'error',
        'message': 'Endpoint not found'
      }));
      await request.response.close();
    }
  }

  /// Обработка приёма URL презентации (старый метод - требует интернет)
  Future<void> _handleReceivePresentation(HttpRequest request) async {
    try {
      // Читаем body запроса
      final body = await utf8.decoder.bind(request).join();
      debugPrint('📦 Получены данные: $body');

      final data = json.decode(body) as Map<String, dynamic>;

      if (data.containsKey('pdf_url')) {
        final pdfUrl = data['pdf_url'] as String;
        debugPrint('✅ Получен PDF URL: $pdfUrl');

        // Вызываем callback
        if (onPdfUrlReceived != null) {
          onPdfUrlReceived!(pdfUrl);
        }

        // Отправляем успешный ответ
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(json.encode({
          'status': 'success',
          'message': 'Presentation received'
        }));
      } else {
        throw Exception('Missing pdf_url field');
      }
    } catch (e) {
      debugPrint('❌ Ошибка обработки запроса: $e');
      request.response.statusCode = HttpStatus.badRequest;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({
        'status': 'error',
        'message': 'Invalid request: $e'
      }));
    } finally {
      await request.response.close();
    }
  }

  /// Обработка приёма байтов PDF напрямую (новый метод - работает офлайн)
  Future<void> _handleReceivePresentationBytes(HttpRequest request) async {
    try {
      debugPrint('📦 Получаем PDF байты напрямую...');

      // Читаем бинарные данные из body
      final List<int> bytesList = [];
      await for (final chunk in request) {
        bytesList.addAll(chunk);
      }
      final bytes = Uint8List.fromList(bytesList);

      debugPrint('📦 Получено ${bytes.length} байт');

      // Проверяем что это PDF
      if (bytes.length < 5) {
        throw Exception('Файл слишком маленький');
      }

      final header = String.fromCharCodes(bytes.take(5));
      if (!header.startsWith('%PDF-')) {
        throw Exception('Полученные данные не являются PDF файлом');
      }

      debugPrint('✅ PDF валидный, размер: ${bytes.length} байт');

      // Вызываем callback для приёма байтов
      if (onPdfBytesReceived != null) {
        onPdfBytesReceived!(bytes);
      }

      // Отправляем успешный ответ
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({
        'status': 'success',
        'message': 'PDF received directly',
        'size': bytes.length,
      }));
    } catch (e) {
      debugPrint('❌ Ошибка приёма PDF байтов: $e');
      request.response.statusCode = HttpStatus.badRequest;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({
        'status': 'error',
        'message': 'Invalid PDF data: $e'
      }));
    } finally {
      await request.response.close();
    }
  }

  /// Получаем локальный IP адрес устройства
  /// Поддерживает: Wi-Fi, Ethernet, и режим точки доступа (Hotspot)
  Future<String?> _getLocalIpAddressAsync() async {
    diagnosticLogs.clear();
    diagnosticLogs.add('🔍 ПОИСК IP АДРЕСА');
    debugPrint('🔍 ========== НАЧАЛО ПОИСКА IP АДРЕСА ==========');

    // Метод 1: Через NetworkInterface.list() - проверяем все интерфейсы
    try {
      diagnosticLogs.add('Метод 1: NetworkInterface...');
      debugPrint('🔧 Метод 1: Попытка через NetworkInterface.list()...');

      final interfaces = await NetworkInterface.list();
      diagnosticLogs.add('  └─ Найдено интерфейсов: ${interfaces.length}');
      debugPrint('   Найдено интерфейсов: ${interfaces.length}');

      // Выводим ВСЕ интерфейсы
      for (var interface in interfaces) {
        debugPrint('   📡 ${interface.name}:');
        diagnosticLogs.add('  📡 ${interface.name}:');
        for (var addr in interface.addresses) {
          debugPrint('      ${addr.address} [${addr.type.name}] loopback=${addr.isLoopback}');
          if (addr.type == InternetAddressType.IPv4) {
            diagnosticLogs.add('    ${addr.address}');
          }
        }
      }

      // Сначала проверяем интерфейсы точки доступа (Hotspot)
      // На Android хотспот обычно использует: ap0, swlan0, wlan1, softap0
      final hotspotPatterns = ['ap0', 'swlan', 'softap', 'wlan1'];

      for (var pattern in hotspotPatterns) {
        for (var interface in interfaces) {
          if (interface.name.toLowerCase().contains(pattern)) {
            for (var addr in interface.addresses) {
              if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
                diagnosticLogs.add('  └─ ✅ HOTSPOT: ${addr.address}');
                debugPrint('✅ Метод 1 HOTSPOT: IP = ${addr.address} (${interface.name})');
                return addr.address;
              }
            }
          }
        }
      }

      // Проверяем стандартные IP диапазоны хотспота Android
      // Разные производители используют разные диапазоны
      final hotspotIpPrefixes = [
        '192.168.43.',  // Стандартный Android hotspot
        '192.168.49.',  // Samsung devices
        '192.168.44.',  // Alternative Android
        '192.168.1.',   // Some custom ROMs (когда проектор = gateway)
        '172.20.10.',   // iOS Personal Hotspot
      ];

      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4) {
            for (var prefix in hotspotIpPrefixes) {
              // Проверяем что это gateway IP (заканчивается на .1)
              if (addr.address.startsWith(prefix) && addr.address.endsWith('.1')) {
                diagnosticLogs.add('  └─ ✅ HOTSPOT IP: ${addr.address}');
                debugPrint('✅ Метод 1 HOTSPOT IP: ${addr.address} (${interface.name})');
                return addr.address;
              }
            }
          }
        }
      }

      // Затем проверяем обычные Wi-Fi/Ethernet интерфейсы
      final wifiPatterns = ['wlan0', 'wlan', 'wifi', 'en0', 'en1', 'eth'];

      for (var pattern in wifiPatterns) {
        for (var interface in interfaces) {
          if (interface.name.toLowerCase().contains(pattern)) {
            for (var addr in interface.addresses) {
              if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
                diagnosticLogs.add('  └─ ✅ WIFI: ${addr.address}');
                debugPrint('✅ Метод 1 WIFI: IP = ${addr.address} (${interface.name})');
                return addr.address;
              }
            }
          }
        }
      }

      // Fallback: любой IPv4 (кроме loopback и link-local)
      diagnosticLogs.add('  └─ Ищу любой IPv4...');
      debugPrint('⚠️ Приоритетные не найдены, ищу ЛЮБОЙ IPv4...');
      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 &&
              !addr.isLoopback &&
              !addr.address.startsWith('169.254.') &&
              !addr.address.startsWith('127.')) {
            diagnosticLogs.add('  └─ ✅ FALLBACK: ${addr.address}');
            debugPrint('✅ Метод 1 FALLBACK: IP = ${addr.address} (${interface.name})');
            return addr.address;
          }
        }
      }

      diagnosticLogs.add('  └─ ❌ Нет IPv4 адресов');
      debugPrint('❌ Метод 1: НЕТ подходящих IPv4 адресов');
    } catch (e, stackTrace) {
      diagnosticLogs.add('  └─ ❌ Ошибка: $e');
      debugPrint('❌ Метод 1 ПРОВАЛИЛСЯ: $e');
      debugPrint('   Stack: ${stackTrace.toString().split('\n').take(3).join('\n')}');
    }

    // Метод 2: Попытка через UDP Socket
    try {
      diagnosticLogs.add('Метод 2: UDP Socket...');
      debugPrint('🔧 Метод 2: Попытка через UDP Socket...');
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final address = socket.address.address;
      socket.close();

      diagnosticLogs.add('  └─ Получен: $address');
      if (address != '0.0.0.0' && !address.startsWith('127.')) {
        diagnosticLogs.add('  └─ ✅ УСПЕХ: $address');
        debugPrint('✅ Метод 2 УСПЕШНО: IP = $address');
        return address;
      }
      diagnosticLogs.add('  └─ ⚠️ Некорректный адрес');
      debugPrint('⚠️ Метод 2: получен некорректный адрес $address');
    } catch (e) {
      diagnosticLogs.add('  └─ ❌ Ошибка: $e');
      debugPrint('❌ Метод 2 ПРОВАЛИЛСЯ: $e');
    }

    // Метод 3: Проверка стандартного IP хотспота Android
    // Если устройство в режиме точки доступа, оно обычно имеет IP 192.168.43.1
    try {
      diagnosticLogs.add('Метод 3: Проверка стандартного Hotspot IP...');
      debugPrint('🔧 Метод 3: Проверка стандартного Hotspot IP 192.168.43.1...');

      // Пробуем забиндить сервер на стандартный IP хотспота
      final testSocket = await RawDatagramSocket.bind(
        InternetAddress('192.168.43.1'),
        0,
      );
      testSocket.close();

      diagnosticLogs.add('  └─ ✅ HOTSPOT: 192.168.43.1');
      debugPrint('✅ Метод 3 УСПЕШНО: Hotspot IP = 192.168.43.1');
      return '192.168.43.1';
    } catch (e) {
      diagnosticLogs.add('  └─ Не хотспот режим');
      debugPrint('⚠️ Метод 3: Не в режиме хотспота ($e)');
    }

    // Метод 4: Подключение к 8.8.8.8 (только если есть интернет)
    try {
      diagnosticLogs.add('Метод 4: Подключение к 8.8.8.8...');
      debugPrint('🔧 Метод 4: Проверка через тестовое подключение к 8.8.8.8...');
      final socket = await Socket.connect('8.8.8.8', 53, timeout: const Duration(seconds: 3));
      final localAddress = socket.address.address;
      socket.destroy();

      diagnosticLogs.add('  └─ Локальный адрес: $localAddress');
      if (localAddress != '0.0.0.0') {
        diagnosticLogs.add('  └─ ✅ УСПЕХ: $localAddress');
        debugPrint('✅ Метод 4 УСПЕШНО: IP = $localAddress');
        return localAddress;
      }
    } catch (e) {
      diagnosticLogs.add('  └─ ❌ Нет интернета');
      debugPrint('❌ Метод 4 ПРОВАЛИЛСЯ: $e');
    }

    diagnosticLogs.add('❌ ВСЕ МЕТОДЫ ПРОВАЛИЛИСЬ');
    debugPrint('❌ ========== ВСЕ МЕТОДЫ ПРОВАЛИЛИСЬ ==========');
    return null;
  }

  /// Останавливаем сервер
  Future<void> stop() async {
    await _server?.close();
    _server = null;
    _port = null;
    debugPrint('🛑 HTTP-сервер остановлен');
  }
}
