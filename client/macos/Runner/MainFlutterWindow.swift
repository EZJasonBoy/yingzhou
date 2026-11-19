import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // First launch: same size as on Windows. Afterwards the app restores where the user left the window.
    self.setContentSize(NSSize(width: 1360, height: 860))
    self.center()
    self.title = "映舟"
    self.collectionBehavior.insert(.fullScreenPrimary)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
