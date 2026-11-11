import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // The benchmark grid (200 x 60 cells) needs about 1400 x 960 logical
    // pixels; the template's 800 x 600 window cannot hold it. Ask for the
    // same size as the Linux runner (1800 x 1100), clamped to the screen's
    // visible area (GitHub's macOS runners have a 1920 x 1080 display).
    var frame = NSRect(x: 0, y: 0, width: 1800, height: 1100)
    if let visible = (self.screen ?? NSScreen.main)?.visibleFrame {
      frame.size.width = min(frame.size.width, visible.width)
      frame.size.height = min(frame.size.height, visible.height)
      frame.origin = visible.origin
    }
    self.setFrame(frame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
