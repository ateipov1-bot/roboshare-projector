import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:bt_classic/bt_classic.dart';

/// Service for receiving PDF files via Bluetooth on the projector (Android only)
/// Uses bt_classic package with custom chunked protocol for large files
///
/// Protocol:
/// 1. PDF_START:size:filename - header with file size
/// 2. PDF_CHUNK:num:base64data - chunks of data
/// 3. PDF_END:size - end marker with verification
class BluetoothReceiverService {
  static final BluetoothReceiverService _instance = BluetoothReceiverService._internal();
  static BluetoothReceiverService get instance => _instance;

  BluetoothReceiverService._internal();

  BluetoothHostService? _hostService;
  bool _isListening = false;
  bool _isReceiving = false;

  // Chunked transfer state
  int _expectedSize = 0;
  String _fileName = '';
  final BytesBuilder _dataBuffer = BytesBuilder();
  int _lastChunkNum = -1;

  // Callbacks
  Function(Uint8List pdfBytes)? onPdfReceived;
  Function(String status)? onStatusChange;
  Function(double progress)? onProgress;
  Function(String error)? onError;

  bool get isListening => _isListening;
  bool get isReceiving => _isReceiving;

  /// Check if Bluetooth is available and enabled
  Future<bool> isBluetoothAvailable() async {
    if (!Platform.isAndroid) {
      debugPrint('Bluetooth receiver is only available on Android');
      return false;
    }

    try {
      _hostService ??= BluetoothHostService();
      final isEnabled = await _hostService!.isBluetoothEnabled();
      debugPrint('🔵 Bluetooth enabled: $isEnabled');
      return isEnabled;
    } catch (e) {
      debugPrint('Error checking Bluetooth state: $e');
      return false;
    }
  }

  /// Request to enable Bluetooth
  Future<bool> requestEnableBluetooth() async {
    if (!Platform.isAndroid) return false;
    return await isBluetoothAvailable();
  }

  /// Get device name
  Future<String?> getDeviceName() async {
    if (!Platform.isAndroid) return null;

    try {
      _hostService ??= BluetoothHostService();
      return await _hostService!.getDeviceName();
    } catch (e) {
      debugPrint('Error getting device name: $e');
      return null;
    }
  }

  /// Start listening for incoming Bluetooth connections (server mode)
  Future<void> startListening() async {
    if (!Platform.isAndroid) {
      onError?.call('Bluetooth доступен только на Android');
      return;
    }

    if (_isListening) {
      debugPrint('Already listening for Bluetooth connections');
      return;
    }

    try {
      // Create new host service instance
      _hostService = BluetoothHostService();

      debugPrint('🔵 Requesting Bluetooth permissions...');
      onStatusChange?.call('Запрос разрешений...');

      final permissionsGranted = await _hostService!.requestPermissions();
      debugPrint('🔵 Permissions granted: $permissionsGranted');

      if (permissionsGranted != true) {
        onError?.call('Bluetooth разрешения не предоставлены');
        return;
      }

      // Set up callbacks BEFORE starting server
      _hostService!.onClientConnected = (address) {
        debugPrint('📱 Client connected from: $address');
        onStatusChange?.call('Телефон подключен');
        _resetTransferState();
      };

      _hostService!.onClientDisconnected = () {
        debugPrint('📱 Client disconnected');
        onStatusChange?.call('Телефон отключен');
        if (_isReceiving) {
          onError?.call('Соединение потеряно во время передачи');
        }
        _resetTransferState();
      };

      _hostService!.onMessageReceived = (message) {
        _handleMessage(message);
      };

      _hostService!.onFileReceived = (fileName, fileData) {
        debugPrint('📥 File received via built-in: $fileName (${fileData.length} bytes)');
        _handleDirectFile(fileName, fileData);
      };

      _hostService!.onError = (error) {
        debugPrint('❌ Bluetooth error: $error');
        onError?.call(error);
      };

      // Make device discoverable (shows system dialog)
      debugPrint('🔵 Making device discoverable...');
      onStatusChange?.call('Включение видимости...');
      await _hostService!.makeDiscoverable();

      await Future.delayed(const Duration(milliseconds: 500));

      // Start Bluetooth server (host mode)
      debugPrint('🔵 Starting Bluetooth server...');
      onStatusChange?.call('Запуск сервера...');

      final started = await _hostService!.startServer();
      debugPrint('🔵 Server started: $started');

      if (started == true) {
        _isListening = true;
        onStatusChange?.call('Bluetooth готов');
        debugPrint('📡 Bluetooth server started, waiting for connections...');
      } else {
        onError?.call('Не удалось запустить Bluetooth сервер');
        debugPrint('❌ Failed to start Bluetooth server');
      }
    } catch (e, st) {
      debugPrint('Error starting Bluetooth listener: $e');
      debugPrint('Stack trace: $st');
      _isListening = false;
      onError?.call('Ошибка запуска Bluetooth: $e');
    }
  }

  /// Handle incoming message (chunked protocol)
  void _handleMessage(String message) {
    try {
      if (message.startsWith('PDF_START:')) {
        _handleStartMessage(message);
      } else if (message.startsWith('PDF_CHUNK:')) {
        _handleChunkMessage(message);
      } else if (message.startsWith('PDF_END:')) {
        _handleEndMessage(message);
      } else if (message.startsWith('FILE:')) {
        // Handle bt_classic's built-in file protocol (fallback)
        _handleBuiltInFileMessage(message);
      } else {
        debugPrint('📥 Unknown message: ${message.substring(0, message.length.clamp(0, 50))}...');
      }
    } catch (e, st) {
      debugPrint('❌ Error handling message: $e');
      debugPrint('Stack: $st');
      onError?.call('Ошибка обработки данных');
    }
  }

