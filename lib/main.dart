import 'dart:async';
import 'dart:io';
import 'dart:isolate';
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
const int chunkSize = 1024 * 1024; // 1MB chunks for optimal speed

// --- Data Models for Isolate Communication ---
class IsolateCommand {
  final String ip;
  final int code;
  final String destinationFolder;
  final SendPort replyPort;
  IsolateCommand(this.ip, this.code, this.destinationFolder, this.replyPort);
}

abstract class IsolateStatus {}
class ProgressUpdate extends IsolateStatus {
  final double progress;
  final String speed;
  ProgressUpdate(this.progress, this.speed);
}
class StatusUpdate extends IsolateStatus {
  final String message;
  StatusUpdate(this.message);
}
class TransferError extends IsolateStatus {
  final String error;
  TransferError(this.error);
}
class TransferComplete extends IsolateStatus {}

// --- Isolate Entry Point (Receiver) ---
void receiverIsolate(IsolateCommand command) async {
  Socket? socket;
  try {
    socket = await Socket.connect(command.ip, port, timeout: const Duration(seconds: 15));
    socket.add(Uint8List(4)..buffer.asByteData().setInt32(0, command.code));
    await socket.flush();

    final buffer = BytesBuilder();
    Completer<void>? dataAvailable;

    final streamSubscription = socket.listen(
      (data) {
        buffer.add(data);
        if (dataAvailable != null && !dataAvailable!.isCompleted) {
          dataAvailable!.complete();
        }
      },
      onError: (error) {
        command.replyPort.send(TransferError(error.toString()));
      },
      onDone: () {
        if (dataAvailable != null && !dataAvailable!.isCompleted) {
          dataAvailable!.completeError("Socket closed unexpectedly.");
        }
      },
      cancelOnError: true,
    );

    Future<Uint8List> readBytes(int count) async {
      while (buffer.length < count) {
        dataAvailable = Completer<void>();
        await dataAvailable!.future.timeout(const Duration(seconds: 45));
      }
      final bytes = buffer.toBytes().sublist(0, count);
      final remaining = buffer.toBytes().sublist(count);
      buffer.clear();
      buffer.add(remaining);
      return Uint8List.fromList(bytes);
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

      command.replyPort.send(StatusUpdate("Receiving ${i + 1}/$fileCount:\n$fileName"));
      
      final outputFile = File(path.join(command.destinationFolder, fileName));
      var sink = outputFile.openWrite();
      
      int receivedSize = 0;
      var stopwatch = Stopwatch()..start();

      while (receivedSize < fileSize) {
        final toRead = min(fileSize - receivedSize, chunkSize); // Use 1MB chunks
        final chunk = await readBytes(toRead);
        sink.add(chunk);
        receivedSize += chunk.length;

        if (stopwatch.elapsedMilliseconds > 300) {
            final speed = (receivedSize / stopwatch.elapsed.inMilliseconds) * 1000 / (1024 * 1024);
            command.replyPort.send(ProgressUpdate(receivedSize / fileSize, "${speed.toStringAsFixed(1)} MB/s"));
        }
      }
      
      await sink.flush();
      await sink.close();
    }

    socket.add([1]);
    await socket.flush();
    command.replyPort.send(TransferComplete());
    
    await streamSubscription.cancel();

  } catch (e) {
    command.replyPort.send(TransferError(e.toString()));
  } finally {
    socket?.destroy();
  }
}

// --- Main App Code ---
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
      home: const MainPage(),
    );
  }
}

enum TransferState { idle, transferring, success }

class MainPage extends StatefulWidget {
  const MainPage({super.key});
  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  TransferState _currentState = TransferState.idle;
  String _statusText = "Initializing...";
  String _localIp = "Getting IP...";
  double _progress = 0.0;
  String _speedText = "";
  ServerSocket? _serverSocket;
  ReceivePort? _receivePort;

  @override
  void initState() {
    super.initState();
    _setIdleUI();
  }

  @override
  void dispose() {
    _serverSocket?.close();
    _receivePort?.close();
    super.dispose();
  }

  Future<void> _setIdleUI() async {
    _receivePort?.close();
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
    List<File> files = [];
    for (var asset in result) {
      final file = await asset.file;
      if (file != null) files.add(file);
    }
    if (files.isNotEmpty) await _startSending(files);
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true, withData: false, withReadStream: true);
    if (result == null || result.files.isEmpty) return;
    List<File> files = result.paths.where((path) => path != null).map((path) => File(path!)).toList();
    if (files.isNotEmpty) await _startSending(files);
  }

  Future<void> _startSending(List<File> files) async {
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

  // --- SENDER LOGIC (with 1MB chunks) ---
  Future<void> _handleClient(Socket client, List<File> files, int securityCode) async {
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
      
      int totalFilesSize = 0;
      for(var file in files){
        totalFilesSize += await file.length();
      }

      int totalBytesSent = 0;
      var stopwatch = Stopwatch()..start();

      for (int i = 0; i < files.length; i++) {
        final file = files[i];
        final fileSize = await file.length();
        final fileName = path.basename(file.path);
        
        final fileNameBytes = fileName.codeUnits;
        client.add(Uint8List(2)..buffer.asByteData().setInt16(0, fileNameBytes.length));
        await client.flush();
        client.add(fileNameBytes);
        await client.flush();
        client.add(Uint8List(8)..buffer.asByteData().setInt64(0, fileSize));
        await client.flush();

        final fileStream = file.openRead();

        await for (final chunk in fileStream) {
            client.add(chunk);
            totalBytesSent += chunk.length;

            if(stopwatch.elapsedMilliseconds > 250){
                final speed = (totalBytesSent / stopwatch.elapsed.inMilliseconds) * 1000 / (1024*1024);
                if (mounted) setState(() {
                    _statusText = "Sending ${i + 1}/${files.length}:\n$fileName";
                    _progress = totalBytesSent / totalFilesSize;
                    _speedText = "${speed.toStringAsFixed(1)} MB/s";
                });
            }
        }
        await client.flush();
      }

      await client.first.timeout(const Duration(seconds: 60));
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
      _receivePort = ReceivePort();
      final command = IsolateCommand(ip, code, destinationDir.path, _receivePort!.sendPort);
      await Isolate.spawn(receiverIsolate, command);

      _receivePort!.listen((message) {
        if (message is ProgressUpdate) {
          if (mounted) setState(() {
            _progress = message.progress;
            _speedText = message.speed;
          });
        } else if (message is StatusUpdate) {
          if (mounted) setState(() => _statusText = message.message);
        } else if (message is TransferError) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Receive Error: ${message.error}")));
            _setIdleUI();
          }
        } else if (message is TransferComplete) {
          if (mounted) {
            _showSuccessState("All files saved to Files app!");
          }
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: ${e.toString()}")));
        await _setIdleUI();
      }
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
