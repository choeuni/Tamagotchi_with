import 'dart:convert';
import 'dart:async';
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
        scaffoldBackgroundColor: Colors.white,
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
  // 상태 변수
  int level = 1;
  int diamonds = 0;
  int gold = 0;
  int mood = 80;
  int fullness = 50;
  int hygiene = 100;
  int energy = 70;

  List<_FallingApple> _apples = [];
  List<_TapFeedback> _tapFeedbacks = [];
  final math.Random _random = math.Random();

  // AI 및 위치 변수
  double _charX = 0.0;
  double _charZ = -30.0;
  double _charYaw = 0;
  int _currentModelIndex = 0; // 0: stop, 1: walk, 2: hello
  Timer? _mainWanderTimer;
  
  int _rubCount = 0;
  bool _isHappyAction = false;
  bool _isEatingAction = false;
  Timer? _eatingActionTimer;

  final Color primaryColor = const Color(0xFF87CEEB);
  bool isOutdoor = false;
  
  String get currentBackground => isOutdoor 
      ? 'assets/backs/back_out.png' 
      : 'assets/backs/back_in.png';

  final WebSocketChannel channel = WebSocketChannel.connect(
    Uri.parse('ws://192.168.200.193:8000/ws/gesture'),
  );

  @override
  void initState() {
    super.initState();
    _startMainWandering();

    channel.stream.listen(
      (data) {
        final decoded = jsonDecode(data);
        setState(() {
          if (decoded['current_fullness'] != null) fullness = decoded['current_fullness'];
          if (decoded['gold'] != null) gold = decoded['gold'];
          if (decoded['diamonds'] != null) diamonds = decoded['diamonds'];
        });
      },
      onError: (error) => debugPrint("WebSocket Error: $error"),
    );
  }

  void _spawnApple() {
    setState(() {
      _apples.add(_FallingApple(
        id: DateTime.now().millisecondsSinceEpoch,
        x: _random.nextDouble() * 200 + 25,
        y: -50,
      ));
    });
    final message = jsonEncode({"action": "FEED"});
    channel.sink.add(message);
  }

  void _onAppleTapped(int id, double x, double y) {
    setState(() {
      _apples.removeWhere((apple) => apple.id == id);
      // 사과 터치 위치에 사과 이모티콘 피드백 추가
      _tapFeedbacks.add(_TapFeedback(
        id: DateTime.now().millisecondsSinceEpoch,
        x: x,
        y: y,
      ));
      
      // 캐릭터 머리 위 음표 피드백 활성화
      _isEatingAction = true;
      _eatingActionTimer?.cancel();
      _eatingActionTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _isEatingAction = false);
      });

      fullness = (fullness + 5).clamp(0, 100);
    });
  }

  // 메인 배회 AI
  void _startMainWandering() {
    _mainWanderTimer = Timer.periodic(const Duration(seconds: 12), (timer) async {
      if (!mounted || _isHappyAction) return;

      if (_random.nextDouble() < 0.6) { 
        final double targetX = (_random.nextDouble() - 0.5) * 180; 
        final double targetZ = _random.nextDouble() * 50 - 130;
        
        double dx = targetX - _charX;
        double dz = targetZ - _charZ;
        
        double newYaw;
        if (dz.abs() > dx.abs()) {
          newYaw = (dz > 0) ? 180 : 0; 
        } else {
          newYaw = (dx > 0) ? -90 : 90; 
        }

        if (mounted) {
          setState(() {
            _currentModelIndex = 1; // 걷기 시작
            _charYaw = newYaw;
          });
        }

        // 방향 전환 시간 대기
        await Future.delayed(const Duration(milliseconds: 500));
        
        if (mounted && !_isHappyAction) {
          setState(() {
            _charX = targetX;
            _charZ = targetZ;
          });
        }

        // 이동 지속 시간 (3.7초)
        await Future.delayed(const Duration(milliseconds: 3700));
        
        if (mounted && !_isHappyAction) {
          setState(() {
            _currentModelIndex = 0; // 정지
            _charYaw = 0; // 정지 시 정면
          });
        }
      }
    });
  }

  void _onRubUpdate(DragUpdateDetails details) {
    if (_isHappyAction) return;
    _rubCount++;
    if (_rubCount > 15) {
      _performHappyAction();
      _rubCount = 0;
    }
  }

  Future<void> _performHappyAction() async {
    setState(() {
      _isHappyAction = true;
      _currentModelIndex = 2; // Wave_One_Hand 인사
      _charYaw = 0;
      mood = (mood + 10).clamp(0, 100);
    });

    await Future.delayed(const Duration(seconds: 4));

    if (mounted) {
      setState(() {
        _isHappyAction = false;
        _currentModelIndex = 0; // 다시 정지
      });
    }
  }

  @override
  void dispose() {
    _mainWanderTimer?.cancel();
    _eatingActionTimer?.cancel();
    channel.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF9FAFB),
          image: DecorationImage(
            image: AssetImage(currentBackground),
            fit: BoxFit.cover,
            onError: (exception, stackTrace) => debugPrint("BG Not Found"),
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
                      child: Container(
                        width: double.infinity,
                        height: 450,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            AnimatedPositioned(
                              duration: const Duration(milliseconds: 3700),
                              curve: Curves.easeInOut,
                              left: screenWidth / 2 - 300 + _charX,
                              bottom: 40 + _charZ,
                              child: Transform.scale(
                                scale: 0.5 * (1.0 - (_charZ / 500)),
                                child: Container(
                                  width: 600,
                                  height: 600,
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      // 바닥 그림자
                                      Positioned(
                                        bottom: 165,
                                        child: Container(
                                          width: 140,
                                          height: 30,
                                          decoration: BoxDecoration(
                                            color: Colors.black.withValues(alpha: 0.2),
                                            borderRadius: const BorderRadius.all(Radius.elliptical(140, 30)),
                                          ),
                                        ),
                                      ),
                                      // 3D 캐릭터 레이어
                                      IndexedStack(
                                        index: _currentModelIndex,
                                        children: [
                                          _buildModelViewer('assets/models/TAMA1_stop.glb', 0, "stop"),
                                          _buildModelViewer('assets/models/TAMA1_Casual_Walk.glb', _charYaw, "walk"),
                                          _buildModelViewer('assets/models/TAMA1_Wave_One_Hand.glb', 0, "hello"),
                                        ],
                                      ),
                                      // 쓰다듬기 하트 이모티콘
                                      if (_isHappyAction)
                                        Positioned(
                                          top: 10,
                                          child: TweenAnimationBuilder<double>(
                                            tween: Tween(begin: 0.0, end: 1.0),
                                            duration: const Duration(milliseconds: 500),
                                            builder: (context, value, child) {
                                              return Opacity(
                                                opacity: value,
                                                child: Transform.translate(
                                                  offset: Offset(0, -40 * value),
                                                  child: const Text("❤️", style: TextStyle(fontSize: 40)),
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                      // 식사 음표 이모티콘
                                      if (_isEatingAction)
                                        Positioned(
                                          top: 10,
                                          child: TweenAnimationBuilder<double>(
                                            key: ValueKey(DateTime.now().millisecondsSinceEpoch),
                                            tween: Tween(begin: 0.0, end: 1.0),
                                            duration: const Duration(milliseconds: 800),
                                            builder: (context, value, child) {
                                              return Opacity(
                                                opacity: 1.0 - value,
                                                child: Transform.translate(
                                                  offset: Offset(0, -60 * value),
                                                  child: const Text("🎶", style: TextStyle(fontSize: 40)),
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                      // 인터랙션용 투명 오버레이
                                      GestureDetector(
                                        onPanUpdate: _onRubUpdate,
                                        behavior: HitTestBehavior.opaque,
                                        child: Container(
                                          width: double.infinity,
                                          height: double.infinity,
                                          color: Colors.transparent,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  _buildBottomMenu(),
                ],
              ),
              // 떨어지는 사과들
              ..._apples.map((apple) => _FallingAppleWidget(
                key: ValueKey(apple.id),
                apple: apple,
                onTapped: (x, y) => _onAppleTapped(apple.id, x, y),
                onFinished: () => setState(() => _apples.removeWhere((a) => a.id == apple.id)),
              )),
              // 사과 터치 피드백 (🍎)
              ..._tapFeedbacks.map((feedback) => _TapFeedbackWidget(
                key: ValueKey(feedback.id),
                feedback: feedback,
                onFinished: () => setState(() => _tapFeedbacks.removeWhere((f) => f.id == feedback.id)),
              )),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModelViewer(String src, double yaw, String stateKey) {
    return ModelViewer(
      key: ValueKey("$src-$yaw"), 
      src: src,
      alt: "다마고치",
      autoRotate: false,
      autoPlay: true,
      ar: false,
      cameraControls: false,
      disableZoom: true,
      backgroundColor: Colors.transparent,
      exposure: 0.5,
      shadowIntensity: 0,
      environmentImage: "neutral",
      cameraOrbit: "${yaw}deg 75deg 8m",
      fieldOfView: "30deg",
      cameraTarget: "0m 0.5m 0m",
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
                Navigator.push(context, MaterialPageRoute(builder: (context) => const ARCameraScreen()));
              }),
              const SizedBox(height: 12),
              _buildIconButton(isOutdoor ? Icons.home_rounded : Icons.directions_walk_rounded, () {
                setState(() => isOutdoor = !isOutdoor);
              }),
            ],
          ),
          _buildTopChip(Icons.monetization_on_rounded, "$gold", const Color(0xFFF6A000)),
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
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: Color(0xFF333D4B))),
        ],
      ),
    );
  }

  Widget _buildIconButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, 2))]),
        child: Icon(icon, color: const Color(0xFF8B95A1), size: 20),
      ),
    );
  }

  Widget _buildBottomMenu() {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 20, offset: const Offset(0, 8))]),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildMenuIcon(Icons.face_rounded, "기분", mood / 100.0, null),
          _buildMenuIcon(Icons.restaurant_rounded, "식사", fullness / 100.0, _spawnApple),
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
                    child: FractionallySizedBox(heightFactor: safePercentage, widthFactor: 1.0, child: Container(color: primaryColor)),
                  ),
                  Center(child: Icon(icon, color: safePercentage > 0.5 ? Colors.white : const Color(0xFF4E5968), size: 28)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF4E5968))),
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
  final Function(double x, double y) onTapped;
  final VoidCallback onFinished;
  const _FallingAppleWidget({super.key, required this.apple, required this.onTapped, required this.onFinished});
  @override
  State<_FallingAppleWidget> createState() => _FallingAppleWidgetState();
}

