"""
제스처 학습 스크립트

사용법:
  1. gestures/ 폴더 아래에 제스처별로 사진을 준비합니다.
     gestures/
       palm/          ← ✋ 손바닥 사진 30장 이상
       v_sign/        ← ✌️ 브이 사진 30장 이상
       fist/          ← 👊 주먹 사진 30장 이상
       finger_heart/  ← 🤞 손가락 하트 사진 30장 이상

  2. 서버를 먼저 실행합니다:
       uvicorn main:app --host 0.0.0.0 --port 8000

  3. 이 스크립트를 실행합니다:
       python train_gesture.py

  4. 학습 완료 후 서버가 자동으로 제스처를 인식합니다.
"""

import glob
import os
import requests

BASE_URL = "http://localhost:8000"
GESTURES_DIR = "./gestures"
SUPPORTED = ["palm", "v_sign", "fist", "finger_heart"]

def upload_photos(label: str, folder: str):
    photos = glob.glob(os.path.join(folder, "*.jpg")) + \
             glob.glob(os.path.join(folder, "*.jpeg")) + \
             glob.glob(os.path.join(folder, "*.png"))
    if not photos:
        print(f"  [!] {folder} 에 사진이 없습니다.")
        return 0

    ok = 0
    for path in photos:
        with open(path, "rb") as f:
            try:
                res = requests.post(
                    f"{BASE_URL}/train/upload",
                    data={"label": label},
                    files={"file": (os.path.basename(path), f, "image/jpeg")},
                    timeout=10,
                )
                if res.status_code == 200:
                    ok += 1
                else:
                    print(f"  [!] {os.path.basename(path)}: {res.json().get('detail')}")
            except Exception as e:
                print(f"  [!] {os.path.basename(path)}: {e}")

    print(f"  [{label}] {ok}/{len(photos)} 장 업로드 완료")
    return ok

def main():
    print("=== TamaWith 제스처 학습 시작 ===\n")

    # 현재 상태 확인
    try:
        status = requests.get(f"{BASE_URL}/train/status", timeout=5).json()
        print(f"현재 샘플 수: {status['counts']}\n")
    except Exception:
        print("[오류] 서버에 연결할 수 없습니다. 서버가 실행 중인지 확인하세요.")
        return

    total = 0
    for gesture in SUPPORTED:
        folder = os.path.join(GESTURES_DIR, gesture)
        if not os.path.isdir(folder):
            print(f"  [skip] {folder} 폴더 없음")
            continue
        total += upload_photos(gesture, folder)

    if total == 0:
        print("\n업로드된 사진이 없습니다. gestures/ 폴더 구조를 확인하세요.")
        return

    print(f"\n총 {total}장 업로드 완료. 학습 시작...\n")
    try:
        res = requests.post(f"{BASE_URL}/train/fit", timeout=30).json()
        print("학습 결과:", res)
    except Exception as e:
        print(f"학습 실패: {e}")

if __name__ == "__main__":
    main()
