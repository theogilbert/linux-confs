/*
 * This script defines shortcuts to toggle the focus on specific applications.
*/

function toggleFocus(desktopFileName) {
    var allClients = workspace.clientList();
    var client = allClients.find((client) => client.desktopFileName == desktopFileName);

    if (client === undefined)
        return;

    if (client.active) {
        client.minimized = true;
    }
    else {
        workspace.activeClient = client;
    }
}

registerShortcut(
    "ToggleKonsole", "ToggleKonsole", "Meta+M",
    () => toggleFocus("org.kde.konsole")
);
registerShortcut(
    "ToggleFirefox", "ToggleFirefox", "Meta+F",
    () => toggleFocus("firefox")
);
