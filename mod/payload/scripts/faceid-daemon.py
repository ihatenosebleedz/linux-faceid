#!/usr/bin/env python3
"""Linux Face ID backend daemon.

Local facial recognition for a personal Void Linux + Hyprland machine.
Everything stays on this machine: camera frames are never exported, and the
IPC socket only carries JSON status/commands, never pixels or face data.

Architecture
------------
A single capture thread owns the camera (V4L2, MJPEG) and runs the YuNet
detector + SFace recognizer, mirroring the original prototype exactly
(threshold 0.363, 20 enrollment frames, averaged + normalized embedding).
Commands arrive from a Unix socket and are consumed by that loop, so the
camera is only ever touched by one thread.

Ownership:
  * socket path : $XDG_RUNTIME_DIR/linux-faceid.sock (fallback /tmp)
  * data dir    : $XDG_DATA_HOME/linux-faceid (fallback ~/.local/share/linux-faceid)
                  0700; face.npy is saved 0600.

Protocol (line-delimited JSON over the Unix socket):

client -> daemon   {"command": "status" | "watch:on" | "watch:off" |
                                "enroll" | "verify" | "clear" | "cancel" | "quit" |
                                "auth"}
  daemon -> client   {"event": "state",   "data": {...snapshot...}}
                     {"event": "message", "data": {"level": "...", "text": "..."}}
                     {"event": "auth",    "data": {"status":"pending"|"success"|"failed",
                                                    "score":..., "reason":"..."}}
                     {"event": "auth_result", "data": {"ok": true|false,
                                                        "reason":"...", "score":...}}

  "auth" is a one-shot verification request used by the doas PAM module (and
  anything else that wants a decisive result). It opens the camera if needed,
  looks for the enrolled face, then:
    * replies to the *requesting* client with auth_result,
    * broadcasts an auth event so the shell can show a face-ID notification,
    * closes the camera again unless something else was already watching.
  Auth gives up after AUTH_TIMEOUT without a match.

The daemon broadcasts the full state snapshot to every connected client on
each meaningful change and sends a fresh snapshot to a client right after it
connects.  Debug values (score, fps, faces) are part of the snapshot.

Usage:
    python3 faceid-daemon.py            # run in the foreground
env overrides: FACEID_CAMERA, FACEID_MODEL_DIR, FACEID_SOCKET, FACEID_DATA_DIR
"""

import json
import os
import queue
import signal
import socket
import struct
import sys
import threading
import time

import cv2
import numpy as np

PROTOCOL = 1

CAMERA = os.environ.get("FACEID_CAMERA", "/dev/video0")
DETECTOR_MODEL = "face_detection_yunet_2023mar.onnx"
RECOGNITION_MODEL = "face_recognition_sface_2021dec.onnx"

THRESHOLD = 0.363
ENROLL_FRAMES = 20

# One-shot auth (doas/PAM) gives up after this long without a match and lets
# the caller fall back to the password.
AUTH_TIMEOUT = 20.0
# If a face is present but keeps failing to match, give up a little faster.
AUTH_MISMATCH_GRACE = 4.0

# The C922 is as wedge-prone as the rest of this box's hardware: it can stall
# mid-stream (especially on quick open/close cycles), and cv2's read() then
# blocks forever. Frames are therefore fetched by a dedicated reader thread
# feeding a bounded queue, and the main loop only ever non-blocking-waits on
# it. If the camera stops delivering frames for CAMERA_STALL_TIMEOUT seconds
# it's treated as wedged and force-released so the next watch attempt starts
# from a fresh capture.
CAMERA_STALL_TIMEOUT = 3.0
# The C922 can also wedge on the *open* call itself: cv2.VideoCapture() on a
# still-recovering device blocks the caller indefinitely. Opening therefore
# runs on a worker thread; if it hasn't returned within CAMERA_OPEN_TIMEOUT we
# abandon the attempt, keep the main loop alive, and briefly cool down so we
# don't hammer the wedged device.
CAMERA_OPEN_TIMEOUT = 2.0
CAMERA_OPEN_COOLDOWN = 10.0
FRAME_WAIT = 0.05

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.expanduser("~/Projects/linux-faceid")

DATA_DIR = os.environ.get(
    "FACEID_DATA_DIR",
    os.path.expanduser("~/.local/share/linux-faceid"),
)
FACE_FILE = os.path.join(DATA_DIR, "face.npy")

