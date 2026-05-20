import base64
import json
import pickle
import time
from pathlib import Path
from typing import Optional

import cv2
import mediapipe as mp
import numpy as np
import uvicorn
from fastapi import FastAPI, File, Form, HTTPException, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from sklearn.ensemble import RandomForestClassifier
from sklearn.preprocessing import LabelEncoder

app = FastAPI(title="TamaWith Backend")
app.add_middleware(
    CORSMiddleware, allow_origins=["*"], allow_credentials=True,
    allow_methods=["*"], allow_headers=["*"],
)

# ── 펫 상태 ───────────────────────────────────────────────────────────────────
_pet = {
    "level": 1, "gold": 0, "diamonds": 0,
    "mood": 80, "fullness": 50, "hygiene": 100, "energy": 70,
}

def _clamp(v: int) -> int:
    return max(0, min(100, v))

def _apply(delta: dict):
    for k, v in delta.items():
        if k in _pet:
            _pet[k] = _clamp(_pet[k] + v)

# ── MediaPipe ────────────────────────────────────────────────────────────────
_hands = mp.solutions.hands.Hands(
    static_image_mode=True, max_num_hands=1, min_detection_confidence=0.5
)
_face_mesh = mp.solutions.face_mesh.FaceMesh(
    static_image_mode=True, max_num_faces=1, min_detection_confidence=0.5
)

def _landmarks(img_bytes: bytes) -> Optional[np.ndarray]:
    arr = np.frombuffer(img_bytes, np.uint8)
    img = cv2.imdecode(arr, cv2.IMREAD_COLOR)
    if img is None:
        return None
    res = _hands.process(cv2.cvtColor(img, cv2.COLOR_BGR2RGB))
    if not res.multi_hand_landmarks:
        return None
    lm = res.multi_hand_landmarks[0].landmark
    wrist = np.array([lm[0].x, lm[0].y, lm[0].z])
    # 손목→중지MCP 거리로 정규화 (크기·거리 불변)
    scale = np.linalg.norm(np.array([lm[9].x, lm[9].y, lm[9].z]) - wrist) + 1e-6
    feat = []
    for p in lm:
        feat += [(p.x - wrist[0]) / scale,
                 (p.y - wrist[1]) / scale,
                 (p.z - wrist[2]) / scale]
    return np.array(feat)  # shape: (63,)

# ── 표정 인식 (MediaPipe FaceMesh 기반, 5~20ms) ──────────────────────────────
def _expression(img_bytes: bytes) -> Optional[str]:
    arr = np.frombuffer(img_bytes, np.uint8)
    img = cv2.imdecode(arr, cv2.IMREAD_COLOR)
    if img is None:
        return None
    res = _face_mesh.process(cv2.cvtColor(img, cv2.COLOR_BGR2RGB))
    if not res.multi_face_landmarks:
        return None
    lm = res.multi_face_landmarks[0].landmark

    # 얼굴 세로 길이로 정규화 (이마:10 → 턱:152)
    face_h = abs(lm[152].y - lm[10].y) + 1e-6

    # 미소: 입꼬리(61, 291)가 입술 중심(13)보다 위에 있으면 (y 좌표 작을수록 위)
    lip_center_y = lm[13].y
    corner_y     = (lm[61].y + lm[291].y) / 2
    smile_score  = (lip_center_y - corner_y) / face_h  # 양수 = 꼬리가 위 = 미소

    # 놀람: 입 벌림 + 눈썹 올라감
    mouth_open  = abs(lm[14].y - lm[13].y) / face_h
    brow_raise  = (lm[1].y - (lm[52].y + lm[282].y) / 2) / face_h

    if smile_score > 0.025:
        return "happy"
    if mouth_open > 0.07 and brow_raise > 0.40:
        return "surprise"
    return None  # neutral은 아무 반응 없음

# ── 제스처 분류기 ─────────────────────────────────────────────────────────────
_MODEL_PATH = Path("gesture_model.pkl")
_SAMPLES_PATH = Path("gesture_samples.json")

_clf: Optional[RandomForestClassifier] = None
_le = LabelEncoder()
_samples: list[dict] = []

if _MODEL_PATH.exists():
    _saved = pickle.loads(_MODEL_PATH.read_bytes())
    _clf, _le = _saved["clf"], _saved["le"]
if _SAMPLES_PATH.exists():
    _samples = json.loads(_SAMPLES_PATH.read_text(encoding="utf-8"))

# 제스처 → 스탯 변화 + 애니메이션 액션
GESTURE_MAP = {
    "palm":         {"mood": 5,            "action": "wave"},
    "v_sign":       {"mood": 10,           "action": "happy"},
    "fist":         {"energy": 10,         "action": "fighting"},
    "finger_heart": {"mood": 15, "hygiene": 5, "action": "love"},
}

# 표정 → 스탯 변화 (소폭)
EXPRESSION_MAP = {
    "happy":    {"mood":  2},
    "sad":      {"mood": -2},
    "angry":    {"mood": -3},
    "surprise": {"mood":  1},
    "fear":     {"mood": -1},
    "disgust":  {"mood": -2},
}

