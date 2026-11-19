// The installer's progress window (osascript -l JavaScript progress.js <progress file>): a bar and the stage's text, read every half
// second from the file the installer writes ("N text" lines, N = 0..100); it closes itself at 100.
// Adapted from NFSU2Deadware's tools/dmg/progress.js (MIT).
ObjC.import('Cocoa');
function run(argv) {
  const file = argv[0];
  const app = $.NSApplication.sharedApplication;
  app.setActivationPolicy($.NSApplicationActivationPolicyRegular);
  const win = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
    $.NSMakeRect(0, 0, 480, 120), $.NSWindowStyleMaskTitled, $.NSBackingStoreBuffered, false);
  win.title = 'NFS Underground 2: installing';
  const label = $.NSTextField.labelWithString('Preparing');
  label.frame = $.NSMakeRect(20, 70, 440, 24);
  const bar = $.NSProgressIndicator.alloc.initWithFrame($.NSMakeRect(20, 35, 440, 20));
  bar.indeterminate = false; bar.minValue = 0; bar.maxValue = 100;
  win.contentView.addSubview(label); win.contentView.addSubview(bar);
  win.center; win.makeKeyAndOrderFront(null); app.activateIgnoringOtherApps(true);
  for (;;) {
    const s = $.NSString.stringWithContentsOfFileEncodingError(file, $.NSUTF8StringEncoding, null);
    if (!s.isNil()) {
      const lines = s.js.trim().split('\n'), last = lines[lines.length - 1] || '';
      const m = last.match(/^(\d+) (.*)$/);
      if (m) { bar.doubleValue = +m[1]; label.stringValue = m[2]; if (+m[1] >= 100) break; }
    }
    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.5));
  }
  $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(1.0));
}