class _FallingAppleWidgetState extends State<_FallingAppleWidget> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: const Duration(seconds: 3), vsync: this);
    _animation = Tween<double>(begin: -50, end: 600).animate(_controller)..addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onFinished();
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
            onTap: () => widget.onTapped(widget.apple.x, _animation.value), 
            child: const Text("🍎", style: TextStyle(fontSize: 40))
          )
        );
      },
    );
  }
}

class _TapFeedback {
  final int id;
  final double x;
  final double y;
  _TapFeedback({required this.id, required this.x, required this.y});
}

class _TapFeedbackWidget extends StatefulWidget {
  final _TapFeedback feedback;
  final VoidCallback onFinished;
  const _TapFeedbackWidget({super.key, required this.feedback, required this.onFinished});

  @override
  State<_TapFeedbackWidget> createState() => _TapFeedbackWidgetState();
}

class _TapFeedbackWidgetState extends State<_TapFeedbackWidget> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacity;
  late Animation<double> _moveUp;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: const Duration(milliseconds: 800), vsync: this);
    _opacity = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _controller, curve: const Interval(0.5, 1.0, curve: Curves.easeOut)),
    );
    _moveUp = Tween<double>(begin: 0.0, end: -50.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onFinished();
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
      animation: _controller,
      builder: (context, child) {
        return Positioned(
          left: widget.feedback.x,
          top: widget.feedback.y + _moveUp.value,
          child: Opacity(
            opacity: _opacity.value,
            child: const Text("🍎", style: TextStyle(fontSize: 30)),
          ),
        );
      },
    );
  }
}
