import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import qs.modules.services

pragma Singleton

// FaceIdService bridges QML to the linux-faceid Python daemon.
//
// The daemon is a *child of this singleton* — spawned through the
// Quickshell Io Process API and spoken to over a private Unix socket at
// $XDG_RUNTIME_DIR/linux-faceid.sock. Protocol is line-delimited JSON:
//   QML -> daemon   {"command": "watch:on"|"watch:off"|"enroll"|"verify"|"clear"|"cancel"|"status"|"auth"}
//   daemon -> QML   {"event": "state",   "data": {...snapshot...}}
//                   {"event": "message", "data": {"level":"...", "text":"..."}}
//                   {"event": "auth",    "data": {"status":"pending"|"success"|"failed", "score":...}}
//
// Only status/commands cross the socket — never camera frames or face data.
// The daemon owns the camera and only opens it while something is watching.
//
// "auth" events signal an external one-shot verification (e.g. the doas PAM
// module). This service mirrors them as props for the settings panel and
// pushes a native notch notification so the scan shows up in the shell.
//
// The path to the daemon script is resolved relative to this file inside the
// mod's generated payload (generation/scripts/faceid-daemon.py).
Singleton {
    id: root

    readonly property string socketPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/linux-faceid.sock"

    // Resolve the staged daemon script next to this file:
    // modules/services/FaceIdService.qml -> ../../scripts/faceid-daemon.py
    readonly property string daemonPath: {
        let url = Qt.resolvedUrl("../../scripts/faceid-daemon.py").toString();
        if (url.startsWith("file://")) {
            let p = url.substring(7);
            try { return decodeURIComponent(p); } catch (e) { return p; }
        }
        return url;
    }

    property bool socketConnected: false
    property bool processRunning: false

    // ---- daemon state, mirrored 1:1 from state events ----
    property bool backend: false
    property bool cameraAvailable: false
    property bool camera: false
    property bool watching: false
    property real fps: 0
    property int faces: 0
    property bool faceDetected: false
    property bool recognizing: false
    property bool recognized: false
    property real score: -1
    property real threshold: 0.363
    property bool enrolled: false
    property bool enrolling: false
    property int enrollProgress: 0
    property int enrollTotal: 20
    property string errorMessage: ""

    // ---- one-shot auth (doas/PAM): mirrored from daemon "auth" events ----
    // idle -> pending -> success|failed
    property string authStatus: "idle"
    property real authScore: -1

    // ---- recent daemon messages (panel breadcrumb / status line) ----
    property var messages: []

    Timer {
        id: probeTimer
        interval: 500
        repeat: true
        running: true
        onTriggered: root.tick()
    }

    // Capped spawn: never launch the daemon more than once every 3s, and
    // only when the socket is dead. This absorbs the "another daemon is
    // already running" exit-0 case without a busy loop.
    property bool started: false
    property int spawnCooldownUntil: 0

    function nowMs() {
        return Date.now();
    }

    function tick() {
        if (!root.socketConnected) {
            root.tryConnect();
        }
        if (!root.socketConnected && !root.started && root.nowMs() >= root.spawnCooldownUntil) {
            root.spawn();
        }
    }

    function spawn() {
        root.started = true;
        root.processRunning = true;
        root.spawnCooldownUntil = root.nowMs() + 3000;
        daemonProcess.running = true;
    }

    // ---- socket lifecycle ----
    // The Quickshell Socket does not re-establish a connection once a connect
    // attempt has failed; a fresh instance is required. We therefore treat the
    // socket as throwaway: any error or unexpected disconnect destroys it and
    // the next probe tick recreates it.
    property var socket: null

    Component {
        id: socketFactory
        Socket {
            id: sock
            path: root.socketPath
            connected: false

            parser: SplitParser {
                onRead: (data) => {
                    if (!data) return;
                    try {
                        const msg = JSON.parse(data);
                        if (msg.event === "state") {
                            root.applyState(msg.data);
                        } else if (msg.event === "message") {
                            root.pushMessage(msg.data.level, msg.data.text);
                        } else if (msg.event === "auth") {
                            root.onAuthEvent(msg.data);
                        }
                    } catch (e) {
                        console.warn("FaceIdService: failed to parse message:", e);
                    }
                }
            }

            onConnectionStateChanged: {
                root.onSockState(sock.connected);
            }

            onError: (error) => {
                console.warn("FaceIdService: socket error", error);
                root.tearDown();
            }
        }
    }

    function ensureSocket() {
        if (root.socket) return;
        root.socket = socketFactory.createObject(root);
    }

    function onSockState(connected) {
        if (connected) {
            root.socketConnected = true;
            root.backend = true;
            root._drainQueue();
            return;
        }
        // Disconnected while we thought we were up, or a failed attempt.
        root.tearDown();
    }

    function tearDown() {
        const dead = root.socket;
        root.socket = null;
        root.socketConnected = false;
        root.backend = false;
        root.authStatus = "idle";
        root.authScore = -1;
        if (dead) {
            dead.connected = false;
            dead.destroy();
        }
    }

    function tryConnect() {
        if (root.socketConnected) return;
        root.ensureSocket();
        root.socket.connected = true;
    }

    // ---- outbound commands (buffered while disconnected) ----
    property var pendingQueue: []

    function _send(command) {
        const msg = JSON.stringify({command: command});
        if (root.socketConnected && root.socket) {
            root.socket.write(msg + "\n");
            root.socket.flush();
            root._drainQueue();
        } else {
            root.pendingQueue.push(msg);
        }
    }

    function _drainQueue() {
        while (root.socketConnected && root.socket && root.pendingQueue.length > 0) {
            const msg = root.pendingQueue.shift();
            root.socket.write(msg + "\n");
            root.socket.flush();
        }
    }

    function requestStatus() { root._send("status"); }
    function watchOn()       { root._send("watch:on"); }
    function watchOff()      { root._send("watch:off"); }
    function enroll()        { root._send("enroll"); }
    function verify()        { root._send("verify"); }
    function clear()         { root._send("clear"); }
    function cancel()        { root._send("cancel"); }
    function auth()          { root._send("auth"); }

    function pushMessage(level, text) {
        const msg = {level: level, text: text};
        root.messages = root.messages.concat(msg).slice(-30);
    }

    // ---- one-shot auth notch notification ----
    //
    // The daemon broadcasts "auth" events whenever something asks it to do a
    // one-shot verification (currently: the doas/PAM module). We mirror the
    // status into properties and raise a native notch notification so the
    // scan feels like a phone Face ID prompt. The same replaceKey swaps the
    // "looking for you…" bubble into the granted/denied one in place.
    readonly property string authReplaceKey: "community.linux-faceid.auth"

    function onAuthEvent(data) {
        root.authStatus = data && data.status ? data.status : "idle";
        root.authScore = data && Number.isFinite(data.score) ? data.score : -1;

        let summary = "";
        let body = "";
        let urgency = "normal";
        let expire = 5000;

        if (data.status === "pending") {
            summary = "Face ID";
            body = "Looking for your face…";
            urgency = "critical";
            expire = -1; // keep until the auth attempt resolves
        } else if (data.status === "success") {
            summary = "Face ID — unlocked";
            body = "Match " + (root.authScore * 100).toFixed(0) + "%";
            urgency = "normal";
            expire = 4000;
        } else if (data.status === "failed") {
            summary = "Face ID — denied";
            if (data.reason === "no_match") {
                body = "Not a match";
            } else if (data.reason === "timeout") {
                body = "Timed out";
            } else {
                body = "Try again with the password";
            }
            urgency = "critical";
            expire = 4000;
        }

        if (!summary) return;

        Notifications.notifyInternal({
            appName: "Face ID",
            summary: summary,
            body: body,
            urgency: urgency,
            expireTimeout: expire,
            replaceKey: root.authReplaceKey,
            popup: true
        });
    }

    // ---- daemon child process ----
    Process {
        id: daemonProcess
        command: ["python3", root.daemonPath]
        running: false // started lazily from tick()

        stderr: SplitParser {
            onRead: (data) => {
                if (!data) return;
                console.log("[linux-faceid-daemon]", data);
            }
        }

        onExited: (exitCode, exitStatus) => {
            root.started = false;
            root.processRunning = false;
            if (root.backend) {
                root.backend = false;
                root.pushMessage("error", "Face ID backend exited unexpectedly (" + exitCode + ")");
            }
        }
    }

    function applyState(data) {
        root.fps             = Number(data.fps) || 0;
        root.faces           = Number(data.faces) || 0;
        root.faceDetected    = !!data.faceDetected;
        root.recognizing     = !!data.recognizing;
        root.recognized      = !!data.recognized;
        root.score           = data.score === null || data.score === undefined ? -1 : Number(data.score);
        root.threshold       = data.threshold === null || data.threshold === undefined ? root.threshold : Number(data.threshold);
        root.enrolled        = !!data.enrolled;
        root.enrolling       = !!data.enrolling;
        root.enrollProgress  = Number(data.enrollProgress) || 0;
        root.enrollTotal     = Number(data.enrollTotal) || root.enrollTotal;
        root.cameraAvailable = !!data.cameraAvailable;
        root.camera          = !!data.camera;
        root.watching        = !!data.watching;
        root.backend         = data.backend !== undefined ? !!data.backend : root.backend;
        root.errorMessage    = data.error || "";
    }
}