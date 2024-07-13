/*
 * This script defines shortcuts to toggle the focus on specific applications.
*/

function toggleFocus(resourceClass) {
    var allWindows = workspace.windowList();
    var appWindow = allWindows.find((win) => win.resourceClass == resourceClass);

    if (appWindow === undefined)
        return;

    if (appWindow.active) {
        appWindow.minimized = true;
    }
    else {
        workspace.activeWindow = appWindow;
    }
}

registerShortcut(
    "ToggleKonsole", "ToggleKonsole", "Meta+M",
    () => toggleFocus("org.kde.konsole")
);
registerShortcut(
    "ToggleFirefox", "ToggleFirefox", "Meta+F",
    () => toggleFocus("org.mozilla.firefox")
);
