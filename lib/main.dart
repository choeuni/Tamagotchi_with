import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:camera/camera.dart';
import 'camera_screen.dart';
import 'database_helper.dart';

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
  int level = 1;
  int exp = 0;
  int diamonds = 0;
  int gold = 0;
  int mood = 80;
  int fullness = 50;
  int hygiene = 100;
  int energy = 70;

  bool _isEvolving = false;

  final List<_FallingApple> _apples = [];
  final List<_TapFeedback> _tapFeedbacks = [];
  final math.Random _random = math.Random();

  double _charX = 0.0;
  double _charZ = -30.0;
  int _currentModelIndex = 0;
  Timer? _mainWanderTimer;

  int _rubCount = 0;
  bool _isHappyAction = false;
  bool _isEatingAction = false;
  Timer? _eatingActionTimer;

  final Color primaryColor = const Color(0xFF87CEEB);
  bool isOutdoor = false;

  String get currentBackground =>
      isOutdoor ? 'assets/backs/back_out.png' : 'assets/backs/back_in.png';

  // 0=유아기(Lv1-4), 1=청소년기(Lv5-9), 2=성인기(Lv10+)
  int get _evolutionStage {
    if (level < 5) return 0;
    if (level < 10) return 1;
    return 2;
  }

  static const _stageNames = ['유아기', '청소년기', '성인기'];
  String get _stageName => _stageNames[_evolutionStage];

  int get _levelForNextStage {
    if (level < 5) return 5;
    if (level < 10) return 10;
    return level;
  }

  String get _nextStageName {
    if (_evolutionStage < 2) return _stageNames[_evolutionStage + 1];
    return '성인기';
  }

  final WebSocketChannel channel = WebSocketChannel.connect(
    Uri.parse('wss://unsmooth-nacho-glancing.ngrok-free.dev/ws/gesture'),
  );

  @override
  void initState() {
    super.initState();
    _loadInitialData();
    _startMainWandering();

    channel.stream.listen(
      (data) {
        debugPrint("서버 데이터 수신: $data");
        final decoded = jsonDecode(data);
        if (mounted) {
          setState(() {
            if (decoded['current_fullness'] != null) fullness = decoded['current_fullness'];
            if (decoded['gold'] != null) gold = decoded['gold'];
            if (decoded['diamonds'] != null) diamonds = decoded['diamonds'];
            if (decoded['level'] != null) level = decoded['level'];
            if (decoded['mood'] != null) mood = decoded['mood'];
            if (decoded['hygiene'] != null) hygiene = decoded['hygiene'];
            if (decoded['energy'] != null) energy = decoded['energy'];
          });
          DatabaseHelper().updateTamagotchi(decoded);
        }
      },
      onError: (error) => debugPrint("WebSocket Error: $error"),
      onDone: () => debugPrint("WebSocket 연결 종료"),
    );
  }

  Future<void> _loadInitialData() async {
    final data = await DatabaseHelper().getTamagotchi();
    if (data != null && mounted) {
      setState(() {
        level = data['level'] ?? level;
        exp = data['exp'] ?? exp;
        gold = data['gold'] ?? gold;
        diamonds = data['diamonds'] ?? diamonds;
        mood = data['mood'] ?? mood;
        fullness = data['fullness'] ?? fullness;
        hygiene = data['hygiene'] ?? hygiene;
        energy = data['energy'] ?? energy;
      });
    }
  }

  void _gainExp(int amount) {
    final stageBefore = _evolutionStage;

    setState(() {
      exp += amount;
      while (exp >= 100) {
        exp -= 100;
        level++;
      }
    });

    _saveProgress();

    if (mounted && _evolutionStage > stageBefore) {
      _triggerEvolution();
    }
  }

  Future<void> _saveProgress() async {
    await DatabaseHelper().updateTamagotchi({
      'level': level,
      'exp': exp,
      'gold': gold,
      'diamonds': diamonds,
      'mood': mood,
      'fullness': fullness,
      'hygiene': hygiene,
      'energy': energy,
    });
  }

  Future<void> _triggerEvolution() async {
    setState(() => _isEvolving = true);
    await Future.delayed(const Duration(milliseconds: 3500));
    if (mounted) setState(() => _isEvolving = false);
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
      _tapFeedbacks.add(_TapFeedback(
        id: DateTime.now().millisecondsSinceEpoch,
        x: x,
        y: y,
      ));

      _isEatingAction = true;
      _eatingActionTimer?.cancel();
      _eatingActionTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _isEatingAction = false);
      });

      fullness = (fullness + 5).clamp(0, 100);
    });
    _gainExp(10);
  }

  void _startMainWandering() {
    _mainWanderTimer = Timer.periodic(const Duration(seconds: 12), (timer) async {
      if (!mounted || _isHappyAction) return;

      if (_random.nextDouble() < 0.6) {
        final double targetX = (_random.nextDouble() - 0.5) * 180;
        final double targetZ = _random.nextDouble() * 50 - 130;

        double dx = targetX - _charX;
        double dz = targetZ - _charZ;

        int nextIndex;
        if (dz.abs() > dx.abs()) {
          nextIndex = (dz > 0) ? 2 : 1;
        } else {
          nextIndex = (dx > 0) ? 4 : 3;
        }

        if (mounted) {
          setState(() => _currentModelIndex = nextIndex);
        }

        await Future.delayed(const Duration(milliseconds: 500));

        if (mounted && !_isHappyAction) {
          setState(() {
            _charX = targetX;
            _charZ = targetZ;
          });
        }

        await Future.delayed(const Duration(milliseconds: 3700));

        if (mounted && !_isHappyAction) {
          setState(() => _currentModelIndex = 0);
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
      _currentModelIndex = 5;
      mood = (mood + 10).clamp(0, 100);
    });

    _gainExp(15);

    await Future.delayed(const Duration(seconds: 4));

    if (mounted) {
      setState(() {
        _isHappyAction = false;
        _currentModelIndex = 0;
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
                    child: SizedBox(
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
                              child: SizedBox(
                                width: 600,
                                height: 600,
                                child: _buildCharacterInner(),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _buildBottomMenu(),
                ],
              ),
              ..._apples.map((apple) => _FallingAppleWidget(
                    key: ValueKey(apple.id),
                    apple: apple,
                    onTapped: (x, y) => _onAppleTapped(apple.id, x, y),
                    onFinished: () =>
                        setState(() => _apples.removeWhere((a) => a.id == apple.id)),
                  )),
              ..._tapFeedbacks.map((feedback) => _TapFeedbackWidget(
                    key: ValueKey(feedback.id),
                    feedback: feedback,
                    onFinished: () => setState(
                        () => _tapFeedbacks.removeWhere((f) => f.id == feedback.id)),
                  )),
              if (_isEvolving)
                Positioned.fill(
                  child: _EvolutionOverlay(stageName: _stageName),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCharacterInner() {
    // 유아기: 알 캐릭터 위젯
    if (_evolutionStage == 0) {
      return _EggCharacterWidget(
        level: level,
        isHappyAction: _isHappyAction,
        isEatingAction: _isEatingAction,
        onRubUpdate: _onRubUpdate,
      );
    }

    // 청소년기/성인기: 3D 모델 (청소년기는 80% 스케일)
    final double stageScale = _evolutionStage == 1 ? 0.8 : 1.0;

    return Stack(
      alignment: Alignment.center,
      children: [
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
        Transform.scale(
          scale: stageScale,
          child: IndexedStack(
            index: _currentModelIndex,
            children: [
              _buildModelViewer('assets/models/TAMA1_stop.glb', 0, "stop"),
              _buildModelViewer('assets/models/TAMA1_Casual_Walk.glb', 0, "walk_f"),
              _buildModelViewer('assets/models/TAMA1_Casual_Walk.glb', 180, "walk_b"),
              _buildModelViewer('assets/models/TAMA1_Casual_Walk.glb', 90, "walk_l"),
              _buildModelViewer('assets/models/TAMA1_Casual_Walk.glb', -90, "walk_r"),
              _buildModelViewer('assets/models/TAMA1_Wave_One_Hand.glb', 0, "hello"),
            ],
          ),
        ),
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
    );
  }

  Widget _buildModelViewer(String src, double yaw, String stateKey) {
    return ModelViewer(
      key: ValueKey(stateKey),
      src: src,
      alt: "다마고치",
      autoRotate: false,
      autoPlay: true,
      ar: false,
      cameraControls: false,
      disableZoom: true,
      backgroundColor: Colors.transparent,
      loading: Loading.eager,
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
              _buildLevelChip(),
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
              _buildIconButton(
                isOutdoor ? Icons.home_rounded : Icons.directions_walk_rounded,
                () => setState(() => isOutdoor = !isOutdoor),
              ),
            ],
          ),
          _buildTopChip(Icons.monetization_on_rounded, "$gold", const Color(0xFFF6A000)),
        ],
      ),
    );
  }

  Widget _buildLevelChip() {
    final bool isMaxStage = _evolutionStage >= 2;

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
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.stars_rounded, color: primaryColor, size: 20),
              const SizedBox(width: 6),
              Text(
                'Lv. $level  $_stageName',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: Color(0xFF333D4B),
                ),
              ),
            ],
          ),
          if (!isMaxStage) ...[
            const SizedBox(height: 6),
            SizedBox(
              width: 130,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: exp / 100.0,
                      minHeight: 6,
                      backgroundColor: const Color(0xFFEEF0F3),
                      valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '$exp / 100 EXP  →  Lv$_levelForNextStage $_nextStageName',
                    style: const TextStyle(fontSize: 9, color: Color(0xFF8B95A1)),
                  ),
                ],
              ),
            ),
          ],
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
          )
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
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, 2))],
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
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 20, offset: Offset(0, 8))],
      ),
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

