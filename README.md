# pocketbooktools.koplugin
The plugin is a revamped version of the pocketbooksync.koplugin with additional features. Allows syncing reading progress from KOReader with the PocketBook device database. Also adds support for the native PocketBook feature of showing the last page on startup.
## Removing read books from the collection
I usually add new books to my 'To Read' collection (via the Calibre and [connect-to-calibre.app](https://github.com/reuerendo/connect-to-calibre.app)). This option allows you to automatically remove finished books from the collection selected in the settings.
## Boot logo: Current page
This option must be enabled in the PocketBook device settings (not within KOReader). The plugin utilizes a native device function and requires no configuration.

However, in newer versions of KOReader, the necessary function has been removed from the file `/koreader/ffi/inkview_h.lua` and it must be manually added back into it.

Ensure that the line `int PageSnapshot();` is present in the `inkview_h.lua` file and add it if necessary.
## PocketBook Style
My attempt to bring the appearance of some interface components (like info messages, dialog boxes, context menus) closer to the native PocketBook style. *This functionality is under active development and currently only modifies a few components.*
