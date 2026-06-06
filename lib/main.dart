import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:camera/camera.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
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
  bool _isSleeping = false;
  Timer? _sleepTimer;

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

  final SpeechToText _speech = SpeechToText();
  bool _speechEnabled = false;
  bool _isListening = false;
  String _voiceStatus = '';

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

  final WebSocketChannel channel = WebSocketChannel.connect(
    Uri.parse('ws://192.168.200.193:8000/ws/gesture'),
  );

  @override
  void initState() {
    super.initState();
    _loadInitialData();
    _startMainWandering();
    _initSpeech();

    channel.stream.listen(
      (data) {
        debugPrint("서버 데이터 수신: $data");
        final decoded = jsonDecode(data);
        if (mounted) {
          setState(() {
            if (decoded['current_fullness'] != null) fullness = decoded['current_fullness'];
            if (decoded['gold'] != null) gold = decoded['gold'];
            if (decoded['diamonds'] != null) diamonds = decoded['diamonds'];
            // level은 로컬 EXP 시스템이 관리 — 서버 값으로 덮어쓰지 않음
            if (decoded['mood'] != null) mood = decoded['mood'];
            if (decoded['hygiene'] != null) hygiene = decoded['hygiene'];
            if (!_isSleeping && decoded['energy'] != null) energy = decoded['energy'];
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
      int loadedMood     = data['mood']     ?? mood;
      int loadedFullness = data['fullness'] ?? fullness;
      int loadedHygiene  = data['hygiene']  ?? hygiene;
      int loadedEnergy   = data['energy']   ?? energy;

      // 오프라인 경과 시간만큼 스탯 자연 감소 (최대 120분 적용)
      final lastStr = data['last_updated']?.toString();
      if (lastStr != null) {
        final lastUpdated = DateTime.tryParse(lastStr);
        if (lastUpdated != null) {
          final mins = DateTime.now().difference(lastUpdated).inMinutes.clamp(0, 120);
          loadedFullness = (loadedFullness - mins * 2).clamp(0, 100);
          loadedEnergy   = (loadedEnergy   - mins).clamp(0, 100);
          loadedMood     = (loadedMood     - mins ~/ 2).clamp(0, 100);
          loadedHygiene  = (loadedHygiene  - mins ~/ 3).clamp(0, 100);
        }
      }

      setState(() {
        level    = data['level']    ?? level;
        exp      = data['exp']      ?? exp;
        gold     = data['gold']     ?? gold;
        diamonds = data['diamonds'] ?? diamonds;
        mood     = loadedMood;
        fullness = loadedFullness;
        hygiene  = loadedHygiene;
        energy   = loadedEnergy;
      });
      _saveProgress();
    }
  }

  void _gainExp(int amount) {
    final stageBefore = _evolutionStage;
    final levelBefore = level;

    setState(() {
      exp += amount;
      while (exp >= 100) {
        exp -= 100;
        level++;
      }
    });

    _saveProgress();

    if (level != levelBefore) {
      channel.sink.add(jsonEncode({'action': 'UPDATE_STATE', 'level': level}));
    }

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

  void _openShop() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ShopModal(gold: gold, onBuy: _buyItem),
    );
  }

  void _buyItem(Map<String, dynamic> item) {
    setState(() {
      gold -= item['price'] as int;
      if (item['fullness'] != null) fullness = (fullness + (item['fullness'] as int)).clamp(0, 100);
      if (item['mood']     != null) mood     = (mood     + (item['mood']     as int)).clamp(0, 100);
      if (item['hygiene']  != null) hygiene  = (hygiene  + (item['hygiene']  as int)).clamp(0, 100);
      if (item['energy']   != null) energy   = (energy   + (item['energy']   as int)).clamp(0, 100);
    });
    channel.sink.add(jsonEncode({
      'action': 'UPDATE_STATE',
      'gold': gold,
      'mood': mood,
      'fullness': fullness,
      'hygiene': hygiene,
      'energy': energy,
    }));
    _saveProgress();
  }

  void _toggleSleep() {
    if (_isSleeping) {
      _wakeUp();
    } else {
      setState(() => _isSleeping = true);
      _sleepTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
        if (!mounted || !_isSleeping) { timer.cancel(); return; }
        setState(() => energy = (energy + 5).clamp(0, 100));
        if (energy >= 100) { timer.cancel(); _wakeUp(); }
      });
    }
  }

  void _wakeUp() {
    _sleepTimer?.cancel();
    if (!mounted) return;
    setState(() => _isSleeping = false);
    channel.sink.add(jsonEncode({'action': 'UPDATE_STATE', 'energy': energy}));
    _saveProgress();
  }

  Future<void> _triggerEvolution() async {
    setState(() => _isEvolving = true);
    await Future.delayed(const Duration(milliseconds: 3500));
    if (mounted) setState(() => _isEvolving = false);
  }

  void _spawnApple() {
    // FEED는 사과를 잡았을 때만 전송 — 버튼 누를 때는 사과 생성만
    setState(() {
      _apples.add(_FallingApple(
        id: DateTime.now().millisecondsSinceEpoch,
        x: _random.nextDouble() * 200 + 25,
        y: -50,
      ));
    });
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
    });
    // 사과 잡을 때 FEED 전송 — 서버가 fullness/mood/gold 계산 후 브로드캐스트
    channel.sink.add(jsonEncode({"action": "FEED"}));
    _gainExp(10);
  }

  void _startMainWandering() {
    _mainWanderTimer = Timer.periodic(const Duration(seconds: 12), (timer) async {
      if (!mounted || _isHappyAction || _evolutionStage == 0) return;

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

  Future<void> _initSpeech() async {
    _speechEnabled = await _speech.initialize(
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          if (mounted) setState(() => _isListening = false);
        }
      },
      onError: (error) {
        if (mounted) setState(() => _isListening = false);
      },
    );
  }

  Future<void> _toggleListening() async {
    if (!_speechEnabled) return;
    if (_isListening) {
      await _speech.stop();
      setState(() => _isListening = false);
      return;
    }
    setState(() {
      _isListening = true;
      _voiceStatus = '듣고 있어요...';
    });
    await _speech.listen(
      onResult: _onVoiceResult,
      listenOptions: SpeechListenOptions(
        localeId: 'ko_KR',
        listenFor: const Duration(seconds: 6),
        pauseFor: const Duration(seconds: 2),
      ),
    );
  }

  void _onVoiceResult(SpeechRecognitionResult result) {
    setState(() => _voiceStatus = result.recognizedWords);
    if (result.finalResult) {
      _handleVoiceCommand(result.recognizedWords);
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) setState(() => _voiceStatus = '');
      });
    }
  }

  void _handleVoiceCommand(String text) {
    final t = text;
    if (t.contains('밥') || t.contains('먹') || t.contains('배고')) {
      _spawnApple();
    } else if (t.contains('놀') || t.contains('칭찬') || t.contains('잘했')) {
      if (!_isHappyAction) _performHappyAction();
    } else if (t.contains('자') || t.contains('졸려') || t.contains('잠')) {
      if (!_isSleeping) _toggleSleep();
    } else if (t.contains('일어') || t.contains('깨')) {
      if (_isSleeping) _toggleSleep();
    }
  }

  @override
  void dispose() {
    _mainWanderTimer?.cancel();
    _eatingActionTimer?.cancel();
    _sleepTimer?.cancel();
    _speech.stop();
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
                        clipBehavior: Clip.none,
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
              if (_isSleeping)
                Positioned.fill(
                  child: _SleepOverlay(energy: energy, onWake: _wakeUp),
                ),
              if (_isListening || _voiceStatus.isNotEmpty)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: _VoiceStatusBanner(
                    isListening: _isListening,
                    statusText: _voiceStatus,
                  ),
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
    final bool isMaxStage = _evolutionStage >= 2;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 왼쪽: 레벨 카드 + 상점
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.93),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 10, offset: const Offset(0, 2))],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.stars_rounded, color: primaryColor, size: 16),
                    const SizedBox(width: 5),
                    Text('Lv.$level', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: Color(0xFF333D4B))),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(_stageName, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: primaryColor)),
                    ),
                    if (!isMaxStage) ...[
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 64,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: exp / 100.0,
                            minHeight: 5,
                            backgroundColor: const Color(0xFFEEF0F3),
                            valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                          ),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text('$exp', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF8B95A1))),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 10),
              _buildTopIconBtn(Icons.storefront_rounded, _openShop),
            ],
          ),
          // 오른쪽: 골드 카드 + AR · 음성
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.93),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 10, offset: const Offset(0, 2))],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.monetization_on_rounded, color: Color(0xFFF6A000), size: 16),
                    const SizedBox(width: 4),
                    Text('$gold', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: Color(0xFF333D4B))),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _buildTopIconBtn(Icons.camera_alt_rounded, () {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const ARCameraScreen()));
                  }),
                  const SizedBox(width: 8),
                  _buildTopIconBtn(
                    _isListening ? Icons.mic_rounded : Icons.mic_none_rounded,
                    _toggleListening,
                    active: _isListening,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTopIconBtn(IconData icon, VoidCallback onTap, {bool active = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: active ? primaryColor.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.93),
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8, offset: const Offset(0, 2))],
        ),
        child: Icon(icon, color: active ? primaryColor : const Color(0xFF4E5968), size: 20),
      ),
    );
  }

  Widget _buildBottomMenu() {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 24, offset: Offset(0, -4))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 14),
            width: 36,
            height: 3,
            decoration: BoxDecoration(color: const Color(0xFFDDE1E7), borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(child: _buildStatRow(Icons.favorite_rounded, '기분', mood, const Color(0xFFFF8A80))),
                    const SizedBox(width: 14),
                    Expanded(child: _buildStatRow(Icons.restaurant_rounded, '식사', fullness, const Color(0xFF69D2A0))),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: _buildStatRow(Icons.water_drop_rounded, '위생', hygiene, const Color(0xFF87CEEB))),
                    const SizedBox(width: 14),
                    Expanded(child: _buildStatRow(Icons.bolt_rounded, '에너지', energy, const Color(0xFFFFB74D))),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          const Divider(height: 1, color: Color(0xFFF0F2F5)),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
            child: Row(
              children: [
                Expanded(child: _buildActionBtn(Icons.restaurant_rounded, '밥주기', _spawnApple)),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildActionBtn(
                    _isSleeping ? Icons.wb_sunny_rounded : Icons.dark_mode_rounded,
                    _isSleeping ? '기상' : '취침',
                    _toggleSleep,
                    active: _isSleeping,
                    activeColor: const Color(0xFF7986CB),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildActionBtn(
                    isOutdoor ? Icons.home_rounded : Icons.directions_walk_rounded,
                    isOutdoor ? '실내' : '실외',
                    () => setState(() => isOutdoor = !isOutdoor),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatRow(IconData icon, String label, int value, Color color) {
    final double pct = (value / 100.0).clamp(0.0, 1.0);
    final Color barColor = pct > 0.5 ? color : pct > 0.25 ? const Color(0xFFFFB74D) : const Color(0xFFFF5252);
    return Row(
      children: [
        Icon(icon, color: barColor, size: 15),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF4E5968))),
        const SizedBox(width: 6),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 5,
              backgroundColor: const Color(0xFFF0F2F5),
              valueColor: AlwaysStoppedAnimation<Color>(barColor),
            ),
          ),
        ),
        const SizedBox(width: 5),
        SizedBox(
          width: 22,
          child: Text('$value', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF8B95A1)), textAlign: TextAlign.right),
        ),
      ],
    );
  }

  Widget _buildActionBtn(
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool active = false,
    Color activeColor = const Color(0xFF87CEEB),
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: active ? activeColor.withValues(alpha: 0.12) : const Color(0xFFF5F7FA),
          borderRadius: BorderRadius.circular(18),
          border: active ? Border.all(color: activeColor.withValues(alpha: 0.35), width: 1.5) : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: active ? activeColor : const Color(0xFF4E5968), size: 26),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: active ? activeColor : const Color(0xFF4E5968),
              ),
            ),
          ],
        ),
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
    with SingleTickerProviderStateMixin {
  AnimationController? _wobbleCtrl;
  Animation<double>? _wobble;

  @override
  void initState() {
    super.initState();
    if (widget.level >= 3) _startWobble();
  }

  @override
  void didUpdateWidget(covariant _EggCharacterWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.level >= 3 && _wobbleCtrl == null) {
      _startWobble();
    } else if (_wobbleCtrl != null && widget.level != oldWidget.level) {
      _wobbleCtrl!.duration = Duration(milliseconds: widget.level >= 4 ? 150 : 400);
      _wobbleCtrl!.repeat(reverse: true);
    }
  }

  void _startWobble() {
    _wobbleCtrl = AnimationController(
      duration: Duration(milliseconds: widget.level >= 4 ? 150 : 400),
      vsync: this,
    )..repeat(reverse: true);
    _wobble = Tween<double>(begin: -0.06, end: 0.06).animate(
      CurvedAnimation(parent: _wobbleCtrl!, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _wobbleCtrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final int crackCount = (widget.level - 1).clamp(0, 3);

    Widget eggBody = Container(
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
          if (crackCount > 0)
            Positioned.fill(
              child: CustomPaint(
                painter: _EggCrackPainter(crackCount: crackCount),
              ),
            ),
        ],
      ),
    );

    if (_wobbleCtrl != null && _wobble != null) {
      eggBody = AnimatedBuilder(
        animation: _wobbleCtrl!,
        builder: (context, child) => Transform.rotate(
          angle: _wobble!.value,
          child: child,
        ),
        child: eggBody,
      );
    }

    return GestureDetector(
      onPanUpdate: widget.onRubUpdate,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 600,
        height: 600,
        child: Stack(
          children: [
            // 그림자
            Positioned(
              bottom: 140,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  width: 130,
                  height: 30,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.22),
                    borderRadius: const BorderRadius.all(Radius.elliptical(130, 30)),
                  ),
                ),
              ),
            ),
            // 알 본체
            Positioned(
              bottom: 158,
              left: 0,
              right: 0,
              child: Center(child: eggBody),
            ),
            // 행복 이펙트
            if (widget.isHappyAction)
              Positioned(
                top: 100,
                left: 0,
                right: 0,
                child: Center(
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
              ),
            // 먹기 이펙트
            if (widget.isEatingAction)
              Positioned(
                top: 100,
                left: 0,
                right: 0,
                child: Center(
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
              ),
          ],
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

// ─── 수면 오버레이 ────────────────────────────────────────────────────────────

class _SleepOverlay extends StatefulWidget {
  final int energy;
  final VoidCallback onWake;
  const _SleepOverlay({required this.energy, required this.onWake});

  @override
  State<_SleepOverlay> createState() => _SleepOverlayState();
}

class _SleepOverlayState extends State<_SleepOverlay> with TickerProviderStateMixin {
  late AnimationController _zzzCtrl;
  late Animation<double> _zzzY;
  late Animation<double> _zzzOpacity;
  late AnimationController _fadeCtrl;

  @override
  void initState() {
    super.initState();

    _fadeCtrl = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    )..forward();

    _zzzCtrl = AnimationController(
      duration: const Duration(milliseconds: 2200),
      vsync: this,
    )..repeat();

    _zzzY = Tween<double>(begin: 0, end: -70).animate(
      CurvedAnimation(parent: _zzzCtrl, curve: Curves.easeOut),
    );
    _zzzOpacity = TweenSequence([
      TweenSequenceItem(tween: Tween<double>(begin: 0.0, end: 1.0), weight: 25),
      TweenSequenceItem(tween: ConstantTween<double>(1.0), weight: 45),
      TweenSequenceItem(tween: Tween<double>(begin: 1.0, end: 0.0), weight: 30),
    ]).animate(_zzzCtrl);
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    _zzzCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeCtrl,
      child: GestureDetector(
        onTap: widget.onWake,
        child: Container(
          color: const Color(0xEE060B1A),
          child: SafeArea(
            child: Stack(
              children: [
                // 별 장식
                const Positioned(top: 60,  left: 40,  child: Text('✦', style: TextStyle(color: Colors.white24, fontSize: 14))),
                const Positioned(top: 100, right: 60, child: Text('✦', style: TextStyle(color: Colors.white30, fontSize: 10))),
                const Positioned(top: 40,  right: 100,child: Text('✦', style: TextStyle(color: Colors.white24, fontSize: 18))),
                const Positioned(top: 160, left: 80,  child: Text('✦', style: TextStyle(color: Colors.white12, fontSize: 12))),
                // 중앙 콘텐츠
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('🌙', style: TextStyle(fontSize: 64)),
                      const SizedBox(height: 20),
                      // 떠오르는 zzz
                      AnimatedBuilder(
                        animation: _zzzCtrl,
                        builder: (context, child) {
                          return Transform.translate(
                            offset: Offset(0, _zzzY.value),
                            child: Opacity(
                              opacity: _zzzOpacity.value,
                              child: const Text(
                                'z  z  z',
                                style: TextStyle(
                                  fontSize: 26,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF87CEEB),
                                  letterSpacing: 6,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 48),
                      // 에너지 회복 표시
                      Container(
                        width: 220,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  '에너지 충전 중',
                                  style: TextStyle(color: Colors.white60, fontSize: 13),
                                ),
                                Text(
                                  '${widget.energy}%',
                                  style: const TextStyle(
                                    color: Color(0xFF87CEEB),
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: widget.energy / 100.0,
                                minHeight: 8,
                                backgroundColor: Colors.white12,
                                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF87CEEB)),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 36),
                      const Text(
                        '화면을 터치하면 깨어납니다',
                        style: TextStyle(color: Colors.white24, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── 상점 모달 ────────────────────────────────────────────────────────────────

class _ShopModal extends StatefulWidget {
  final int gold;
  final Function(Map<String, dynamic>) onBuy;
  const _ShopModal({required this.gold, required this.onBuy});

  @override
  State<_ShopModal> createState() => _ShopModalState();
}

class _ShopModalState extends State<_ShopModal> {
  late int _gold;

  static const List<Map<String, dynamic>> _items = [
    {'name': '케이크',       'emoji': '🎂', 'price': 5,  'fullness': 30, 'mood': 10, 'desc': '포만감·기분 회복'},
    {'name': '영양제',       'emoji': '💊', 'price': 8,  'fullness': 20, 'energy': 20,'desc': '포만감·에너지'},
    {'name': '목욕',         'emoji': '🛁', 'price': 6,  'hygiene': 50,              'desc': '위생 +50'},
    {'name': '향수',         'emoji': '🌸', 'price': 10, 'hygiene': 100,             'desc': '위생 완전 회복'},
    {'name': '공놀이',       'emoji': '⚽', 'price': 4,  'mood': 20,                 'desc': '기분 +20'},
    {'name': '에너지 드링크', 'emoji': '⚡', 'price': 12, 'energy': 60,              'desc': '에너지 +60'},
  ];

  @override
  void initState() {
    super.initState();
    _gold = widget.gold;
  }

  void _handleBuy(Map<String, dynamic> item) {
    final int price = item['price'] as int;
    if (_gold < price) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('골드가 부족해요!'), duration: Duration(seconds: 1)),
      );
      return;
    }
    setState(() => _gold -= price);
    widget.onBuy(item);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.62,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '상점',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Color(0xFF333D4B)),
                ),
                Row(
                  children: [
                    const Icon(Icons.monetization_on_rounded, color: Color(0xFFF6A000), size: 20),
                    const SizedBox(width: 4),
                    Text(
                      '$_gold',
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: Color(0xFF333D4B)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                childAspectRatio: 0.82,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: _items.length,
              itemBuilder: (context, i) {
                final item = _items[i];
                final bool canAfford = _gold >= (item['price'] as int);
                return GestureDetector(
                  onTap: () => _handleBuy(item),
                  child: Container(
                    decoration: BoxDecoration(
                      color: canAfford ? const Color(0xFFF9FAFB) : const Color(0xFFF2F4F6),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: canAfford ? const Color(0xFFE0E0E0) : const Color(0xFFEEEEEE),
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(item['emoji'] as String, style: const TextStyle(fontSize: 30)),
                        const SizedBox(height: 4),
                        Text(
                          item['name'] as String,
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF333D4B)),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          item['desc'] as String,
                          style: const TextStyle(fontSize: 9, color: Color(0xFF8B95A1)),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: canAfford ? const Color(0xFFF6A000) : Colors.grey[400],
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.monetization_on_rounded, color: Colors.white, size: 11),
                              const SizedBox(width: 2),
                              Text(
                                '${item['price']}',
                                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
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

// ─── 음성 인식 상태 배너 ──────────────────────────────────────────────────────

class _VoiceStatusBanner extends StatelessWidget {
  final bool isListening;
  final String statusText;
  const _VoiceStatusBanner({required this.isListening, required this.statusText});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: isListening
            ? const Color(0xFF87CEEB).withValues(alpha: 0.95)
            : Colors.white.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, 2))],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isListening ? Icons.mic_rounded : Icons.check_circle_rounded,
            color: isListening ? Colors.white : const Color(0xFF87CEEB),
            size: 18,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              statusText.isEmpty ? '듣고 있어요...' : statusText,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isListening ? Colors.white : const Color(0xFF333D4B),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
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