  /// Handle PDF_START message
  void _handleStartMessage(String message) {
    // Format: PDF_START:size:filename
    final parts = message.split(':');
    if (parts.length >= 3) {
      _expectedSize = int.tryParse(parts[1]) ?? 0;
      _fileName = parts[2];

      _isReceiving = true;
      _dataBuffer.clear();
      _lastChunkNum = -1;

      debugPrint('📥 Starting PDF receive: $_fileName ($_expectedSize bytes)');
      onStatusChange?.call('Приём: $_fileName');
      onProgress?.call(0.0);
    }
  }

  /// Handle PDF_CHUNK message
  void _handleChunkMessage(String message) {
    if (!_isReceiving) {
      debugPrint('⚠️ Received chunk but not in receiving state');
      return;
    }

    // Format: PDF_CHUNK:num:base64data
    final firstColon = message.indexOf(':');
    final secondColon = message.indexOf(':', firstColon + 1);

    if (firstColon == -1 || secondColon == -1) {
      debugPrint('❌ Invalid chunk format');
      return;
    }

    final chunkNumStr = message.substring(firstColon + 1, secondColon);
    final base64Data = message.substring(secondColon + 1);

    final chunkNum = int.tryParse(chunkNumStr) ?? -1;

    // Verify chunk order
    if (chunkNum != _lastChunkNum + 1) {
      debugPrint('⚠️ Chunk out of order: expected ${_lastChunkNum + 1}, got $chunkNum');
      // Still try to process it
    }

    _lastChunkNum = chunkNum;

    // Decode Base64 chunk
    try {
      final chunkBytes = base64Decode(base64Data);
      _dataBuffer.add(chunkBytes);

      // Update progress
      if (_expectedSize > 0) {
        final progress = (_dataBuffer.length / _expectedSize).clamp(0.0, 1.0);
        onProgress?.call(progress);

        if (chunkNum % 50 == 0) {
          debugPrint('📥 Received chunk $chunkNum (${(progress * 100).toInt()}%)');
          onStatusChange?.call('Приём: ${(progress * 100).toInt()}%');
        }
      }
    } catch (e) {
      debugPrint('❌ Failed to decode chunk $chunkNum: $e');
    }
  }

  /// Handle PDF_END message
  void _handleEndMessage(String message) {
    if (!_isReceiving) {
      debugPrint('⚠️ Received END but not in receiving state');
      return;
    }

    // Format: PDF_END:size
    final parts = message.split(':');
    final reportedSize = parts.length >= 2 ? (int.tryParse(parts[1]) ?? 0) : 0;

    final receivedBytes = _dataBuffer.toBytes();
    debugPrint('📥 Transfer complete: ${receivedBytes.length} bytes (expected: $reportedSize)');

    // Validate
    if (receivedBytes.length < 5) {
      debugPrint('❌ Received data too small');
      onError?.call('Файл слишком маленький');
      _resetTransferState();
      return;
    }

    // Check PDF header
    final header = String.fromCharCodes(receivedBytes.take(5));
    debugPrint('📄 File header: "$header"');

    if (header.startsWith('%PDF-')) {
      debugPrint('✅ Valid PDF received!');
      onProgress?.call(1.0);
      onStatusChange?.call('PDF получен!');
      onPdfReceived?.call(receivedBytes);
    } else {
      debugPrint('❌ Invalid PDF header: $header');
      onError?.call('Неверный формат PDF');
    }

    _resetTransferState();
  }

  /// Handle bt_classic's built-in FILE: protocol
  void _handleBuiltInFileMessage(String message) {
    // Format: FILE:filename:base64data
    final parts = message.split(':');
    if (parts.length >= 3) {
      final fileName = parts[1];
      final base64Data = parts.sublist(2).join(':'); // In case filename has colons

      debugPrint('📥 Received file via built-in protocol: $fileName');

      try {
        final fileData = base64Decode(base64Data);
        _handleDirectFile(fileName, fileData);
      } catch (e) {
        debugPrint('❌ Failed to decode file: $e');
        onError?.call('Ошибка декодирования файла');
      }
    }
  }

  /// Handle directly received file
  void _handleDirectFile(String fileName, Uint8List fileData) {
    debugPrint('✅ Processing direct file: $fileName (${fileData.length} bytes)');

    if (fileData.length >= 5) {
      final header = String.fromCharCodes(fileData.take(5));
      debugPrint('📄 File header: "$header"');

      if (header.startsWith('%PDF-')) {
        debugPrint('✅ Valid PDF received!');
        onProgress?.call(1.0);
        onStatusChange?.call('PDF получен!');
        onPdfReceived?.call(fileData);
        return;
      }
    }

    onError?.call('Неверный формат файла');
  }

  /// Reset transfer state
  void _resetTransferState() {
    _isReceiving = false;
    _expectedSize = 0;
    _fileName = '';
    _dataBuffer.clear();
    _lastChunkNum = -1;
  }

  /// Stop listening and close server
  Future<void> stop() async {
    debugPrint('🔵 Stopping Bluetooth receiver...');
    try {
      if (_hostService != null) {
        await _hostService!.stopServer();
        await _hostService!.disconnect();
      }
      _hostService = null;

      _isListening = false;
      _resetTransferState();
      debugPrint('✅ Bluetooth receiver stopped');
    } catch (e) {
      debugPrint('Error stopping Bluetooth receiver: $e');
    }
  }

  /// Check if server is running
  Future<bool> isServerRunning() async {
    try {
      final running = await _hostService?.isServerRunning();
      return running ?? false;
    } catch (e) {
      return false;
    }
  }
}
