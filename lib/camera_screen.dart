import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_2/datatypes/node_types.dart';
import 'package:ar_flutter_plugin_2/datatypes/hittest_result_types.dart';
import 'package:ar_flutter_plugin_2/models/ar_anchor.dart';
import 'package:ar_flutter_plugin_2/models/ar_node.dart';
import 'package:ar_flutter_plugin_2/models/ar_hittest_result.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/widgets/ar_view.dart';
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' as vector;
import 'package:camera/camera.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'main.dart';

// 서버 주소 — ngrok 사용 시 아래 URL을 교체하세요
// 실기기 테스트: ws://<컴퓨터 IP>:8000/ws/gesture
// 에뮬레이터:   ws://10.0.2.2:8000/ws/gesture
const _kWsUrl = 'ws://192.168.200.193:8000/ws/gesture';

class ARCameraScreen extends StatefulWidget {
  const ARCameraScreen({super.key});
  @override
  State<ARCameraScreen> createState() => _ARCameraScreenState();
}

class _ARCameraScreenState extends State<ARCameraScreen> {
  ARSessionManager? arSessionManager;
  ARObjectManager? arObjectManager;
  ARAnchorManager? arAnchorManager;

  ARNode? _characterNode;
  ARPlaneAnchor? _currentAnchor;
  bool _isCharacterPlaced = false;
  bool _isPlacing = false;
  String _statusMessage = "바닥을 향해 카메라를 천천히 움직여 평면을 인식시키세요.";

  Timer? _wanderTimer;
  Timer? _captureTimer;
  bool _isActionExecuting = false;

  CameraController? _frontCameraController;
  WebSocketChannel? _wsChannel;
  String? _expressionEmoji; // 표정 인식 결과 표시용

  // 제스처별 모델 경로 & 상태 메시지
  static const _gestureModels = {
    'wave':     'assets/models/TAMA1_Big_Wave_Hello.glb',
    'happy':    'assets/models/TAMA1_Skip_Forward.glb',
    'fighting': 'assets/models/TAMA1_Skip_Forward.glb',
    'love':     'assets/models/TAMA1_Wave_One_Hand.glb',
  };
  static const _gestureMessages = {
    'wave':     '안녕! 다마고치가 인사합니다.',
    'happy':    '브이! 다마고치가 신났어요!',
    'fighting': '파이팅! 에너지가 올라갑니다!',
    'love':     '❤️ 다마고치가 좋아합니다!',
  };
  static const _expressionEmojis = {
    'happy': '😊', 'sad': '😢', 'angry': '😠',
    'surprise': '😲', 'fear': '😨', 'disgust': '🤢', 'neutral': '😐',
  };

  static final _fixedScale = vector.Vector3(0.002, 0.002, 0.002);

  @override
  void initState() {
    super.initState();
    _connectWebSocket();
    _initFrontCamera();
  }

  @override
  void dispose() {
    _wanderTimer?.cancel();
    _captureTimer?.cancel();
    _frontCameraController?.dispose();
    _wsChannel?.sink.close();
    arSessionManager?.dispose();
    super.dispose();
  }

  // ── WebSocket ───────────────────────────────────────────────────────────────

  void _connectWebSocket() {
    try {
      _wsChannel = WebSocketChannel.connect(Uri.parse(_kWsUrl));
      _wsChannel!.stream.listen(
        (data) {
          final decoded = jsonDecode(data as String) as Map<String, dynamic>;
          final gestureAction = decoded['gesture_action'] as String?;
          final expression    = decoded['expression']     as String?;

          if (gestureAction != null) _handleGestureAction(gestureAction);

          if (expression != null && mounted) {
            setState(() => _expressionEmoji = _expressionEmojis[expression]);
            Future.delayed(const Duration(seconds: 3), () {
              if (mounted) setState(() => _expressionEmoji = null);
            });
          }
        },
        onError: (e) => debugPrint("WS error: $e"),
      );
    } catch (e) {
      debugPrint("WS connect failed: $e");
    }
  }

  void _handleGestureAction(String action) {
    final model   = _gestureModels[action];
    final message = _gestureMessages[action];
    if (model != null && message != null) {
      _performGestureAction(model, message);
    }
  }

  // ── 전면 카메라 ─────────────────────────────────────────────────────────────

  Future<void> _initFrontCamera() async {
    if (cameras.isEmpty) return;
    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    _frontCameraController = CameraController(front, ResolutionPreset.low, enableAudio: false);
    try {
      await _frontCameraController!.initialize();
      if (!mounted) return;
      // 0.8초마다 사진 캡처 → 서버 전송
      _captureTimer = Timer.periodic(
        const Duration(milliseconds: 800),
        (_) => _captureAndSend(),
      );
    } catch (e) {
      debugPrint("Front camera error: $e");
    }
  }