// ─── 알(유아기) 캐릭터 위젯 ───────────────────────────────────────────────────

class _EggCharacterWidget extends StatefulWidget {
  final int level;
  final bool isHappyAction;
  final bool isEatingAction;
  final Function(DragUpdateDetails) onRubUpdate;

  const _EggCharacterWidget({
    required this.level,
    required this.isHappyAction,
    required this.isEatingAction,
    required this.onRubUpdate,
  });

  @override
  State<_EggCharacterWidget> createState() => _EggCharacterWidgetState();
}

class _EggCharacterWidgetState extends State<_EggCharacterWidget>
    with TickerProviderStateMixin {
  late AnimationController _wobbleCtrl;
  late AnimationController _pulseCtrl;
  late Animation<double> _wobble;
  late Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    // Lv4이면 빠르게 흔들림 (부화 직전)
    final wobbleMs = widget.level >= 4 ? 120 : 500;
    _wobbleCtrl = AnimationController(
      duration: Duration(milliseconds: wobbleMs),
      vsync: this,
    )..repeat(reverse: true);
    _wobble = Tween<double>(begin: -0.07, end: 0.07).animate(
      CurvedAnimation(parent: _wobbleCtrl, curve: Curves.easeInOut),
    );

    _pulseCtrl = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat(reverse: true);
    _pulse = Tween<double>(begin: 1.0, end: 1.06).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void didUpdateWidget(covariant _EggCharacterWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 레벨 변경 시 흔들림 속도 업데이트
    if (oldWidget.level != widget.level) {
      final wobbleMs = widget.level >= 4 ? 120 : 500;
      _wobbleCtrl.duration = Duration(milliseconds: wobbleMs);
      _wobbleCtrl.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _wobbleCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanUpdate: widget.onRubUpdate,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 600,
        height: 600,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 그림자
            Positioned(
              bottom: 165,
              child: Container(
                width: 120,
                height: 28,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.2),
                  borderRadius: const BorderRadius.all(Radius.elliptical(120, 28)),
                ),
              ),
            ),
            // 알 본체
            AnimatedBuilder(
              animation: Listenable.merge([_wobble, _pulse]),
              builder: (context, child) {
                return Transform.rotate(
                  angle: _wobble.value,
                  child: Transform.scale(
                    scale: _pulse.value,
                    child: child,
                  ),
                );
              },
              child: _buildEggBody(),
            ),
            // 행복 이펙트
            if (widget.isHappyAction)
              Positioned(
                top: 100,
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
            // 먹기 이펙트
            if (widget.isEatingAction)
              Positioned(
                top: 100,
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
          ],
        ),
      ),
    );
  }

  Widget _buildEggBody() {
    final int crackCount = (widget.level - 1).clamp(0, 3);

    return Container(
      width: 150,
      height: 195,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFFDE7), Color(0xFFFFECB3)],
        ),
        borderRadius: BorderRadius.only(
          topLeft: Radius.elliptical(75, 105),
          topRight: Radius.elliptical(75, 105),
          bottomLeft: Radius.elliptical(75, 90),
          bottomRight: Radius.elliptical(75, 90),
        ),
        boxShadow: [
          BoxShadow(color: Colors.black26, blurRadius: 12, offset: Offset(0, 6)),
        ],
      ),
      child: Stack(
        children: [
          // 광택
          Positioned(
            top: 22,
            left: 28,
            child: Container(
              width: 32,
              height: 52,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
          // 금 (레벨별 균열선)
          if (crackCount > 0)
            Positioned.fill(
              child: CustomPaint(
                painter: _EggCrackPainter(crackCount: crackCount),
              ),
            ),
          // 얼굴
          Center(
            child: Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [_buildEye(), const SizedBox(width: 22), _buildEye()],
                  ),
                  const SizedBox(height: 10),
                  // 입
                  Container(
                    width: 22,
                    height: 9,
                    decoration: BoxDecoration(
                      border: const Border(
                        bottom: BorderSide(color: Color(0xFF5D4037), width: 2.5),
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEye() {
    return Container(
      width: 14,
      height: 14,
      decoration: const BoxDecoration(
        color: Color(0xFF3E2723),
        shape: BoxShape.circle,
      ),
      child: Align(
        alignment: const Alignment(0.3, -0.3),
        child: Container(
          width: 4,
          height: 4,
          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

class _EggCrackPainter extends CustomPainter {
  final int crackCount;
  _EggCrackPainter({required this.crackCount});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFBCAAA4)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    if (crackCount >= 1) {
      final path = Path()
        ..moveTo(size.width * 0.62, size.height * 0.18)
        ..lineTo(size.width * 0.52, size.height * 0.38)
        ..lineTo(size.width * 0.65, size.height * 0.52)
        ..lineTo(size.width * 0.58, size.height * 0.68);
      canvas.drawPath(path, paint);
    }
    if (crackCount >= 2) {
      final path2 = Path()
        ..moveTo(size.width * 0.22, size.height * 0.30)
        ..lineTo(size.width * 0.38, size.height * 0.48)
        ..lineTo(size.width * 0.28, size.height * 0.60);
      canvas.drawPath(path2, paint);
    }
    if (crackCount >= 3) {
      final path3 = Path()
        ..moveTo(size.width * 0.45, size.height * 0.55)
        ..lineTo(size.width * 0.30, size.height * 0.72)
        ..lineTo(size.width * 0.42, size.height * 0.85);
      canvas.drawPath(path3, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _EggCrackPainter old) => old.crackCount != crackCount;
}

// ─── 진화 연출 오버레이 ──────────────────────────────────────────────────────

class _EvolutionOverlay extends StatefulWidget {
  final String stageName;
  const _EvolutionOverlay({required this.stageName});

  @override
  State<_EvolutionOverlay> createState() => _EvolutionOverlayState();
}

class _EvolutionOverlayState extends State<_EvolutionOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _bgOpacity;
  late Animation<double> _textScale;
  late Animation<double> _textOpacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 3500),
      vsync: this,
    )..forward();

    _bgOpacity = TweenSequence([
      TweenSequenceItem(tween: Tween<double>(begin: 0.0, end: 0.9), weight: 15),
      TweenSequenceItem(tween: Tween<double>(begin: 0.9, end: 0.6), weight: 25),
      TweenSequenceItem(tween: Tween<double>(begin: 0.6, end: 0.9), weight: 15),
      TweenSequenceItem(tween: Tween<double>(begin: 0.9, end: 0.0), weight: 45),
    ]).animate(_ctrl);

    _textScale = TweenSequence([
      TweenSequenceItem(tween: Tween<double>(begin: 0.4, end: 1.2), weight: 25),
      TweenSequenceItem(tween: Tween<double>(begin: 1.2, end: 1.0), weight: 15),
      TweenSequenceItem(tween: ConstantTween<double>(1.0), weight: 60),
    ]).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));

    _textOpacity = TweenSequence([
      TweenSequenceItem(tween: Tween<double>(begin: 0.0, end: 1.0), weight: 20),
      TweenSequenceItem(tween: ConstantTween<double>(1.0), weight: 55),
      TweenSequenceItem(tween: Tween<double>(begin: 1.0, end: 0.0), weight: 25),
    ]).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        return Container(
          color: Colors.white.withValues(alpha: _bgOpacity.value),
          child: Center(
            child: Opacity(
              opacity: _textOpacity.value,
              child: Transform.scale(
                scale: _textScale.value,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '✨ 진화! ✨',
                      style: TextStyle(
                        fontSize: 52,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFFFF6F00),
                        shadows: [
                          Shadow(color: Colors.orange, blurRadius: 20),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF6F00),
                        borderRadius: BorderRadius.circular(32),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.orange,
                            blurRadius: 20,
                            spreadRadius: 2,
                          )
                        ],
                      ),
                      child: Text(
                        widget.stageName,
                        style: const TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─── 낙하 사과 ────────────────────────────────────────────────────────────────

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
  const _FallingAppleWidget({
    super.key,
    required this.apple,
    required this.onTapped,
    required this.onFinished,
  });

  @override
  State<_FallingAppleWidget> createState() => _FallingAppleWidgetState();
}

class _FallingAppleWidgetState extends State<_FallingAppleWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: const Duration(seconds: 3), vsync: this);
    _animation = Tween<double>(begin: -50, end: 600).animate(_controller)
      ..addStatusListener((status) {
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
            child: const Text("🍎", style: TextStyle(fontSize: 40)),
          ),
        );
      },
    );
  }
}

// ─── 탭 피드백 ────────────────────────────────────────────────────────────────

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

class _TapFeedbackWidgetState extends State<_TapFeedbackWidget>
    with SingleTickerProviderStateMixin {
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
            child: const Text(
              "+5",
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.green),
            ),
          ),
        );
      },
    );
  }
}
