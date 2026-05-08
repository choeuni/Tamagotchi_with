import 'dart:async';
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
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:flutter/foundation.dart';
import 'main.dart';

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
  String _statusMessage = "바닥을 찾는 중입니다...";
  
  Timer? _wanderTimer;
  bool _isActionExecuting = false;

  CameraController? _frontCameraController;
  final PoseDetector _poseDetector = PoseDetector(options: PoseDetectorOptions());
  bool _isBusy = false;

  // 크기 조정 (0.002 -> 0.008로 상향)
  static final vector.Vector3 _fixedScale = vector.Vector3(0.008, 0.008, 0.008);

  @override
  void initState() {
    super.initState();
    _initFrontCamera();
  }

  @override
  void dispose() {
    _wanderTimer?.cancel();
    _poseDetector.close();
    _frontCameraController?.dispose();
    arSessionManager?.dispose();
    super.dispose();
  }

  Future<void> _initFrontCamera() async {
    if (cameras.isEmpty) return;
    final frontCamera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _frontCameraController = CameraController(
      frontCamera,
      ResolutionPreset.low,
      enableAudio: false,
    );

    try {
      await _frontCameraController!.initialize();
      if (!mounted) return;
      _frontCameraController!.startImageStream(_processCameraImage);
    } catch (e) {
      debugPrint("Front camera error: $e");
    }
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isBusy || _isActionExecuting || !_isCharacterPlaced) return;
    _isBusy = true;

    final inputImage = _inputImageFromCameraImage(image);
    if (inputImage == null) {
      _isBusy = false;
      return;
    }

    try {
      final poses = await _poseDetector.processImage(inputImage);
      if (poses.isNotEmpty) {
        final pose = poses.first;
        final leftWrist = pose.landmarks[PoseLandmarkType.leftWrist];
        final rightWrist = pose.landmarks[PoseLandmarkType.rightWrist];

        if ((leftWrist != null && leftWrist.likelihood > 0.8) || 
            (rightWrist != null && rightWrist.likelihood > 0.8)) {
          _performWaveAction();
        }
      }
    } catch (e) {
      debugPrint("Pose detection error: $e");
    } finally {
      _isBusy = false;
    }
  }

  // 모델 교체 시 모든 파라미터를 명시적으로 고정
  Future<void> _updateCharacterModel(String modelPath, {required vector.Vector3 position, required double yaw}) async {
    // 1. 이전 노드 제거
    if (_characterNode != null) {
      await arObjectManager?.removeNode(_characterNode!);
    }

    // 2. 새 노드 생성 및 크기/위치/방향(Yaw) 강제 고정
    _characterNode = ARNode(
      type: NodeType.localGLTF2,
      uri: modelPath,
      scale: _fixedScale,
      position: position,
    );
    // X, Z축 회전을 0으로 고정하여 뒤집힘 원천 차단
    _characterNode!.eulerAngles = vector.Vector3(0, yaw, 0);

    // 3. 새 노드 추가
    await arObjectManager?.addNode(_characterNode!, planeAnchor: _currentAnchor);
  }

  Future<void> _performWaveAction() async {
    if (_isActionExecuting || _characterNode == null) return;
    _isActionExecuting = true;
    _wanderTimer?.cancel();

    if (mounted) setState(() { _statusMessage = "안녕! 다마고치가 손을 흔듭니다."; });

    final lastPos = _characterNode!.position;
    final lastYaw = _characterNode!.eulerAngles.y;

    await _updateCharacterModel("assets/models/TAMA1_Wave_One_Hand.glb", position: lastPos, yaw: lastYaw);
    await Future.delayed(const Duration(seconds: 4));

    if (mounted) {
      await _updateCharacterModel("assets/models/TAMA1_stop.glb", position: lastPos, yaw: lastYaw);
      setState(() { _statusMessage = "다마고치와 함께 놀아요!"; });
      _isActionExecuting = false;
      _startWandering();
    }
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    final sensorOrientation = cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.front).sensorOrientation;
    final rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    final allBytes = WriteBuffer();
    for (final plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final metadata = InputImageMetadata(
      size: imageSize,
      rotation: rotation,
      format: format,
      bytesPerRow: image.planes[0].bytesPerRow,
    );

    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  void onARViewCreated(
    ARSessionManager arSessionManager,
    ARObjectManager arObjectManager,
    ARAnchorManager arAnchorManager,
    ARLocationManager arLocationManager,
  ) {
    this.arSessionManager = arSessionManager;
    this.arObjectManager = arObjectManager;
    this.arAnchorManager = arAnchorManager;

    this.arSessionManager!.onInitialize(
      showFeaturePoints: true,
      showPlanes: true,
      showWorldOrigin: false,
      handleTaps: true,
    );
    this.arObjectManager!.onInitialize();

    this.arSessionManager!.onPlaneOrPointTap = (List<ARHitTestResult> hits) {
      if (!_isCharacterPlaced && hits.isNotEmpty) {
        ARHitTestResult? bestHit;
        try {
          bestHit = hits.firstWhere((element) => element.type == ARHitTestResultType.plane);
        } catch (e) {
          bestHit = hits.first;
        }
        
        if (bestHit != null) {
          _addAnchorAndNode(bestHit);
        }
      }
    };

    this.arSessionManager!.onPlaneDetected = (int planeCount) {
      if (!_isCharacterPlaced && planeCount > 0) {
        if (mounted) {
          setState(() {
            _statusMessage = "바닥이 감지되었습니다! 화면을 터치하여 소환하세요.";
          });
        }
      }
    };
  }

  Future<void> _addAnchorAndNode(ARHitTestResult hitResult) async {
    if (_isCharacterPlaced) return;
    _isCharacterPlaced = true;
    
    _currentAnchor = ARPlaneAnchor(transformation: hitResult.worldTransform);
    bool? didAddAnchor = await arAnchorManager?.addAnchor(_currentAnchor!);
    
    if (didAddAnchor == true) {
      _characterNode = ARNode(
        type: NodeType.localGLTF2,
        uri: "assets/models/TAMA1_stop.glb",
        scale: _fixedScale,
        position: vector.Vector3(0, 0, 0),
      );
      _characterNode!.eulerAngles = vector.Vector3(0, 0, 0);

      bool? didAddNode = await arObjectManager?.addNode(_characterNode!, planeAnchor: _currentAnchor);
      
      if (didAddNode == true) {
        if (mounted) {
          setState(() {
            _statusMessage = "다마고치가 소환되었습니다!";
          });
        }
        _startWandering();
      }
    } else {
      _isCharacterPlaced = false;
    }
  }

  void _startWandering() {
    if (_isActionExecuting) return;
    _wanderTimer = Timer.periodic(const Duration(seconds: 12), (timer) async {
      if (!mounted || _isActionExecuting || _characterNode == null) return;
      
      _isActionExecuting = true;
      
      final startPos = vector.Vector3.copy(_characterNode!.position);
      final random = math.Random();
      final double targetX = (random.nextDouble() - 0.5) * 0.4;
      final double targetZ = (random.nextDouble() - 0.5) * 0.4;
      
      final angle = math.atan2(targetX - startPos.x, targetZ - startPos.z);

      // 1. 걷기 모델로 변경 (회전 고정 포함)
      await _updateCharacterModel("assets/models/TAMA1_Casual_Walk.glb", position: startPos, yaw: angle);

      // 2. 실제 위치 이동 (루프)
      int steps = 60;
      double stepX = (targetX - startPos.x) / steps;
      double stepZ = (targetZ - startPos.z) / steps;

      for (int i = 0; i < steps; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
        if (!mounted || !_isActionExecuting || _characterNode == null) break;
        
        final currentPos = _characterNode!.position;
        currentPos.x += stepX;
        currentPos.z += stepZ;
        _characterNode!.position = currentPos;
      }

      // 3. 도착 후 정지 모델로 복구 (현재 위치와 각도 유지)
      if (mounted && _isActionExecuting && _characterNode != null) {
        final finalPos = vector.Vector3.copy(_characterNode!.position);
        await _updateCharacterModel("assets/models/TAMA1_stop.glb", position: finalPos, yaw: angle);
        _isActionExecuting = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          ARView(
            onARViewCreated: onARViewCreated,
            planeDetectionConfig: PlaneDetectionConfig.horizontal,
          ),
          if (_frontCameraController != null && _frontCameraController!.value.isInitialized)
             const SizedBox.shrink(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _statusMessage,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!_isCharacterPlaced)
            Positioned(
              bottom: 60,
              left: 0,
              right: 0,
              child: Center(
                child: Column(
                  children: [
                    const CircularProgressIndicator(color: Colors.white),
                    const SizedBox(height: 16),
                    Text(
                      _statusMessage == "바닥이 감지되었습니다! 화면을 터치하여 소환하세요."
                        ? "화면을 터치하면 캐릭터가 소환됩니다!"
                        : "바닥을 천천히 비춰주세요...",
                      textAlign: TextAlign.center,
                      style: const TextStyle(
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
        ],
      ),
    );
  }
}
