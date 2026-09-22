import cv2
import time
import os
import numpy as np

CAMERA = "/dev/video0"
DETECTOR_MODEL = "face_detection_yunet_2023mar.onnx"
RECOGNITION_MODEL = "face_recognition_sface_2021dec.onnx"

DATA_DIR = os.path.expanduser("~/.local/share/linux-faceid")
FACE_FILE = os.path.join(DATA_DIR, "face.npy")

THRESHOLD = 0.363
ENROLL_FRAMES = 20

print("[INFO] Linux Face ID")
print(f"[INFO] Camera: {CAMERA}")
print(f"[INFO] Detector: {DETECTOR_MODEL}")
print(f"[INFO] Recognition: {RECOGNITION_MODEL}")
print(f"[INFO] Face profile: {FACE_FILE}")

# Create private data directory.
os.makedirs(DATA_DIR, mode=0o700, exist_ok=True)

# Load existing enrollment.
enrolled_face = None

if os.path.exists(FACE_FILE):
    try:
        enrolled_face = np.load(FACE_FILE)

        if enrolled_face.shape != (1, 128):
            print(
                f"[WARN] Invalid face profile shape: "
                f"{enrolled_face.shape}"
            )
            enrolled_face = None
        else:
            print("[INFO] Existing face profile loaded")

    except Exception as e:
        print(f"[WARN] Failed to load face profile: {e}")
else:
    print("[INFO] No enrolled face profile found")

camera = cv2.VideoCapture(CAMERA, cv2.CAP_V4L2)

if not camera.isOpened():
    print("[ERROR] Failed to open camera")
    raise SystemExit(1)

camera.set(
    cv2.CAP_PROP_FOURCC,
    cv2.VideoWriter_fourcc(*"MJPG")
)
camera.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
camera.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
camera.set(cv2.CAP_PROP_FPS, 60)

width = int(camera.get(cv2.CAP_PROP_FRAME_WIDTH))
height = int(camera.get(cv2.CAP_PROP_FRAME_HEIGHT))
fps_camera = camera.get(cv2.CAP_PROP_FPS)

print(
    f"[INFO] Camera mode: "
    f"{width}x{height} @ {fps_camera:.1f} FPS"
)

detector = cv2.FaceDetectorYN.create(
    DETECTOR_MODEL,
    "",
    (320, 320),
    0.8,
    0.3,
    5000,
)

recognizer = cv2.FaceRecognizerSF.create(
    RECOGNITION_MODEL,
    "",
)

print("[INFO] YuNet loaded")
print("[INFO] SFace loaded")
print()
print("[INFO] Controls:")
print("       E = enroll / replace face")
print("       R = clear face profile")
print("       ESC = quit")
print()

enrolling = False
enrollment_features = []

last_time = time.perf_counter()
frames = 0
fps = 0

while True:
    try:
        ok, frame = camera.read()

        if not ok:
            print("[ERROR] Failed to read camera frame")
            break

        h, w = frame.shape[:2]
        detector.setInputSize((w, h))

        detect_start = time.perf_counter()

        _, faces = detector.detect(frame)

        detect_time = (
            time.perf_counter() - detect_start
        ) * 1000

        face_count = 0
        score = None
        status = "No face"

        if faces is not None:
            face_count = len(faces)

            # Use the largest detected face.
            face = max(
                faces,
                key=lambda f: f[2] * f[3]
            )

            x, y, fw, fh = face[:4].astype(int)

            cv2.rectangle(
                frame,
                (x, y),
                (x + fw, y + fh),
                (0, 255, 0),
                2,
            )

            # Generate face embedding.
            aligned = recognizer.alignCrop(
                frame,
                face
            )

            feature = recognizer.feature(
                aligned
            )

            if enrolling:
                enrollment_features.append(
                    feature.copy()
                )

                count = len(enrollment_features)

                status = (
                    f"Enrolling "
                    f"{count}/{ENROLL_FRAMES}"
                )

                if count >= ENROLL_FRAMES:
                    # Average all enrollment embeddings.
                    enrolled_face = np.mean(
                        np.vstack(
                            enrollment_features
                        ),
                        axis=0,
                        keepdims=True,
                    )

                    # Normalize the resulting embedding.
                    norm = np.linalg.norm(
                        enrolled_face
                    )

                    if norm > 0:
                        enrolled_face /= norm

                    # Save to disk.
                    np.save(
                        FACE_FILE,
                        enrolled_face
                    )

                    # Make sure the file is private.
                    os.chmod(FACE_FILE, 0o600)

                    enrollment_features.clear()
                    enrolling = False

                    print(
                        "[EVENT] Enrollment complete"
                    )
                    print(
                        "[EVENT] Face profile saved"
                    )
                    print(
                        f"[INFO] Saved to {FACE_FILE}"
                    )

            elif enrolled_face is None:
                status = "Press E to enroll"

            else:
                # Compare current face with saved profile.
                score = recognizer.match(
                    enrolled_face,
                    feature,
                    cv2.FaceRecognizerSF_FR_COSINE,
                )

                if score >= THRESHOLD:
                    status = (
                        f"Recognized {score:.3f}"
                    )
                else:
                    status = (
                        f"Unknown {score:.3f}"
                    )

        else:
            if enrolling:
                status = (
                    f"Enrolling "
                    f"{len(enrollment_features)}/"
                    f"{ENROLL_FRAMES}"
                )

        frames += 1

        now = time.perf_counter()

        if now - last_time >= 1:
            fps = frames / (
                now - last_time
            )

            frames = 0
            last_time = now

        cv2.putText(
            frame,
            status,
            (20, 40),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.9,
            (0, 255, 0),
            2,
        )

        cv2.putText(
            frame,
            f"FPS: {fps:.1f}",
            (20, 75),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.8,
            (0, 255, 0),
            2,
        )

        cv2.putText(
            frame,
            f"Faces: {face_count}",
            (20, 110),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.7,
            (0, 255, 0),
            2,
        )

        cv2.imshow(
            "Linux Face ID",
            frame
        )

        key = cv2.waitKey(1) & 0xFF

        if key == ord("e"):
            if faces is not None:
                enrollment_features.clear()
                enrolling = True

                print(
                    f"[EVENT] Enrollment started "
                    f"({ENROLL_FRAMES} frames)"
                )

                print(
                    "[INFO] Look directly at the camera"
                )

            else:
                print(
                    "[EVENT] Enrollment failed: "
                    "no face detected"
                )

        elif key == ord("r"):
            enrolled_face = None
            enrollment_features.clear()
            enrolling = False

            if os.path.exists(FACE_FILE):
                try:
                    os.remove(FACE_FILE)
                    print(
                        "[EVENT] Face profile deleted"
                    )
                except OSError as e:
                    print(
                        f"[ERROR] Failed to delete "
                        f"profile: {e}"
                    )
            else:
                print(
                    "[EVENT] Face profile cleared"
                )

        elif key == 27:
            print()
            print("[INFO] Shutting down...")
            break

    except KeyboardInterrupt:
        print()
        print("[INFO] Interrupted")
        break

camera.release()
cv2.destroyAllWindows()

print("[INFO] Camera released")
print("[INFO] Linux Face ID stopped")
