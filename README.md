# utils
random tools and scripts


## copy-as-markdown-link
Unzip the file. On your Fedora machine: unzip copy-as-markdown-link.zip.
In Brave, open brave://extensions in the address bar.
Turn on Developer mode (toggle in the top-right corner).
Click Load unpacked.
Select the copy-as-markdown-link folder, the one that contains manifest.json and background.js, not the zip itself.

The extension should now appear in the list. If it shows an error, check that you picked the inner folder and that both files are directly inside it.

Things to know:

Don’t move or delete the folder afterwards. Brave loads the extension from that location, so removing it disables the extension.
To change the Alt+Shift+C shortcut, open brave://extensions/shortcuts.
Brave may show a “Disable developer mode extensions” notice on restart. You can ignore it or dismiss it. It won’t remove the extension.
After you edit background.js, click the reload icon on the extension’s card at brave://extensions to apply the change.
If the right-click entry doesn’t appear on a tab that was already open, reload that tab once.
