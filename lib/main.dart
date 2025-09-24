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

// Constants
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
  double _progress = 0.0;
  String _speedText = "";
  String _localIp = "Getting IP...";
  List<PlatformFile> _filesToSend = [];
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

  // --- UI State Management ---
  Future<void> _setIdleUI() async {
    await [Permission.photos, Permission.storage].request();
    _filesToSend.clear();
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
    await Future.delayed(const Duration(seconds: 3));
    if (mounted) await _setIdleUI();
  }

  // --- Networking Logic (Sender) ---
  Future<void> _sendButton_Clicked() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty) return;

    _filesToSend = result.files;
    _setTransferUI("${_filesToSend.length} file(s) ready to send.");
    
    try {
      final securityCode = Random().nextInt(899999) + 100000;
      _serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      _setTransferUI("On the other device, enter:\nIP: $_localIp\nCode: $securityCode");
      
      await for (var clientSocket in _serverSocket!) {
        await _handleClient(clientSocket, _filesToSend, securityCode);
        break;
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Send Error: ${e.toString()}")));
      await _setIdleUI();
    } finally {
      await _serverSocket?.close();
      _serverSocket = null;
    }
  }

  Future<void> _handleClient(Socket client, List<PlatformFile> files, int securityCode) async {
    try {
      var completer = Completer<Uint8List>();
      var subscription = client.listen(
        (data) {
          if (!completer.isCompleted) completer.complete(data);
        }
      );
      
      final receivedData = await completer.future;
      subscription.cancel();
      final receivedCode = receivedData.buffer.asByteData().getInt32(0);
      if (receivedCode != securityCode) throw Exception("Wrong security code.");

      client.add(Uint8List(4)..buffer.asByteData().setInt32(0, files.length));
      await client.flush();

      for (int i = 0; i < files.length; i++) {
        final file = files[i];
        final fileBytes = File(file.path!).readAsBytesSync();
        final fileNameBytes = file.name.codeUnits;

        setState(() => _statusText = "Sending ${i + 1}/${files.length}:\n${file.name}");

        client.add(Uint8List(2)..buffer.asByteData().setInt16(0, fileNameBytes.length));
        await client.flush();
        client.add(fileNameBytes);
        await client.flush();
        client.add(Uint8List(8)..buffer.asByteData().setInt64(0, fileBytes.length));
        await client.flush();
        client.add(fileBytes);
        await client.flush();
      }
      await _showSuccessState("Transfer Complete!");
    } catch (e) {
       if (!mounted) return;
       ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Handle client error: ${e.toString()}")));
       await _setIdleUI();
    } finally {
       client.close();
    }
  }

  // --- Networking Logic (Receiver) ---
  Future<void> _receiveButton_Clicked() async {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final String? result = await _showIpCodePrompt();
        if (result == null || !result.contains(':')) return;

        final destinationDir = await getApplicationDocumentsDirectory();
        final parts = result.split(':');
        final ip = parts[0];
        final code = int.tryParse(parts[1]);
        if (code == null) throw const FormatException("Invalid code.");

        _setTransferUI("Connecting to $ip...");
        await _startReceiver(ip, code, destinationDir.path);
        await _showSuccessState("All files saved!");
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Receive Error: ${e.toString()}")));
          await _setIdleUI();
        }
      }
    });
  }

  Future<void> _startReceiver(String ip, int code, String destinationFolder) async {
    Socket? socket;
    try {
      socket = await Socket.connect(ip, port, timeout: const Duration(seconds: 10));
      socket.add(Uint8List(4)..buffer.asByteData().setInt32(0, code));

      var buffer = <int>[];
      var completer = Completer<void>();
      var subscription = socket.listen(
        (data) {
          buffer.addAll(data);
          if (!completer.isCompleted) completer.complete();
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        }
      );

      Future<Uint8List> readBytes(int count) async {
        while (buffer.length < count) {
          completer = Completer<void>();
          await completer.future;
        }
        var result = Uint8List.fromList(buffer.sublist(0, count));
        buffer.removeRange(0, count);
        return result;
      }

      final fileCountBytes = await readBytes(4);
      final fileCount = fileCountBytes.buffer.asByteData().getInt32(0);

      for (int i = 0; i < fileCount; i++) {
        final fileNameLenBytes = await readBytes(2);
        final fileNameLen = fileNameLenBytes.buffer.asByteData().getInt16(0);
        final fileNameBytes = await readBytes(fileNameLen);
        final fileName = String.fromCharCodes(fileNameBytes);
        if (mounted) setState(() => _statusText = "Receiving ${i + 1}/$fileCount:\n$fileName");

        final fileSizebytes = await readBytes(8);
        final fileSize = fileSizebytes.buffer.asByteData().getInt64(0);
        
        final fileData = await readBytes(fileSize);
        final outputFile = File(path.join(destinationFolder, fileName));
        await outputFile.writeAsBytes(fileData);
      }
      subscription.cancel();
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
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: ipController, decoration: const InputDecoration(labelText: "Sender's IP"), style: const TextStyle(color: Colors.black)),
            TextField(controller: codeController, decoration: const InputDecoration(labelText: "CODE"), keyboardType: TextInputType.number, style: const TextStyle(color: Colors.black)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text("Cancel")),
          TextButton(onPressed: () => Navigator.of(context).pop("${ipController.text}:${codeController.text}"), child: const Text("Connect")),
        ],
      ),
    );
  }

  // --- UI Build Method ---
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
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: _buildContent(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    final textStyle = const TextStyle(color: Colors.black, fontSize: 18, fontWeight: FontWeight.w600);
    switch (_currentState) {
      case TransferState.idle:
        return Column(
          key: const ValueKey('idle'),
          children: [
            Text(_statusText, style: textStyle, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(child: ElevatedButton(onPressed: _sendButton_Clicked, child: const Text("Send"))),
                const SizedBox(width: 10),
                Expanded(child: ElevatedButton(onPressed: _receiveButton_Clicked, child: const Text("Receive"))),
              ],
            ),
          ],
        );
      case TransferState.transferring:
        return Column(
          key: const ValueKey('transferring'),
          children: [
            Text(_statusText, style: textStyle.copyWith(fontSize: 16), textAlign: TextAlign.center),
            const SizedBox(height: 20),
            LinearProgressIndicator(value: _progress, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 8),
            Text(_speedText, style: const TextStyle(color: Colors.black, fontSize: 20, fontWeight: FontWeight.w600)),
          ],
        );
      case TransferState.success:
        return Column(
          key: const ValueKey('success'),
          children: [
            SizedBox(
              height: 120,
              child: Lottie.asset('assets/transfer_complete.json', repeat: false),
            ),
            const SizedBox(height: 10),
            Text(_statusText, style: textStyle, textAlign: TextAlign.center),
          ],
        );
    }
  }
}
