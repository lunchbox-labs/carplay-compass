# Collect Diagnostics for Support

In Settings › Diagnostics, turn on **Debug Mode** before reproducing an issue.
While it is on, **Export Diagnostics** opens the share sheet with a JSON log;
**Clear Logs** deletes the current log without turning Debug Mode off.

Turning Debug Mode off stops collection, clears stored logs and hides both
buttons. Export first if you want to keep a copy. Files already saved or shared
elsewhere are outside the app’s control.

Logs contain local timing events for the Live Activity and full-screen CarPlay,
not coordinates or bearings. They help investigate update requests but do not
prove that a display was visible or refreshed. Temporary export files are removed
when the share sheet closes; the app reports cleanup failures.
