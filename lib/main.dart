import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

const int port = 12345;

void main() {
  runApp(const FileShareApp());
}

class FileShareApp extends StatelessWidget {
  const FileShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        fontFamily: 'OpenSans',
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF1A237E),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFC4B5FD),
          onPrimary: Colors.black,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFC4B5FD),
            foregroundColor: Colors.black,
            minimumSize: const Size.fromHeight(50),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),
      home: const MainPage(),
    );
  }
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

enum TransferState { idle, transferring, success }

class _MainPageState extends State<MainPage> {
  TransferState _currentState = TransferState.idle;
  String _statusText = "Initializing...";
  String _localIp = "Getting IP...";
  double _progress = 0.0;
  String _speedText = "";
  ServerSocket? _serverSocket;

  @override
  void initState() {
    super.initState();
    _setIdleUI();
  }

  @override
  void dispose() {
    _serverSocket?.close();
    super.dispose();
  }

  Future<void> _setIdleUI() async {
    await [Permission.photos, Permission.storage].request();
    try {
      _localIp = await NetworkInfo().getWifiIP() ?? "No Wi-Fi IP";
    } catch (e) {
      _localIp = "Network error";
    }
    if (!mounted) return;
    setState(() {
      _currentState = TransferState.idle;
      _statusText = "Your IP is $_localIp";
    });
  }

  void _setTransferUI(String status) {
    setState(() {
      _currentState = TransferState.transferring;
      _statusText = status;
      _progress = 0.0;
      _speedText = "";
    });
  }

  Future<void> _showSuccessState(String message) async {
    setState(() {
      _currentState = TransferState.success;
      _statusText = message;
    });
    await Future.delayed(const Duration(seconds: 4));
    if (mounted) await _setIdleUI();
  }