  Future<void> _captureAndSend() async {
    if (!_isCharacterPlaced) return;
    if (_wsChannel == null) return;
    if (_frontCameraController == null || !_frontCameraController!.value.isInitialized) return;
    try {
      final file  = await _frontCameraController!.takePicture();
      final bytes = await file.readAsBytes();
      _wsChannel!.sink.add(jsonEncode({
        'action': 'FRAME',
        'frame': base64Encode(bytes),
      }));
    } catch (_) {
      // AR 세션과 카메라 충돌 등 일시적 오류는 무시
    }
  }

  // ── AR 캐릭터 제어 ──────────────────────────────────────────────────────────

  Future<void> _updateCharacterModel(
    String modelPath, {
    required vector.Vector3 position,
    required double yaw,
  }) async {
    if (_characterNode != null && _characterNode!.uri == modelPath) {
      _characterNode!.position    = position;
      _characterNode!.eulerAngles = vector.Vector3(0, yaw, 0);
      return;
    }
    if (_characterNode != null) {
      await arObjectManager?.removeNode(_characterNode!);
    }
    _characterNode = ARNode(
      type: NodeType.localGLTF2,
      uri: modelPath,
      scale: _fixedScale,
      position: position,
    );
    _characterNode!.eulerAngles = vector.Vector3(0, yaw, 0);
    await arObjectManager?.addNode(_characterNode!, planeAnchor: _currentAnchor);
  }

  Future<void> _performGestureAction(String modelPath, String message) async {
    if (_isActionExecuting || _characterNode == null) return;
    _isActionExecuting = true;
    _wanderTimer?.cancel();
    if (mounted) setState(() => _statusMessage = message);

    final pos = _characterNode!.position;
    final yaw = _characterNode!.eulerAngles.y;

    await _updateCharacterModel(modelPath, position: pos, yaw: yaw);
    await Future.delayed(const Duration(seconds: 4));

    if (mounted) {
      await _updateCharacterModel(
        'assets/models/TAMA1_Casual_Walk.glb', position: pos, yaw: yaw,
      );
      setState(() => _statusMessage = '다마고치와 함께 놀아요!');
      _isActionExecuting = false;
      _startWandering();
    }
  }

  // ── AR 세션 ─────────────────────────────────────────────────────────────────

  void onARViewCreated(
    ARSessionManager arSessionManager,
    ARObjectManager arObjectManager,
    ARAnchorManager arAnchorManager,
    ARLocationManager arLocationManager,
  ) {
    this.arSessionManager = arSessionManager;
    this.arObjectManager  = arObjectManager;
    this.arAnchorManager  = arAnchorManager;

    this.arSessionManager!.onInitialize(
      showFeaturePoints: true,
      showPlanes: true,
      showWorldOrigin: false,
      handleTaps: true,
    );
    this.arObjectManager!.onInitialize();

    this.arSessionManager!.onPlaneOrPointTap = (List<ARHitTestResult> hits) {
      if (_isCharacterPlaced || _isPlacing) return;
      final planeHits = hits.where((h) => h.type == ARHitTestResultType.plane).toList();
      if (planeHits.isEmpty) {
        if (mounted) setState(() => _statusMessage = "평면이 인식되지 않았습니다. 바닥을 향해 천천히 원을 그리듯 움직여주세요.");
        return;
      }
      if (mounted) setState(() => _statusMessage = "다마고치 소환 중...");
      _addAnchorAndNode(planeHits.first);
    };

    this.arSessionManager!.onPlaneDetected = (int planeCount) {
      if (!_isCharacterPlaced && mounted) {
        setState(() {
          _statusMessage = planeCount > 0
              ? "평면 인식 완료! ($planeCount개 구역) 원하는 곳을 터치하세요."
              : "바닥 스캔 중... 휴대폰을 좌우로 천천히 움직이세요.";
        });
      }
    };
  }