SOCKET_PATH = os.environ.get(
    "FACEID_SOCKET",
    os.path.join(
        os.environ.get("XDG_RUNTIME_DIR", "/tmp"),
        "linux-faceid.sock",
    ),
)


def find_model(name):
    """Resolve an ONNX model, preferring a staged copy in the data dir."""
    candidates = []
    if os.environ.get("FACEID_MODEL_DIR"):
        candidates.append(os.environ["FACEID_MODEL_DIR"])
    candidates += [
        os.path.join(DATA_DIR, "models"),
        DATA_DIR,
        os.path.join(SCRIPT_DIR, "..", "models"),
        os.path.join(SCRIPT_DIR, "models"),
        SCRIPT_DIR,
        os.path.join(PROJECT_DIR, "models"),
        PROJECT_DIR,
        "/usr/share/linux-faceid/models",
        "/usr/local/share/linux-faceid/models",
    ]
    for directory in candidates:
        path = os.path.normpath(os.path.join(directory, name))
        if os.path.isfile(path):
            return path
    return None


def stage_models():
    """Copy the ONNX models into the private data dir so the runtime is
    self-contained even if the prototype checkout moves."""
    if os.path.isfile(os.path.join(DATA_DIR, DETECTOR_MODEL)) and os.path.isfile(
        os.path.join(DATA_DIR, RECOGNITION_MODEL)
    ):
        return
    source = os.path.dirname(FACE_FILE)
    os.makedirs(DATA_DIR, mode=0o700, exist_ok=True)
    for name in (DETECTOR_MODEL, RECOGNITION_MODEL):
        path = find_model(name)
        if not path:
            continue
        destination = os.path.join(DATA_DIR, name)
        if os.path.isfile(destination):
            continue
        try:
            with open(path, "rb") as src, open(destination, "wb") as dst:
                dst.write(src.read())
            os.chmod(destination, 0o600)
        except OSError as error:
            print(f"[WARN] failed to stage {name}: {error}")


class State:
    """The single source of truth for what the QML shell shows."""

    def __init__(self):
        self.lock = threading.Lock()
        self.backend = True
        self.camera_available = False
        self.camera = False
        self.watching = False
        self.fps = 0.0
        self.faces = 0
        self.face_detected = False
        self.recognizing = False
        self.recognized = None
        self.score = None
        self.enrolled = self._profile_exists()
        self.enrolling = False
        self.enroll_progress = 0
        self.error = None
        self.dirty = True

    @staticmethod
    def _profile_exists():
        return os.path.isfile(FACE_FILE)

    def snapshot(self):
        with self.lock:
            return {
                "protocol": PROTOCOL,
                "backend": self.backend,
                "cameraAvailable": self.camera_available,
                "camera": self.camera,
                "watching": self.watching,
                "fps": round(self.fps, 1),
                "faces": self.faces,
                "faceDetected": self.face_detected,
                "recognizing": self.recognizing,
                "recognized": None if self.recognized is None else bool(self.recognized),
                "score": None if self.score is None else round(float(self.score), 4),
                "threshold": THRESHOLD,
                "enrolled": self.enrolled,
                "enrolling": self.enrolling,
                "enrollProgress": self.enroll_progress,
                "enrollTotal": ENROLL_FRAMES,
                "error": self.error,
            }

    def touch(self):
        self.dirty = True


class Broadcaster:
    """Fan-out for state snapshots and one-off messages to all clients."""

    def __init__(self, state):
        self.state = state
        self.clients = set()
        self.clients_lock = threading.RLock()

    def register(self, connection):
        with self.clients_lock:
            self.clients.add(connection)
        self.send(connection, {"event": "state", "data": self.state.snapshot()})

    def drop(self, connection):
        with self.clients_lock:
            self.clients.discard(connection)

    def send(self, connection, message):
        data = (json.dumps(message, separators=(",", ":")) + "\n").encode()
        try:
            with connection.write_lock:
                connection.sock.sendall(data)
        except OSError:
            self.drop(connection)

    def broadcast(self, message):
        with self.clients_lock:
            clients = list(self.clients)
        for connection in clients:
            self.send(connection, message)

    def publish(self):
        """Send a state snapshot if anything marked it dirty."""
        if not self.state.dirty:
            return
        self.state.dirty = False
        self.broadcast({"event": "state", "data": self.state.snapshot()})

    def message(self, level, text):
        print(f"[{level.lower()}] {text}")
        self.broadcast(
            {"event": "message", "data": {"level": level, "text": text}}
        )