  Future<void> _pickMedia() async {
    final List<AssetEntity>? result = await AssetPicker.pickAssets(
      context,
      pickerConfig: const AssetPickerConfig(maxAssets: 100, requestType: RequestType.common),
    );
    if (result == null || result.isEmpty) return;

    List<PlatformFile> files = [];
    for (var asset in result) {
      final file = await asset.originFile;
      if (file != null) {
        files.add(PlatformFile(
            name: asset.title ?? 'unknown_media', path: file.path, size: await file.length()));
      }
    }
    if (files.isNotEmpty) await _startSending(files);
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty) return;
    await _startSending(result.files);
  }

  Future<void> _startSending(List<PlatformFile> files) async {
    _setTransferUI("${files.length} file(s) ready to send.");
    try {
      final securityCode = Random().nextInt(899999) + 100000;
      _serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      _setTransferUI("On the other device, enter:\nIP: $_localIp\nCode: $securityCode");
      
      await for (var clientSocket in _serverSocket!) {
        await _handleClient(clientSocket, files, securityCode);
        break;
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Send Error: ${e.toString()}")));
      await _setIdleUI();
    } finally {
      await _serverSocket?.close();
      _serverSocket = null;
    }
  }

  Future<void> _handleClient(Socket client, List<PlatformFile> files, int securityCode) async {
    try {
      var completer = Completer<Uint8List>();
      var subscription = client.listen((data) {
        if (!completer.isCompleted) completer.complete(data);
      });
      final receivedData = await completer.future.timeout(const Duration(seconds: 20));
      subscription.cancel();

      if (receivedData.buffer.asByteData().getInt32(0) != securityCode) throw Exception("Wrong security code.");

      client.add(Uint8List(4)..buffer.asByteData().setInt32(0, files.length));
      await client.flush();

      for (int i = 0; i < files.length; i++) {
        final file = files[i];
        if (mounted) setState(() => _statusText = "Sending ${i + 1}/${files.length}:\n${file.name}");

        final fileNameBytes = file.name.codeUnits;
        client.add(Uint8List(2)..buffer.asByteData().setInt16(0, fileNameBytes.length));
        await client.flush();
        client.add(fileNameBytes);
        await client.flush();
        client.add(Uint8List(8)..buffer.asByteData().setInt64(0, file.size));
        await client.flush();

        final fileStream = File(file.path!).openRead();
        await client.addStream(fileStream);
      }
      await _showSuccessState("Transfer Complete!");
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Connection Error: ${e.toString()}")));
      await _setIdleUI();
    } finally {
      client.close();
    }
  }

  Future<void> _receiveButton_Clicked() async {
    try {
      final String? result = await _showIpCodePrompt();
      if (result == null || !result.contains(':')) return;

      final destinationDir = await getApplicationDocumentsDirectory();
      final parts = result.split(':');
      if (parts.length != 2) throw const FormatException("Invalid format. Use IP:Code");
      
      final ip = parts[0];
      final code = int.tryParse(parts[1]);
      if (code == null) throw const FormatException("Invalid code.");

      _setTransferUI("Connecting to $ip...");
      await _startReceiver(ip, code, destinationDir.path);
      await _showSuccessState("All files saved to Files app!");
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Receive Error: ${e.toString()}")));
        await _setIdleUI();
      }
    }
  }

  Future<void> _startReceiver(String ip, int code, String destinationFolder) async {
    Socket? socket;
    try {
      socket = await Socket.connect(ip, port, timeout: const Duration(seconds: 15));
      socket.add(Uint8List(4)..buffer.asByteData().setInt32(0, code));
      await socket.flush();

      var dataStream = socket.asBroadcastStream();
      
      Future<Uint8List> readBytes(int count) async {
        final completer = Completer<Uint8List>();
        final buffer = BytesBuilder();
        late StreamSubscription subscription;
        subscription = dataStream.listen(
          (data) {
            buffer.add(data);
            if (buffer.length >= count) {
              subscription.cancel();
              completer.complete(Uint8List.fromList(buffer.toBytes().sublist(0, count)));
            }
          },
          onDone: () {
            if (!completer.isCompleted) completer.completeError("Socket closed prematurely.");
          },
          onError: (e) {
             if (!completer.isCompleted) completer.completeError(e);
          }
        );
        return await completer.future.timeout(const Duration(seconds: 30));
      }

      final fileCountBytes = await readBytes(4);
      final fileCount = fileCountBytes.buffer.asByteData().getInt32(0);

      for (int i = 0; i < fileCount; i++) {
        final fileNameLenBytes = await readBytes(2);
        final fileNameLen = fileNameLenBytes.buffer.asByteData().getInt16(0);
        final fileNameBytes = await readBytes(fileNameLen);
        final fileName = String.fromCharCodes(fileNameBytes);
        
        final fileSizebytes = await readBytes(8);
        final fileSize = fileSizebytes.buffer.asByteData().getInt64(0);

        if (mounted) {
          setState(() {
            _statusText = "Receiving ${i + 1}/$fileCount:\n$fileName";
            _progress = 0;
            _speedText = "0 MB/s";
          });
        }
        
        final outputFile = File(path.join(destinationFolder, fileName));
        var sink = outputFile.openWrite();
        
        int receivedSize = 0;
        var stopwatch = Stopwatch()..start();
        
        final completer = Completer<void>();
        late StreamSubscription subscription;
        subscription = dataStream.listen(
          (data) {
            sink.add(data);
            receivedSize += data.length;
            
            if (stopwatch.elapsedMilliseconds > 500) {
              final speed = receivedSize / (stopwatch.elapsedMilliseconds / 1000.0) / 1024 / 1024;
              if (mounted) {
                setState(() {
                  _progress = receivedSize / fileSize;
                  _speedText = "${speed.toStringAsFixed(2)} MB/s";
                });
              }
            }

            if (receivedSize >= fileSize) {
              subscription.cancel();
              completer.complete();
            }
          },
          onDone: () {
             if (!completer.isCompleted) completer.completeError("Socket closed before file was complete.");
          },
          onError: (e) {
             if (!completer.isCompleted) completer.completeError(e);
          }
        );

        await completer.future.timeout(const Duration(minutes: 30));
        await sink.flush();
        await sink.close();
      }
    } finally {
      socket?.destroy();
    }
  }

  Future<String?> _showIpCodePrompt() {
    final ipController = TextEditingController();
    final codeController = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text("Connect to Sender", style: TextStyle(color: Colors.black)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: ipController,
            autofocus: true,
            decoration: const InputDecoration(labelText: "Sender's IP"),
            style: const TextStyle(color: Colors.black),
          ),
          TextField(
            controller: codeController,
            decoration: const InputDecoration(labelText: "CODE"),
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Colors.black),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text("Cancel")),
          TextButton(onPressed: () => Navigator.of(context).pop("${ipController.text}:${codeController.text}"), child: const Text("Connect")),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20.0).copyWith(top: 60.0),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircleAvatar(radius: 40, backgroundImage: AssetImage('assets/profile.png')),
              const SizedBox(height: 20),
              const Text("File Share", style: TextStyle(fontSize: 32, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              const Text("Connect devices to the same Wi-Fi or hotspot.", style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 30),
              Container(
                padding: const EdgeInsets.all(20),
                margin: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: const [BoxShadow(color: Colors.black38, offset: Offset(5, 5), blurRadius: 10)],
                ),
                child: _buildContent(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- THIS IS THE MISSING METHOD ---
  Widget _buildContent() {
    final textStyle = const TextStyle(color: Colors.black, fontSize: 18, fontWeight: FontWeight.w600);
    switch (_currentState) {
      case TransferState.idle:
        return Column(key: const ValueKey('idle'), children: [
          Text(_statusText, style: textStyle, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          ElevatedButton(onPressed: _pickMedia, child: const Text("Select Photos & Videos")),
          const SizedBox(height: 10),
          ElevatedButton(onPressed: _pickFiles, child: const Text("Select Other Files")),
          const SizedBox(height: 10),
          ElevatedButton(onPressed: _receiveButton_Clicked, style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[700]), child: const Text("Receive", style: TextStyle(color: Colors.white))),
        ]);
      case TransferState.transferring:
        return Column(key: const ValueKey('transferring'), children: [
          Text(_statusText, style: textStyle.copyWith(fontSize: 16), textAlign: TextAlign.center),
          const SizedBox(height: 20),
          LinearProgressIndicator(value: _progress),
          const SizedBox(height: 8),
          Text(_speedText, style: const TextStyle(color: Colors.black, fontSize: 20, fontWeight: FontWeight.w600)),
        ]);
      case TransferState.success:
        return Column(key: const ValueKey('success'), children: [
          SizedBox(height: 120, child: Lottie.asset('assets/transfer_complete.json', repeat: false)),
          const SizedBox(height: 10),
          Text(_statusText, style: textStyle, textAlign: TextAlign.center),
        ]);
    }
  }
}
