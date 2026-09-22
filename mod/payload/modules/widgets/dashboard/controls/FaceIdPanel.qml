pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.config
import qs.modules.components
import qs.modules.services
import qs.modules.theme

// Linux Face ID panel.
// Shows face-detection / recognition state, similarity score and enrollment
// progress, and drives the backend through the FaceIdService singleton.
// The panel only talks over the local socket — no frames ever leave the box.
Item {
    id: root

    property int maxContentWidth: 480
    readonly property int contentWidth: Math.min(width, maxContentWidth)
    readonly property real sideMargin: (width - contentWidth) / 2

    // The daemon only opens the camera while at least one consumer is
    // watching. This panel is the only one, so the pairing is 1:1.
    Component.onCompleted: FaceIdService.watchOn()
    Component.onDestruction: FaceIdService.watchOff()

    readonly property bool busy: FaceIdService.enrolling
    readonly property real scoreRatio: {
        const s = FaceIdService.score;
        if (s < 0) return 0;
        return Math.max(0, Math.min(1, s));
    }
    readonly property string statusText: {
        if (!FaceIdService.backend) return "Backend not running";
        if (FaceIdService.errorMessage) return FaceIdService.errorMessage;
        if (FaceIdService.enrolling)
            return "Enrolling " + FaceIdService.enrollProgress + " / " + FaceIdService.enrollTotal;
        if (!FaceIdService.camera) return "Camera off";
        if (!FaceIdService.faceDetected) return "No face detected";
        if (!FaceIdService.recognized && FaceIdService.score >= 0 && FaceIdService.enrolled)
            return "Not recognized";
        if (FaceIdService.recognized) return "Recognized";
        return "Watching";
    }
    readonly property color statusColor: {
        if (FaceIdService.errorMessage || !FaceIdService.backend) return Colors.error;
        if (FaceIdService.enrolling) return Colors.warning;
        if (!FaceIdService.recognized && FaceIdService.recognizing) return Colors.warning;
        if (FaceIdService.recognized) return Colors.success;
        return Colors.outline;
    }
    readonly property string lastMessage: {
        const m = FaceIdService.messages;
        return m.length > 0 ? m[m.length - 1].text : "";
    }
    readonly property string lastMessageLevel: {
        const m = FaceIdService.messages;
        return m.length > 0 ? m[m.length - 1].level : "";
    }
    readonly property color lastMessageColor: {
        if (lastMessageLevel === "error") return Colors.error;
        if (lastMessageLevel === "warn") return Colors.warning;
        if (lastMessageLevel === "success") return Colors.success;
        return Colors.outline;
    }

    component ActionButton: Button {
        id: action
        property bool primary: false
        property bool destructive: false

        implicitHeight: 34
        leftPadding: 14
        rightPadding: 14
        opacity: enabled ? 1 : 0.45

        readonly property bool engaged: hovered || down || activeFocus
        readonly property string surface: action.primary
            ? (action.engaged ? "primaryfocus" : "primary")
            : (action.engaged ? (action.destructive ? "error" : "secondary") : "focus")

        background: StyledRect {
            variant: action.surface
            radius: Styling.radius(-2)
            enableShadow: false
        }

        contentItem: Text {
            text: action.text
            font.family: Config.theme.font
            font.pixelSize: Styling.fontSize(-1)
            font.weight: action.primary ? Font.DemiBold : Font.Medium
            color: action.primary || action.engaged ? Styling.srItem(action.surface)
                : action.destructive ? Colors.error
                : Colors.overBackground
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }

    component MetaRow: RowLayout {
        id: meta
        property string label: ""
        property string value: ""
        property bool mono: false
        default property alias trailing: trailingSlot.data

        Layout.fillWidth: true
        spacing: 10

        Text {
            Layout.preferredWidth: 118
            Layout.alignment: Qt.AlignTop
            text: meta.label
            font.family: Config.theme.font
            font.pixelSize: Styling.fontSize(-2)
            color: Colors.outline
            wrapMode: Text.Wrap
        }

        Text {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            visible: meta.value !== ""
            text: meta.value
            font.family: meta.mono ? Config.theme.monoFont : Config.theme.font
            font.pixelSize: Styling.fontSize(-2)
            color: Colors.overBackground
            wrapMode: Text.WrapAnywhere
        }

        RowLayout {
            id: trailingSlot
            Layout.alignment: Qt.AlignVCenter
            spacing: 6
        }
    }

    Flickable {
        id: mainFlickable
        anchors.fill: parent
        contentHeight: mainColumn.implicitHeight + 8
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
        }

        ColumnLayout {
            id: mainColumn
            width: root.contentWidth
            x: Math.max(0, (mainFlickable.width - width) / 2)
            spacing: 10

            PanelTitlebar {
                title: "Face ID"
                statusText: root.statusText
                statusColor: root.statusColor

                actions: [
                    {
                        icon: Icons.shieldCheck,
                        tooltip: "Verify",
                        enabled: FaceIdService.backend && FaceIdService.enrolled
                            && FaceIdService.cameraAvailable && !root.busy,
                        onClicked: function () { FaceIdService.verify(); }
                    }
                ]
            }

            StyledRect {
                Layout.fillWidth: true
                Layout.preferredHeight: signRow.implicitHeight + 34
                variant: "pane"
                radius: Styling.radius(0)

                RowLayout {
                    id: signRow
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 12
                    spacing: 12

                    Text {
                        text: root.statusColor === Colors.success ? Icons.shieldCheck
                            : root.busy ? Icons.arrowCounterClockwise
                            : root.statusColor === Colors.error ? Icons.alert
                            : Icons.shield
                        font.family: Icons.font
                        font.pixelSize: 20
                        color: root.statusColor
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2

                        Text {
                            Layout.fillWidth: true
                            text: root.statusText
                            font.family: Config.theme.font
                            font.pixelSize: Styling.fontSize(0)
                            font.weight: Font.DemiBold
                            color: Colors.overBackground
                            wrapMode: Text.Wrap
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: FaceIdService.faceDetected && FaceIdService.score >= 0
                            text: "Similarity " + FaceIdService.score.toFixed(3)
                                + " · threshold " + FaceIdService.threshold.toFixed(3)
                            font.family: Config.theme.monoFont
                            font.pixelSize: Styling.fontSize(-2)
                            color: Colors.outline
                        }
                    }

                    Text {
                        Layout.alignment: Qt.AlignVCenter
                        text: FaceIdService.recognized ? "OK" : ""
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-1)
                        font.weight: Font.DemiBold
                        color: Colors.success
                        visible: FaceIdService.recognized
                    }
                }
            }

            // Recognition score bar, normalized 0..1 with a tick at threshold.
            StyledRect {
                visible: FaceIdService.enrolled && !FaceIdService.enrolling
                    && FaceIdService.faceDetected && FaceIdService.score >= 0
                Layout.fillWidth: true
                Layout.preferredHeight: scoreMeta.implicitHeight + 24
                variant: "common"
                radius: Styling.radius(-2)
                enableShadow: false

                ColumnLayout {
                    id: scoreMeta
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 10
                    spacing: 6

                    MetaRow {
                        label: "Detection"
                        value: (FaceIdService.faces > 1 ? FaceIdService.faces + " faces" : "Face found")
                            + " · " + FaceIdService.fps.toFixed(0) + " fps"
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 6
                        radius: 3
                        color: Colors.surfaceBright

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.max(2, parent.width * root.scoreRatio)
                            height: parent.height
                            radius: parent.radius
                            color: FaceIdService.recognized ? Colors.success : Colors.warning
                        }

                        Rectangle {
                            x: parent.width * Math.min(1, Math.max(0, FaceIdService.threshold))
                                - width / 2
                            y: 0
                            width: 2
                            height: parent.height
                            color: Colors.outline
                            opacity: 0.8
                        }
                    }

                    Text {
                        Layout.alignment: Qt.AlignRight
                        text: "Similarity " + FaceIdService.score.toFixed(3)
                            + " / " + FaceIdService.threshold.toFixed(3)
                        font.family: Config.theme.monoFont
                        font.pixelSize: Styling.fontSize(-2)
                        color: Colors.outline
                    }
                }
            }

            // Enrollment state + controls.
            StyledRect {
                Layout.fillWidth: true
                Layout.preferredHeight: enrollColumn.implicitHeight + 28
                variant: "pane"
                radius: Styling.radius(0)

                ColumnLayout {
                    id: enrollColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 14
                    spacing: 8

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2

                            Text {
                                Layout.fillWidth: true
                                text: root.busy ? "Enrollment in progress"
                                    : FaceIdService.enrolled ? "Face profile enrolled"
                                    : "No face profile enrolled"
                                font.family: Config.theme.font
                                font.pixelSize: Styling.fontSize(-1)
                                font.weight: Font.DemiBold
                                color: Colors.overBackground
                                wrapMode: Text.Wrap
                            }

                            Text {
                                Layout.fillWidth: true
                                text: root.busy
                                    ? "Look straight at the camera while the frames are collected."
                                    : FaceIdService.enrolled
                                    ? "Re-enroll to refresh the stored embedding."
                                    : "Enroll now so verification has a profile to compare against."
                                font.family: Config.theme.font
                                font.pixelSize: Styling.fontSize(-2)
                                color: Colors.outline
                                wrapMode: Text.Wrap
                            }
                        }

                        Text {
                            Layout.alignment: Qt.AlignVCenter
                            text: FaceIdService.enrolled ? Icons.shieldCheck : Icons.shield
                            font.family: Icons.font
                            font.pixelSize: 20
                            color: FaceIdService.enrolled ? Colors.success : Colors.outline
                        }
                    }

                    Rectangle {
                        visible: root.busy
                        Layout.fillWidth: true
                        Layout.preferredHeight: 5
                        radius: 2
                        color: Colors.surfaceBright

                        Rectangle {
                            width: Math.max(2, parent.width
                                * (FaceIdService.enrollProgress / Math.max(1, FaceIdService.enrollTotal)))
                            height: parent.height
                            radius: parent.radius
                            color: Colors.warning
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: 2
                        spacing: 8

                        ActionButton {
                            text: root.busy ? "Cancel"
                                : FaceIdService.enrolled ? "Re-enroll"
                                : "Enroll"
                            primary: !root.busy
                            destructive: root.busy
                            enabled: FaceIdService.cameraAvailable
                            onClicked: root.busy ? FaceIdService.cancel() : FaceIdService.enroll()
                        }

                        ActionButton {
                            text: "Clear profile"
                            destructive: true
                            visible: FaceIdService.enrolled && !root.busy
                            enabled: FaceIdService.cameraAvailable
                            onClicked: FaceIdService.clear()
                        }

                        Item { Layout.fillWidth: true }

                        Text {
                            visible: root.busy
                            text: FaceIdService.enrollProgress + " / " + FaceIdService.enrollTotal
                            font.family: Config.theme.monoFont
                            font.pixelSize: Styling.fontSize(-2)
                            color: Colors.outline
                        }
                    }
                }
            }

            // Latest daemon message (parrots success/error/warn notices).
            StyledRect {
                visible: root.lastMessage !== ""
                Layout.fillWidth: true
                Layout.preferredHeight: msgRow.implicitHeight + 20
                variant: "common"
                radius: Styling.radius(-2)
                enableShadow: false

                RowLayout {
                    id: msgRow
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 10
                    spacing: 8

                    Text {
                        Layout.alignment: Qt.AlignTop
                        text: {
                            if (root.lastMessageLevel === "error") return Icons.alert;
                            if (root.lastMessageLevel === "warn") return Icons.alert;
                            if (root.lastMessageLevel === "success") return Icons.accept;
                            return Icons.info;
                        }
                        font.family: Icons.font
                        font.pixelSize: 14
                        color: root.lastMessageColor
                    }

                    Text {
                        Layout.fillWidth: true
                        text: root.lastMessage
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-2)
                        color: root.lastMessageColor
                        wrapMode: Text.Wrap
                    }
                }
            }
        }
    }
}