class Connection:
    def __init__(self, sock):
        self.sock = sock
        self.write_lock = threading.Lock()


def serve(broadcaster, commands):
    """Accept loop: spawn one reader thread per client."""

    def handle(connection):
        parser = connection.sock.makefile("rb")
        try:
            while True:
                try:
                    line = parser.readline()
                except OSError:
                    break
                if not line:
                    break
                try:
                    message = json.loads(line.decode().strip())
                except ValueError:
                    continue
                command = message.get("command")
                if not command:
                    continue
                commands.put((command, connection))
        finally:
            parser.close()
            broadcaster.drop(connection)
            try:
                connection.sock.close()
            except OSError:
                pass

    while True:
        try:
            sock, _ = socket_server.accept()
            # Prevent sendall from blocking indefinitely if a client stops reading
            timeval = struct.pack("ll", 2, 0)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDTIMEO, timeval)
        except OSError:
            if stopping.is_set():
                return
            continue
        connection = Connection(sock)
        try:
            broadcaster.register(connection)
        except OSError:
            # Client vanished between accept() and the snapshot write.
            broadcaster.drop(connection)
            try:
                connection.sock.close()
            except OSError:
                pass
            continue
        threading.Thread(
            target=handle,
            args=(connection,),
            daemon=True,
        ).start()


def load_profile():
    """Load the enrolled embedding or return None when invalid/missing."""
    if not os.path.isfile(FACE_FILE):
        return None
    try:
        profile = np.load(FACE_FILE)
        if profile.shape != (1, 128):
            return None
        return profile
    except Exception:
        return None


def frame_reader(camera, frames, stop):
    """Run in a daemon thread around the blocking cv2 read().

    `camera.read()` can hang forever if the UVC device wedges, which would
    otherwise freeze the main loop and leave the camera LED stuck on. This
    thread owns the blocking read and hands completed frames to the main loop
    through a bounded queue, so the loop can keep answering sockets and can
    detect a stalled capture. `stop` is an Event that, when set, releases the
    capture so a wedged DQBUF is torn down and this thread exits.

    Sensing: main() passes cam/stop via closure through this signature.
    """
    while not stop.is_set():
        try:
            ok, frame = camera.read()
        except cv2.error:
            ok, frame = False, None
        if ok:
            try:
                frames.put_nowait((ok, frame))
            except queue.Full:
                # drop oldest: keep the freshest frame
                try:
                    frames.get_nowait()
                except queue.Empty:
                    pass
                try:
                    frames.put_nowait((ok, frame))
                except queue.Full:
                    pass
        else:
            time.sleep(0.05)
    try:
        camera.release()
    except cv2.error:
        pass


def open_camera_thread(out, cancelled):
    """Run on a worker thread: the C922 can block inside VideoCapture() itself
    (wedged open), so the open must not run inline on the main loop.
    `cancelled` is a threading.Event set by the main loop when it abandons this
    attempt — if VideoCapture() finally returns after the timeout, the thread
    releases the camera itself so the device doesn't stay held."""
    try:
        candidate = cv2.VideoCapture(CAMERA, cv2.CAP_V4L2)
        if candidate.isOpened():
            if cancelled.is_set():
                # Main loop already gave up — release immediately so the
                # device isn't orphaned until GC.
                candidate.release()
                out["camera"] = None
                out["ok"] = False
                return
            candidate.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
            candidate.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
            candidate.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
            candidate.set(cv2.CAP_PROP_FPS, 60)
            out["camera"] = candidate
            out["ok"] = True
        else:
            candidate.release()
            out["camera"] = None
            out["ok"] = False
    except cv2.error:
        candidate = out.get("camera")
        if candidate is not None:
            candidate.release()
        out["camera"] = None
        out["ok"] = False


