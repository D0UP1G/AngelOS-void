import QtQuick
import QtQml.Models

FunctionFilter {
    property string roleName: ""
    property var regExp: null
    function filter(row) {
        if (!regExp || !roleName) return true;
        return regExp.test(row[roleName] || "");
    }
}
