import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';

class ProjectorHttpServer {
  HttpServer? _server;
  int? _port;
  String? _cachedIp;
  Function(String)? onPdfUrlReceived;

  // Диагностическая информация для отображения на экране
  List<String> diagnosticLogs = [];

  int? get port => _port;
  String? get ipAddress => _cachedIp;

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

    // Endpoint для получения презентации
    if (request.method == 'POST' && request.uri.path == '/receive-presentation') {
      await _handleReceivePresentation(request);
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

  /// Обработка приёма URL презентации
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

  /// Получаем локальный IP адрес устройства
  Future<String?> _getLocalIpAddressAsync() async {
    diagnosticLogs.clear();
    diagnosticLogs.add('🔍 ПОИСК IP АДРЕСА');
    debugPrint('🔍 ========== НАЧАЛО ПОИСКА IP АДРЕСА ==========');

    // Метод 1: Попытка через Socket (самый надёжный)
    try {
      diagnosticLogs.add('Метод 1: UDP Socket...');
      debugPrint('🔧 Метод 1: Попытка через UDP Socket...');
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final address = socket.address.address;
      socket.close();

      diagnosticLogs.add('  └─ Получен: $address');
      if (address != '0.0.0.0' && !address.startsWith('127.')) {
        diagnosticLogs.add('  └─ ✅ УСПЕХ: $address');
        debugPrint('✅ Метод 1 УСПЕШНО: IP = $address');
        return address;
      }
      diagnosticLogs.add('  └─ ⚠️ Некорректный адрес');
      debugPrint('⚠️ Метод 1: получен некорректный адрес $address');
    } catch (e) {
      diagnosticLogs.add('  └─ ❌ Ошибка: $e');
      debugPrint('❌ Метод 1 ПРОВАЛИЛСЯ: $e');
    }

    // Метод 2: Через NetworkInterface.list()
    try {
      diagnosticLogs.add('Метод 2: NetworkInterface...');
      debugPrint('🔧 Метод 2: Попытка через NetworkInterface.list()...');

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

      // Приоритетные паттерны
      final patterns = ['wlan', 'wifi', 'en', 'ap', 'eth', 'rmnet'];

      for (var pattern in patterns) {
        for (var interface in interfaces) {
          if (interface.name.toLowerCase().contains(pattern)) {
            for (var addr in interface.addresses) {
              if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
                diagnosticLogs.add('  └─ ✅ УСПЕХ: ${addr.address}');
                debugPrint('✅ Метод 2 УСПЕШНО: IP = ${addr.address} (${interface.name})');
                return addr.address;
              }
            }
          }
        }
      }

      // Fallback: любой IPv4
      diagnosticLogs.add('  └─ Ищу любой IPv4...');
      debugPrint('⚠️ Приоритетные не найдены, ищу ЛЮБОЙ IPv4...');
      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 &&
              !addr.isLoopback &&
              !addr.address.startsWith('169.254.')) {
            diagnosticLogs.add('  └─ ✅ FALLBACK: ${addr.address}');
            debugPrint('✅ Метод 2 FALLBACK: IP = ${addr.address} (${interface.name})');
            return addr.address;
          }
        }
      }

      diagnosticLogs.add('  └─ ❌ Нет IPv4 адресов');
      debugPrint('❌ Метод 2: НЕТ подходящих IPv4 адресов');
    } catch (e, stackTrace) {
      diagnosticLogs.add('  └─ ❌ Ошибка: $e');
      debugPrint('❌ Метод 2 ПРОВАЛИЛСЯ: $e');
      debugPrint('   Stack: ${stackTrace.toString().split('\n').take(3).join('\n')}');
    }

    // Метод 3: Hardcoded fallback (если ничего не работает)
    try {
      diagnosticLogs.add('Метод 3: Подключение к 8.8.8.8...');
      debugPrint('🔧 Метод 3: Проверка через тестовое подключение к 8.8.8.8...');
      final socket = await Socket.connect('8.8.8.8', 53, timeout: const Duration(seconds: 3));
      final localAddress = socket.address.address;
      socket.destroy();

      diagnosticLogs.add('  └─ Локальный адрес: $localAddress');
      if (localAddress != '0.0.0.0') {
        diagnosticLogs.add('  └─ ✅ УСПЕХ: $localAddress');
        debugPrint('✅ Метод 3 УСПЕШНО: IP = $localAddress');
        return localAddress;
      }
    } catch (e) {
      diagnosticLogs.add('  └─ ❌ Ошибка: $e');
      debugPrint('❌ Метод 3 ПРОВАЛИЛСЯ: $e');
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
