import QtQuick

Item {
    property var target: null
    property string signalName: ""
    property int count: 0
    property bool valid: true
    function clear() { count = 0; }
    function wait(timeout) { return true; }
}
