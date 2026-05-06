import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:convert';

void main() {
  runApp(const MaterialApp(home: TamagotchiApp()));
}

class TamagotchiApp extends StatefulWidget {
  const TamagotchiApp({super.key});

  @override
  State<TamagotchiApp> createState() => _TamagotchiAppState();
}

class _TamagotchiAppState extends State<TamagotchiApp> {
  // 1. 서버 전화를 연결합니다 (에뮬레이터 전용 주소)
  final WebSocketChannel _channel = WebSocketChannel.connect(
    Uri.parse('ws://10.0.2.2:8000/ws/gesture'),
  );

  String _serverMessage = "서버 대기 중...";
  int _fullness = 0;

  @override
  void dispose() {
    _channel.sink.close(); // 앱 종료 시 전화 끊기
    super.dispose();
  }

  // 2. 서버에 "밥 주기" 편지 보내기 함수
  void _feedTamagotchi() {
    _channel.sink.add(jsonEncode({
      "action": "FEED"
    }));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("다마고치 서버 테스트")),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 3. 서버가 하는 말을 실시간으로 듣는 화면
            StreamBuilder(
              stream: _channel.stream,
              builder: (context, snapshot) {
                if (snapshot.hasData) {
                  // 서버가 보낸 JSON 데이터를 해석합니다
                  var data = jsonDecode(snapshot.data);
                  _serverMessage = data['message'];
                  _fullness = data['current_fullness'];
                }
                return Column(
                  children: [
                    Text("서버 상태: $_serverMessage", style: const TextStyle(fontSize: 20)),
                    const SizedBox(height: 10),
                    Text("현재 포만감: $_fullness", style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold)),
                  ],
                );
              },
            ),
            const SizedBox(height: 30),
            ElevatedButton(
              onPressed: _feedTamagotchi,
              child: const Text("밥 주기 (서버로 전송)"),
            ),
          ],
        ),
      ),
    );
  }
}