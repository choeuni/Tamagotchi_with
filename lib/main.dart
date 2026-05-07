import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFFFFF9F0),
        fontFamily: 'MyCustomFont',
      ),
      home: const TamagotchiMain(),
    );
  }
}

class TamagotchiMain extends StatefulWidget {
  const TamagotchiMain({super.key});

  @override
  State<TamagotchiMain> createState() => _TamagotchiMainState();
}

class _TamagotchiMainState extends State<TamagotchiMain> {
  // 1. 상태 변수 (서버 DB와 동기화될 값들)
  int level = 1;
  int diamonds = 0;
  int gold = 0;
  int fullness = 50;

  // 2. WebSocket 채널 설정
  final WebSocketChannel channel = WebSocketChannel.connect(
    Uri.parse('ws://192.168.200.193:8000/ws/gesture'), // 본인 IP 입력
  );

  @override
  void initState() {
    super.initState();

    // 3. 서버로부터 오는 실시간 데이터 수신 대기
    channel.stream.listen(
      (data) {
        final decoded = jsonDecode(data);
        setState(() {
          if (decoded['current_fullness'] != null) {
            fullness = decoded['current_fullness'];
          }
          if (decoded['gold'] != null) {
            gold = decoded['gold'];
          }
          if (decoded['diamonds'] != null) {
            diamonds = decoded['diamonds'];
          }
        });
      },
      onError: (error) {
        print("WebSocket 에러: $error");
      },
    );
  }

  // 4. 재화 증가 함수 (서버에 알림 전송)
  void _earnReward() {
    final message = jsonEncode({
      "action": "EARN_REWARD",
      "gold_gain": 100,
      "diamond_gain": 10,
    });
    channel.sink.add(message);
  }

  // 5. 식사 함수 (서버에 FEED 신호 전송)
  void _feedTamagotchi() {
    final message = jsonEncode({"action": "FEED"});
    channel.sink.add(message);
  }

  @override
  void dispose() {
    channel.sink.close(); // 앱 종료 시 연결 해제
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            _buildFullnessGauge(),
            Expanded(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 바닥 그림자
                  Positioned(
                    bottom: 40,
                    child: Container(
                      width: 220,
                      height: 60,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.08),
                        borderRadius: const BorderRadius.all(
                          Radius.elliptical(220, 60),
                        ),
                      ),
                    ),
                  ),
                  // 3D 모델
                  const ModelViewer(
                    src: 'assets/models/tama1.glb',
                    alt: "다마고치 캐릭터",
                    autoRotate: false,
                    cameraControls: true,
                    disableZoom: true,
                    backgroundColor: Colors.transparent,
                  ),
                  // 테스트용 재화 증가 버튼
                  Positioned(
                    bottom: 80,
                    right: 24,
                    child: FloatingActionButton(
                      elevation: 2,
                      backgroundColor: const Color(0xFFFFB4A2),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      onPressed: _earnReward,
                      child: const Icon(
                        Icons.add_shopping_cart,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _buildBottomMenu(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _buildTopIcon(
            Icons.stars_rounded,
            "Lv. $level",
            const Color(0xFF7CAFFF),
          ),
          Row(
            children: [
              _buildTopIcon(
                Icons.diamond_rounded,
                "$diamonds",
                const Color(0xFFFF9EB5),
              ),
              const SizedBox(width: 12),
              _buildTopIcon(
                Icons.monetization_on_rounded,
                "$gold",
                const Color(0xFFFFC56C),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTopIcon(IconData icon, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: Color(0xFF555555),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFullnessGauge() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            const Icon(
              Icons.restaurant_menu_rounded,
              color: Color(0xFFA5D6A7),
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        "배고픔",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: Color(0xFF666666),
                        ),
                      ),
                      Text(
                        "$fullness%",
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: Color(0xFFA5D6A7),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: LinearProgressIndicator(
                      value: fullness / 100,
                      minHeight: 10,
                      backgroundColor: const Color(0xFFF0F0F0),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        Color(0xFFA5D6A7),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomMenu() {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildMenuIcon(
            Icons.face_rounded,
            "기분",
            const Color(0xFFFFB4A2),
            null,
          ),
          _buildMenuIcon(
            Icons.restaurant_rounded,
            "식사",
            const Color(0xFFA5D6A7),
            _feedTamagotchi,
          ),
          _buildMenuIcon(
            Icons.wc_rounded,
            "화장실",
            const Color(0xFF90CAF9),
            null,
          ),
          _buildMenuIcon(
            Icons.dark_mode_rounded,
            "취침",
            const Color(0xFFB39DDB),
            null,
          ),
          _buildMenuIcon(
            Icons.home_rounded,
            "외출",
            const Color(0xFFF48FB1),
            null,
          ),
        ],
      ),
    );
  }

  Widget _buildMenuIcon(
    IconData icon,
    String label,
    Color color,
    VoidCallback? onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 26),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF777777),
            ),
          ),
        ],
      ),
    );
  }
}