  Future<void> _addAnchorAndNode(ARHitTestResult hitResult) async {
    if (_isCharacterPlaced || _isPlacing) return;
    _isPlacing = true;

    _currentAnchor = ARPlaneAnchor(transformation: hitResult.worldTransform);
    final didAddAnchor = await arAnchorManager?.addAnchor(_currentAnchor!);
    if (didAddAnchor != true) {
      _isPlacing = false;
      _currentAnchor = null;
      if (mounted) setState(() => _statusMessage = "앵커 생성 실패. 평면 위 다른 곳을 터치해보세요.");
      return;
    }

    _characterNode = ARNode(
      type: NodeType.localGLTF2,
      uri: 'assets/models/TAMA1_stop.glb',
      scale: _fixedScale,
      position: vector.Vector3(0, 0, 0),
    );
    _characterNode!.eulerAngles = vector.Vector3(0, 0, 0);

    final didAddNode = await arObjectManager?.addNode(_characterNode!, planeAnchor: _currentAnchor);
    if (didAddNode != true) {
      await arAnchorManager?.removeAnchor(_currentAnchor!);
      _characterNode = null;
      _currentAnchor = null;
      _isPlacing = false;
      if (mounted) setState(() => _statusMessage = "캐릭터 소환 실패. 다시 터치해보세요.");
      return;
    }

    _isCharacterPlaced = true;
    _isPlacing = false;
    if (mounted) setState(() => _statusMessage = "소환 완료! 손 제스처로 다마고치와 놀아보세요.");
    _startWandering();
  }

  Future<void> _resetPlacement() async {
    _wanderTimer?.cancel();
    _isActionExecuting = false;
    _isPlacing = false;
    if (_characterNode != null) {
      await arObjectManager?.removeNode(_characterNode!);
      _characterNode = null;
    }
    if (_currentAnchor != null) {
      await arAnchorManager?.removeAnchor(_currentAnchor!);
      _currentAnchor = null;
    }
    if (mounted) {
      setState(() {
        _isCharacterPlaced = false;
        _statusMessage = "바닥을 향해 카메라를 천천히 움직여 평면을 인식시키세요.";
      });
    }
  }

  void _startWandering() {
    if (_isActionExecuting) return;
    _wanderTimer = Timer.periodic(const Duration(seconds: 12), (timer) async {
      if (!mounted || _isActionExecuting || _characterNode == null) return;
      _isActionExecuting = true;

      final startPos = vector.Vector3.copy(_characterNode!.position);
      final rng = math.Random();
      final targetX = (rng.nextDouble() - 0.5) * 0.4;
      final targetZ = (rng.nextDouble() - 0.5) * 0.4;
      final angle   = math.atan2(targetX - startPos.x, targetZ - startPos.z);

      await _updateCharacterModel(
        'assets/models/TAMA1_Casual_Walk.glb', position: startPos, yaw: angle,
      );

      const steps = 60;
      final stepX = (targetX - startPos.x) / steps;
      final stepZ = (targetZ - startPos.z) / steps;
      for (int i = 0; i < steps; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
        if (!mounted || !_isActionExecuting || _characterNode == null) break;
        final pos = _characterNode!.position;
        pos.x += stepX;
        pos.z += stepZ;
        _characterNode!.position = pos;
      }

      if (mounted && _isActionExecuting && _characterNode != null) {
        final finalPos = vector.Vector3.copy(_characterNode!.position);
        await _updateCharacterModel('assets/models/TAMA1_stop.glb', position: finalPos, yaw: angle);
        _isActionExecuting = false;
      }
    });
  }

  // ── UI ──────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          ARView(
            onARViewCreated: onARViewCreated,
            planeDetectionConfig: PlaneDetectionConfig.horizontal,
          ),

          // 상단 바 (뒤로가기 + 상태 메시지 + 재소환 버튼)
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          _statusMessage,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ),
                  if (_isCharacterPlaced)
                    IconButton(
                      icon: const Icon(Icons.refresh_rounded, color: Colors.white),
                      tooltip: "다시 소환",
                      onPressed: _resetPlacement,
                    )
                  else
                    const SizedBox(width: 48),
                ],
              ),
            ),
          ),

          // 표정 인식 결과
          if (_expressionEmoji != null)
            Positioned(
              top: 100,
              right: 20,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(_expressionEmoji!, style: const TextStyle(fontSize: 36)),
              ),
            ),

          // 평면 스캔 안내
          if (!_isCharacterPlaced && !_isPlacing)
            const Positioned(
              bottom: 60,
              left: 0,
              right: 0,
              child: Center(
                child: Column(
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text(
                      "평면(노란 격자)이 나타나면 터치하세요!\n밝은 곳에서 바닥을 향해 카메라를 천천히 움직이면 더 잘 인식됩니다.",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        shadows: [Shadow(blurRadius: 10, color: Colors.black)],
                      ),
                    ),
                  ],
                ),
              ),
            ),

          if (_isPlacing)
            const Positioned(
              bottom: 60, left: 0, right: 0,
              child: Center(child: CircularProgressIndicator(color: Colors.white)),
            ),

          // 소환 후 제스처 가이드
          if (_isCharacterPlaced)
            Positioned(
              bottom: 32,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    "✋ 인사    ✌️ 기쁨    👊 파이팅    🤞 사랑",
                    style: TextStyle(color: Colors.white, fontSize: 14, letterSpacing: 1),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
