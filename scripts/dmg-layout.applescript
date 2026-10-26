-- scripts/dmg-layout.applescript — make-dmg-manual.sh runs it on the writable image, mounted at the path it is given.
--
-- PRD P1 15: the DMG opens as one window — MetaWhisp on the left, Applications on the right, the arrow of
-- Resources/dmg-background.png between them, at the icon centres the background is drawn for (160 and 500, at 170).
-- Finder writes what it shows into the volume's .DS_Store, which the compressed image keeps. The volume is named by
-- its mount point, never by its name, so another volume called MetaWhisp is never touched.

on run argv
	set mountPath to item 1 of argv
	tell application "Finder"
		set dmg to (POSIX file mountPath) as alias
		open dmg
		set dmgWindow to container window of dmg
		set current view of dmgWindow to icon view
		set toolbar visible of dmgWindow to false
		set statusbar visible of dmgWindow to false
		set bounds of dmgWindow to {200, 120, 860, 520}
		set viewOptions to icon view options of dmgWindow
		set arrangement of viewOptions to not arranged
		set icon size of viewOptions to 96
		set text size of viewOptions to 12
		set background picture of viewOptions to ((POSIX file (mountPath & "/.background/background.png")) as alias)
		set position of item "MetaWhisp.app" of dmg to {160, 170}
		set position of item "Applications" of dmg to {500, 170}
		update dmg without registering applications
		delay 1
		close dmgWindow
	end tell
end run
