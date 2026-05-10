import 'dart:convert';
import 'dart:math' as math;
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

class _TamagotchiMainState extends State<TamagotchiMain> with TickerProviderStateMixin {
  // 1. 상태 변수 (서버 DB와 동기화될 값들 포함)
  int level = 1;
  int diamonds = 0; // UI에서는 숨김 처리
  int gold = 0;

  // 상태 게이지를 위한 변수들 (0 ~ 100)
  int mood = 80;
  int fullness = 50;
  int hygiene = 100;
  int energy = 70;

  // 식사 시스템을 위한 변수들
  List<_FallingApple> _apples = [];
  final math.Random _random = math.Random();

  // 파스텔 하늘색 테마 컬러
  final Color primaryColor = const Color(0xFF87CEEB);

  // 배경화면 상태 관리
  bool isOutdoor = false;
  String get currentBackground => isOutdoor 
      ? 'assets/backs/back_out.png' // 추후 추가될 실외 배경
      : 'assets/backs/back_in.png';  // 현재 있는 실내 배경

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
        debugPrint("WebSocket Error: $error");
      },
    );
  }

  // 4. 식사 버튼 클릭 시 사과 생성
  void _spawnApple() {
    setState(() {
      _apples.add(_FallingApple(
        id: DateTime.now().millisecondsSinceEpoch,
        x: _random.nextDouble() * 200 + 25, // 캐릭터 주변 랜덤 위치
        y: -50,
      ));
    });
    
    // 서버에도 FEED 신호 전송 (동기화용)
    final message = jsonEncode({"action": "FEED"});
    channel.sink.add(message);
  }

  // 사과 터치 시 호출
  void _onAppleTapped(int id) {
    setState(() {
      _apples.removeWhere((apple) => apple.id == id);
      fullness = (fullness + 5).clamp(0, 100); // 배고픔 수치 증가
    });
  }

  @override
  void dispose() {
    channel.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF9FAFB),
          image: DecorationImage(
            image: AssetImage(currentBackground),
            fit: BoxFit.cover,
            // 실외 배경이 없을 경우를 대비해 에러 핸들링 (투명 이미지나 기본 배경으로 대체)
            onError: (exception, stackTrace) => debugPrint("Background image not found"),
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  _buildTopBar(),
                  Expanded(
                    child: Center(
                      child: SizedBox(
                        width: 250,
                        height: 250,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // 바닥 그림자
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
                            // 3D 모델 (X축 회전 제한, 정면/측면/후면 위주)
                            const ModelViewer(
                              src: 'assets/models/TAMA1_stop.glb',
                              alt: "다마고치 캐릭터",
                              autoRotate: false,
                              cameraControls: true,
                              disableZoom: true,
                              backgroundColor: Colors.transparent,
                              exposure: 0.5,
                              shadowIntensity: 1,
                              environmentImage: "neutral",
                              cameraOrbit: "0deg 75deg 105%", // 고도 고정으로 위아래 회전 제한
                              minCameraOrbit: "auto 75deg auto", 
                              maxCameraOrbit: "auto 75deg auto",
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  _buildBottomMenu(),
                ],
              ),
              // 떨어지는 사과들 레이어
              ..._apples.map((apple) => _FallingAppleWidget(
                key: ValueKey(apple.id),
                apple: apple,
                onTapped: () => _onAppleTapped(apple.id),
                onFinished: () {
                  setState(() {
                    _apples.removeWhere((a) => a.id == apple.id);
                  });
                },
              )),
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
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTopChip(Icons.stars_rounded, "Lv. $level", primaryColor),
              const SizedBox(height: 16),
              _buildIconButton(Icons.storefront_rounded, () {}),
              const SizedBox(height: 12),
              _buildIconButton(Icons.camera_alt_rounded, () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const ARCameraScreen()),
                );
              }),
              const SizedBox(height: 12),
              // 외출 버튼 추가
              _buildIconButton(
                isOutdoor ? Icons.home_rounded : Icons.directions_walk_rounded, 
                () {
                  setState(() {
                    isOutdoor = !isOutdoor;
                  });
                }
              ),
            ],
          ),
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
              color: Color(0xFF333D4B),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIconButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
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
            _spawnApple,
          ),
          _buildMenuIcon(Icons.wc_rounded, "화장실", hygiene / 100.0, null),
          _buildMenuIcon(Icons.dark_mode_rounded, "취침", energy / 100.0, null),
        ],
      ),
    );
  }

  Widget _buildMenuIcon(IconData icon, String label, double percentage, VoidCallback? onTap) {
    final safePercentage = percentage.clamp(0.0, 1.0);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 56,
            height: 56,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                children: [
                  Container(color: const Color(0xFFF2F4F6)),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: FractionallySizedBox(
                      heightFactor: safePercentage,
                      widthFactor: 1.0,
                      child: Container(color: primaryColor),
                    ),
                  ),
                  Center(
                    child: Icon(
                      icon,
                      color: safePercentage > 0.5 ? Colors.white : const Color(0xFF4E5968),
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

class _FallingApple {
  final int id;
  final double x;
  final double y;
  _FallingApple({required this.id, required this.x, required this.y});
}

class _FallingAppleWidget extends StatefulWidget {
  final _FallingApple apple;
  final VoidCallback onTapped;
  final VoidCallback onFinished;

  const _FallingAppleWidget({
    super.key,
    required this.apple,
    required this.onTapped,
    required this.onFinished,
  });

  @override
  State<_FallingAppleWidget> createState() => _FallingAppleWidgetState();
}

class _FallingAppleWidgetState extends State<_FallingAppleWidget> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 3),
      vsync: this,
    );
    _animation = Tween<double>(begin: -50, end: 600).animate(_controller)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          widget.onFinished();
        }
      });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Positioned(
          left: widget.apple.x,
          top: _animation.value,
          child: GestureDetector(
            onTap: widget.onTapped,
            child: const Text(
              "🍎",
              style: TextStyle(fontSize: 40),
            ),
          ),
        );
      },
    );
  }
}
