import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:camera/camera.dart';
import 'camera_screen.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint("Failed to load cameras: $e");
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.white, // 기본 깔끔한 흰색 배경
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
  // 1. 상태 변수 (서버 DB와 동기화될 값들 포함)
  int level = 1;
  int diamonds = 0; // UI에서는 숨김 처리
  int gold = 0;

  // 상태 게이지를 위한 변수들 (0 ~ 100)
  int mood = 80;
  int fullness = 50;
  int hygiene = 100;
  int energy = 70;

  // 파스텔 하늘색 테마 컬러
  final Color primaryColor = const Color(0xFF87CEEB);

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
          // TODO: 서버에서 mood, hygiene, energy 값을 내려주면 여기서 파싱하여 연동
        });
      },
      onError: (error) {
        // 에러 처리
      },
    );
  }

  // 4. 식사 함수 (서버에 FEED 신호 전송)
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
      body: Container(
        // 개발자 참고: 추후 배경 이미지를 삽입할 경우 아래 주석을 해제하고 이미지를 적용하세요.
        decoration: const BoxDecoration(
          color: Color(0xFFF9FAFB), // 토스 스타일의 아주 연한 회색 배경
          // image: DecorationImage(
          //   image: AssetImage('assets/images/background_placeholder.png'),
          //   fit: BoxFit.cover,
          // ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildTopBar(),
              Expanded(
                child: Center(
                  child: SizedBox(
                    // 기존 크기의 약 1/2 수준으로 축소 (가로세로 250 내외)
                    width: 250,
                    height: 250,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // 바닥 그림자 (작게 조정)
                        Positioned(
                          bottom: 10,
                          child: Container(
                            width: 120,
                            height: 30,
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.06),
                              borderRadius: const BorderRadius.all(
                                Radius.elliptical(120, 30),
                              ),
                            ),
                          ),
                        ),
                        // 3D 모델
                        const ModelViewer(
                          src: 'assets/models/TAMA1_stop.glb',
                          alt: "다마고치 캐릭터",
                          autoRotate: false,
                          cameraControls: true,
                          disableZoom: true,
                          backgroundColor: Colors.transparent,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              _buildBottomMenu(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 좌측 영역: 레벨 + 상점/카메라 버튼 (세로 배치, 텍스트 없음)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTopChip(Icons.stars_rounded, "Lv. $level", primaryColor),
              const SizedBox(height: 16),
              _buildIconButton(Icons.storefront_rounded, () {
                // 상점 로직
              }),
              const SizedBox(height: 12),
              _buildIconButton(Icons.camera_alt_rounded, () {
                // AR 카메라 화면으로 이동
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const ARCameraScreen(),
                  ),
                );
              }),
            ],
          ),
          // 우측 영역: 재화 (골드 하나로 통일)
          _buildTopChip(
            Icons.monetization_on_rounded,
            "$gold",
            const Color(0xFFF6A000),
          ),
        ],
      ),
    );
  }

  Widget _buildTopChip(IconData icon, String text, Color iconColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              color: Color(0xFF333D4B), // 진한 텍스트
            ),
          ),
        ],
      ),
    );
  }

  // 텍스트 없이 둥근 아이콘만 남긴 버튼 (onTap 파라미터 추가)
  Widget _buildIconButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle, // 둥근 원형
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(icon, color: const Color(0xFF8B95A1), size: 20),
      ),
    );
  }

  Widget _buildBottomMenu() {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildMenuIcon(Icons.face_rounded, "기분", mood / 100.0, null),
          _buildMenuIcon(
            Icons.restaurant_rounded,
            "식사",
            fullness / 100.0,
            _feedTamagotchi,
          ),
          _buildMenuIcon(Icons.wc_rounded, "화장실", hygiene / 100.0, null),
          _buildMenuIcon(Icons.dark_mode_rounded, "취침", energy / 100.0, null),
        ],
      ),
    );
  }

  Widget _buildMenuIcon(
    IconData icon,
    String label,
    double percentage,
    VoidCallback? onTap,
  ) {
    // 안전을 위해 0.0 ~ 1.0 범위로 클램핑
    final safePercentage = percentage.clamp(0.0, 1.0);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 내부에 게이지가 차오르는 둥근 네모 컨테이너
          SizedBox(
            width: 56,
            height: 56,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                children: [
                  // 기본 배경 (연한 회색)
                  Container(color: const Color(0xFFF2F4F6)),
                  // 차오르는 게이지 (바닥에서부터)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: FractionallySizedBox(
                      heightFactor: safePercentage,
                      widthFactor: 1.0,
                      child: Container(
                        color: primaryColor, // 파스텔 하늘색
                      ),
                    ),
                  ),
                  // 중앙의 아이콘
                  Center(
                    child: Icon(
                      icon,
                      color: safePercentage > 0.5
                          ? Colors.white
                          : const Color(0xFF4E5968), // 게이지에 따라 아이콘 색상 변경
                      size: 28,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF4E5968),
            ),
          ),
        ],
      ),
    );
  }
}
