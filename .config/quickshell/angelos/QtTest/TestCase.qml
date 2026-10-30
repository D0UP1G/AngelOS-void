import QtQuick

Item {
    property string name: ""
    property bool when: true
    function verify(condition, message) {}
    function compare(actual, expected, message) {}
    function tryVerify(fn, timeout, message) {}
    function tryCompare(obj, prop, expected, timeout, message) {}
    function wait(ms) {}
    function skip(message) {}
    function fail(message) {}
    function expectFail(tag, comment) {}
}