GESTURE_COOLDOWN = 5.0   # 같은 클라이언트가 제스처 재발동하는 최소 간격(초)
EXPR_INTERVAL    = 3.0   # 표정 인식 최소 간격(초)

# ── WebSocket ─────────────────────────────────────────────────────────────────
_clients: set[WebSocket] = set()
_gesture_ts: dict[int, float] = {}  # id(ws) → 마지막 제스처 시각
_expr_ts:    dict[int, float] = {}  # id(ws) → 마지막 표정 인식 시각

async def _broadcast(data: dict):
    msg = json.dumps({**data, "current_fullness": _pet["fullness"]})
    dead = set()
    for ws in _clients:
        try:
            await ws.send_text(msg)
        except Exception:
            dead.add(ws)
    _clients -= dead

@app.websocket("/ws/gesture")
async def ws_handler(ws: WebSocket):
    await ws.accept()
    _clients.add(ws)
    _gesture_ts[id(ws)] = 0.0
    _expr_ts[id(ws)]    = 0.0
    # 연결 즉시 현재 펫 상태 전송
    await ws.send_text(json.dumps({**_pet, "current_fullness": _pet["fullness"]}))
    try:
        while True:
            raw  = await ws.receive_text()
            data = json.loads(raw)
            action = data.get("action")

            if action == "FEED":
                _apply({"fullness": 10, "gold": 1})
                await _broadcast(_pet)

            elif action == "FRAME":
                b64 = data.get("frame", "")
                if not b64:
                    continue
                img_bytes = base64.b64decode(b64)
                now = time.time()

                # 제스처 인식
                if _clf is not None and now - _gesture_ts[id(ws)] >= GESTURE_COOLDOWN:
                    lm = _landmarks(img_bytes)
                    if lm is not None:
                        gesture = _le.inverse_transform(_clf.predict([lm]))[0]
                        fx = GESTURE_MAP.get(gesture)
                        if fx:
                            _gesture_ts[id(ws)] = now
                            _apply({k: v for k, v in fx.items() if k != "action"})
                            await _broadcast({**_pet, "gesture": gesture, "gesture_action": fx["action"]})
                            continue

                # 표정 인식 (스로틀링 — FaceMesh는 빠르므로 직접 호출)
                if now - _expr_ts[id(ws)] >= EXPR_INTERVAL:
                    _expr_ts[id(ws)] = now
                    expr = _expression(img_bytes)
                    if expr and expr in EXPRESSION_MAP:
                        _apply(EXPRESSION_MAP[expr])
                        await _broadcast({**_pet, "expression": expr})

    except WebSocketDisconnect:
        pass
    finally:
        _clients.discard(ws)
        _gesture_ts.pop(id(ws), None)
        _expr_ts.pop(id(ws), None)

# ── 학습 API ─────────────────────────────────────────────────────────────────

@app.post("/train/upload")
async def upload_sample(label: str = Form(...), file: UploadFile = File(...)):
    """
    제스처 사진 한 장을 업로드해 학습 데이터를 수집합니다.
    label: palm | v_sign | fist | finger_heart
    """
    img_bytes = await file.read()
    lm = _landmarks(img_bytes)
    if lm is None:
        raise HTTPException(400, "손이 감지되지 않았습니다. 더 밝거나 손이 잘 보이는 사진을 올려주세요.")
    _samples.append({"label": label, "lm": lm.tolist()})
    _SAMPLES_PATH.write_text(json.dumps(_samples), encoding="utf-8")
    counts: dict[str, int] = {}
    for s in _samples:
        counts[s["label"]] = counts.get(s["label"], 0) + 1
    return {"ok": True, "label": label, "total": len(_samples), "counts": counts}

@app.post("/train/fit")
async def fit_model():
    """수집된 샘플로 RandomForest 분류기를 학습하고 저장합니다."""
    global _clf, _le
    if len(_samples) < 10:
        raise HTTPException(400, f"샘플 부족 — 현재 {len(_samples)}개 (제스처당 최소 10장 권장)")
    X = np.array([s["lm"] for s in _samples])
    y = [s["label"] for s in _samples]
    _le = LabelEncoder().fit(y)
    _clf = RandomForestClassifier(n_estimators=150, random_state=42)
    _clf.fit(X, _le.transform(y))
    _MODEL_PATH.write_bytes(pickle.dumps({"clf": _clf, "le": _le}))
    counts: dict[str, int] = {}
    for label in y:
        counts[label] = counts.get(label, 0) + 1
    return {"ok": True, "counts": counts, "message": "학습 완료!"}

@app.get("/train/status")
async def train_status():
    counts: dict[str, int] = {}
    for s in _samples:
        counts[s["label"]] = counts.get(s["label"], 0) + 1
    return {"model_ready": _clf is not None, "total_samples": len(_samples), "counts": counts}

@app.delete("/train/reset")
async def reset_model():
    global _clf, _samples
    _clf    = None
    _samples = []
    _MODEL_PATH.unlink(missing_ok=True)
    _SAMPLES_PATH.unlink(missing_ok=True)
    return {"ok": True, "message": "초기화 완료"}

@app.get("/health")
async def health():
    return {"ok": True, "model_ready": _clf is not None, "pet": _pet}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