def main():
    global stopping

    os.makedirs(DATA_DIR, mode=0o700, exist_ok=True)
    stage_models()

    detector_path = find_model(DETECTOR_MODEL)
    recognizer_path = find_model(RECOGNITION_MODEL)
    if not detector_path or not recognizer_path:
        print("[FATAL] could not find the YuNet/SFace ONNX models", file=sys.stderr)
        print(f"[FATAL] detector {DETECTOR_MODEL}; recognizer {RECOGNITION_MODEL}", file=sys.stderr)
        return 1

    try:
        detector = cv2.FaceDetectorYN.create(
            detector_path, "", (320, 320), 0.8, 0.3, 5000
        )
        recognizer = cv2.FaceRecognizerSF.create(recognizer_path, "")
    except cv2.error as error:
        print(f"[FATAL] failed to load face models: {error}", file=sys.stderr)
        return 1

    print(f"[INFO] Linux Face ID daemon (protocol {PROTOCOL})")
    print(f"[INFO] Camera: {CAMERA}")
    print(f"[INFO] Data dir: {DATA_DIR}")
    print(f"[INFO] Socket: {SOCKET_PATH}")
    print(f"[INFO] Detector: {detector_path}")
    print(f"[INFO] Recognition: {recognizer_path}")

    # Load the enrolled profile up front so the first snapshot is honest.
    enrolled = load_profile()
    state = State()
    state.enrolled = enrolled is not None

    broadcaster = Broadcaster(state)
    commands = queue.Queue()

    teacher = threading.Thread(target=serve, args=(broadcaster, commands), daemon=True)
    teacher.start()

    camera = None
    reader = None
    reader_stop = threading.Event()
    frames = None
    last_frame_time = None
    frame_tally = 0
    sample_accumulator_start = time.monotonic()
    last_publish = 0.0

    # Threaded camera open: the C922 can block inside VideoCapture() itself,
    # so we run the open on a worker and poll it non-blocking from the main loop.
    opener_thread = None          # Thread | None
    opener_result = None          # dict with "ok" / "camera" keys, populated by thread
    opener_cancel = threading.Event()  # set when we abandon an in-flight open
    opener_start = 0.0
    camera_open_cooldown_until = 0.0

    enroll_features = []

    # One-shot auth (doas/PAM): someone asked to verify the enrolled face and
    # wants a decisive result. `auth_restore_watching` remembers whether the
    # camera was already being watched so we don't leave it open afterwards.
    auth_pending = False
    auth_restore_watching = False
    auth_start = 0.0
    auth_mismatch_since = None
    auth_conn = None

    def finish_auth(conn, ok, reason=None, score=None):
        nonlocal auth_pending, auth_restore_watching, auth_mismatch_since, auth_conn
        # `auth_result` must reach the requester even when this is called
        # from the frame loop / timeout paths (conn == None). Remember which
        # client asked for the auth and target the reply at it.
        target = auth_conn if auth_conn is not None else conn
        if target is not None:
            broadcaster.send(target, {
                "event": "auth_result",
                "data": {"ok": bool(ok), "reason": reason, "score": score},
            })
        broadcaster.broadcast({
            "event": "auth",
            "data": {
                "status": "success" if ok else "failed",
                "reason": reason,
                "score": score,
            },
        })
        if auth_pending:
            auth_pending = False
            auth_conn = None
            auth_mismatch_since = None
            state.watching = auth_restore_watching
            auth_restore_watching = False
            state.touch()

    shutting_down = False
    while not shutting_down:
        if stopping.is_set():
            shutting_down = True
            break

        now = time.monotonic()

        # Give up a pending auth that never produced a match.
        if auth_pending and now - auth_start > AUTH_TIMEOUT:
            finish_auth(None, False, "timeout")

        # Drain pending socket commands.
        try:
            while True:
                command, sender = commands.get_nowait()
                if command == "quit":
                    finish_auth(None, False, "cancelled")
                    shutting_down = True
                elif command == "watch:on":
                    state.watching = True
                    state.touch()
                elif command == "watch:off":
                    finish_auth(None, False, "cancelled")
                    state.watching = False
                    state.enrolling = False
                    enroll_features.clear()
                    state.enroll_progress = 0
                    state.touch()
                elif command == "status":
                    state.touch()
                elif command == "auth":
                    if state.enrolling:
                        finish_auth(sender, False, "enrolling")
                    elif enrolled is None:
                        finish_auth(sender, False, "no_profile")
                    elif auth_pending:
                        finish_auth(sender, False, "busy")
                    else:
                        auth_pending = True
                        auth_conn = sender
                        auth_restore_watching = state.watching
                        auth_start = now
                        auth_mismatch_since = None
                        state.watching = True
                        state.touch()
                        broadcaster.broadcast({
                            "event": "auth",
                            "data": {"status": "pending"},
                        })
                        broadcaster.message("info", "Face auth requested")
                elif command == "enroll":
                    finish_auth(None, False, "cancelled")
                    if not state.watching:
                        state.watching = True  # enrolling implies watching
                    if state.enrolling:
                        broadcaster.message("warn", "Enrollment already in progress")
                    elif camera is None:
                        broadcaster.message("error", "Camera unavailable")
                    else:
                        enroll_features.clear()
                        state.enrolling = True
                        state.enroll_progress = 0
                        state.error = None
                        state.touch()
                        broadcaster.message("info", "Look directly at the camera")
                elif command == "cancel":
                    finish_auth(None, False, "cancelled")
                    state.enrolling = False
                    enroll_features.clear()
                    state.enroll_progress = 0
                    state.touch()
                    broadcaster.message("info", "Enrollment cancelled")
                elif command == "clear":
                    finish_auth(None, False, "cancelled")
                    state.enrolling = False
                    enroll_features.clear()
                    state.enroll_progress = 0
                    enrolled = None
                    state.enrolled = False
                    state.recognized = None
                    state.score = None
                    state.touch()
                    try:
                        os.remove(FACE_FILE)
                        broadcaster.message("info", "Face profile cleared")
                    except FileNotFoundError:
                        broadcaster.message("info", "No face profile to clear")
                    except OSError as error:
                        state.error = f"Failed to remove profile: {error}"
                        broadcaster.message("error", str(state.error))
                elif command == "verify":
                    if state.enrolling:
                        broadcaster.message("error", "Finish or cancel enrollment first")
                    elif enrolled is None:
                        broadcaster.message("error", "No enrolled face profile")
                    elif camera is None:
                        broadcaster.message("error", "Camera unavailable")
                    else:
                        state.error = None
                        state.touch()
                        broadcaster.message("info", "Verifying…")
        except queue.Empty:
            pass

        # Camera lifecycle: only open while somebody wants frames.
        # The C922 can block inside VideoCapture() itself, so the open runs
        # on a worker thread.  We kick it off, then poll non-blocking until
        # it finishes or CAMERA_OPEN_TIMEOUT expires.
        if state.watching and camera is None and opener_thread is None:
            if now >= camera_open_cooldown_until:
                opener_result = {}
                opener_cancel.clear()
                opener_thread = threading.Thread(
                    target=open_camera_thread, args=(opener_result, opener_cancel), daemon=True
                )
                opener_start = now
                opener_thread.start()

        if opener_thread is not None:
            opener_thread.join(timeout=0)          # non-blocking poll
            if not opener_thread.is_alive():
                # Thread finished — check result.
                opener_thread = None
                if opener_result.get("ok"):
                    camera = opener_result["camera"]
                    reader_stop.clear()
                    frames = queue.Queue(maxsize=2)
                    reader = threading.Thread(
                        target=frame_reader, args=(camera, frames, reader_stop), daemon=True
                    )
                    reader.start()
                    last_frame_time = now
                    state.camera_available = True
                    state.error = None
                else:
                    camera_open_cooldown_until = now + CAMERA_OPEN_COOLDOWN
                    state.camera_available = False
                    state.error = "Failed to open camera"
                state.touch()
            elif now - opener_start > CAMERA_OPEN_TIMEOUT:
                # Thread wedged inside VideoCapture() — signal it to release
                # the device when it eventually returns, then abandon it.
                opener_cancel.set()
                opener_thread = None
                opener_result = {}
                camera_open_cooldown_until = now + CAMERA_OPEN_COOLDOWN
                state.camera_available = False
                state.error = "Camera open timed out — please retry"
                state.touch()

        if not state.watching and camera is not None:
            # release() issues VIDIOC_STREAMOFF, which cancels a wedged DQBUF
            # and wakes the reader thread; then it exits on the stop flag.
            reader_stop.set()
            camera.release()
            camera = None
            if reader is not None:
                reader.join(timeout=1.5)
            reader = None
            frames = None
            state.camera = False
            state.faces = 0
            state.face_detected = False
            state.recognizing = False
            state.touch()

        if not state.watching and opener_thread is not None:
            # Watching was cancelled while a threaded open was in progress;
            # signal the thread to release the device if/when it returns.
            opener_cancel.set()
            opener_thread = None
            opener_result = {}


        state.camera = camera is not None

        # A camera that stops delivering frames is wedged (this box's UVC
        # cam stalls on quick open/close cycles). The reader thread is stuck
        # inside read(); force-release it so the next loop iteration starts a
        # fresh capture. Auth falls through to its timeout -> password prompt.
        if state.watching and camera is not None and (
            now - last_frame_time > CAMERA_STALL_TIMEOUT
        ):
            reader_stop.set()
            camera.release()
            camera = None
            if reader is not None:
                reader.join(timeout=1.5)
            reader = None
            frames = None
            state.camera_available = False
            state.error = "Camera stopped responding — please retry"
            state.touch()

        frame = None
        if state.watching and camera is not None:
            try:
                ok, frame = frames.get_nowait()
            except (queue.Empty, AttributeError):
                ok, frame = False, None
            if ok:
                last_frame_time = now
            else:
                frame = None

        if frame is not None:
            height, width = frame.shape[:2]
            detector.setInputSize((width, height))
            _, faces = detector.detect(frame)
            face = None
            if faces is not None and len(faces) > 0:
                face = max(faces, key=lambda f: f[2] * f[3])
            state.faces = 0 if faces is None else len(faces)
            state.face_detected = face is not None
            state.recognizing = face is not None and not state.enrolling
            state.touch()

            if state.enrolling:
                if face is not None:
                    aligned = recognizer.alignCrop(frame, face)
                    enroll_features.append(recognizer.feature(aligned).copy())
                    state.enroll_progress = len(enroll_features)
                    if len(enroll_features) >= ENROLL_FRAMES:
                        pooled = np.mean(
                            np.vstack(enroll_features), axis=0, keepdims=True
                        )
                        norm = np.linalg.norm(pooled)
                        if norm > 0:
                            pooled = pooled / norm
                        np.save(FACE_FILE, pooled)
                        os.chmod(FACE_FILE, 0o600)
                        enrolled = pooled
                        enroll_features.clear()
                        state.enrolling = False
                        state.enrolled = True
                        state.error = None
                        broadcaster.message("success", "Enrollment complete")
                # no face -> keep waiting, counts only advance on a face
            elif enrolled is not None and face is not None:
                aligned = recognizer.alignCrop(frame, face)
                feature = recognizer.feature(aligned)
                score = recognizer.match(
                    enrolled,
                    feature,
                    cv2.FaceRecognizerSF_FR_COSINE,
                )
                state.score = float(score)
                state.recognized = score >= THRESHOLD
                state.error = None
                state.touch()
                if auth_pending:
                    if state.recognized:
                        finish_auth(None, True, score=round(state.score, 4))
                    elif auth_mismatch_since is None:
                        auth_mismatch_since = time.monotonic()
                    elif time.monotonic() - auth_mismatch_since > AUTH_MISMATCH_GRACE:
                        finish_auth(None, False, "no_match")
            elif face is None:
                # No face right now: reset the transient recognition reading.
                state.recognized = None
                state.score = None
                state.touch()
                if auth_pending:
                    auth_mismatch_since = None

            frame_tally += 1
            now = time.monotonic()
            if state.fps <= 0 or now - sample_accumulator_start >= 1.0:
                state.fps = frame_tally / max(now - sample_accumulator_start, 1e-6)
                frame_tally = 0
                sample_accumulator_start = now
                state.touch()

        # Publish at most once per ~100ms while idle, immediately when dirty.
        if state.dirty:
            broadcaster.publish()
            last_publish = time.monotonic()
        elif camera is not None and time.monotonic() - last_publish >= 0.1:
            broadcaster.publish()
            last_publish = time.monotonic()

        time.sleep(0.016)

    # Shutdown path.
    if camera is not None:
        reader_stop.set()  # STREAMOFF-style release cancels a wedged read()
        camera.release()
        if reader is not None:
            reader.join(timeout=1.5)
    if enrolled is not None and os.path.isfile(FACE_FILE):
        os.chmod(FACE_FILE, 0o600)
    cleanup_socket()
    print("[INFO] Linux Face ID daemon stopped")
    return 0


if __name__ == "__main__":
    stopping = threading.Event()

    def on_signal(signum, frame):
        stopping.set()

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    def cleanup_socket():
        try:
            os.unlink(SOCKET_PATH)
        except FileNotFoundError:
            pass
        except OSError:
            pass

    # Unique owner of the socket. If another live daemon already holds it,
    # leave it to do the work and exit quietly.
    if os.path.exists(SOCKET_PATH):
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.connect(SOCKET_PATH)
            print("[INFO] daemon already running; exiting")
            sys.exit(0)
        except OSError:
            pass
        finally:
            probe.close()
        cleanup_socket()

    umask = os.umask(0o077)
    socket_server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    socket_server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    socket_server.bind(SOCKET_PATH)
    socket_server.listen(8)
    os.umask(umask)
    os.chmod(SOCKET_PATH, 0o600)

    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        cleanup_socket()
        raise