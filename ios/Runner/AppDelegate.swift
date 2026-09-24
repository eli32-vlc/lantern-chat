import AVFoundation
import BackgroundTasks
import Flutter
import UIKit
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var backgroundChannel: FlutterMethodChannel?
  private var audioChannel: FlutterMethodChannel?
  private var webPreviewChannel: FlutterMethodChannel?
  private var webPreviewController: LanternWebPreviewController?

  private let refreshTaskIdentifier = "com.lantern.lanternChat.refresh"
  private let processingTaskIdentifier = "com.lantern.lanternChat.processing"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // The project uses UIScene. Flutter's implicit engine and its messenger
    // are not guaranteed to exist in application:didFinishLaunching, so all
    // Flutter channels are installed in didInitializeImplicitFlutterEngine.
    registerBackgroundTasks()
    scheduleBackgroundTasks()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()

    backgroundChannel = FlutterMethodChannel(
      name: "com.lantern/service",
      binaryMessenger: messenger)
    backgroundChannel?.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else {
        result(FlutterError(code: "APP_UNAVAILABLE", message: "App delegate unavailable", details: nil))
        return
      }
      switch call.method {
      case "startService":
        self.scheduleBackgroundTasks()
        result(true)
      case "stopService":
        self.cancelBackgroundTasks()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    audioChannel = FlutterMethodChannel(
      name: "com.lantern/audio",
      binaryMessenger: messenger)
    audioChannel?.setMethodCallHandler { (call, result) in
      switch call.method {
      case "enableBackgroundAudio":
        do {
          try AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .default,
            options: [.mixWithOthers]
          )
          try AVAudioSession.sharedInstance().setActive(true)
          result(true)
        } catch {
          result(FlutterError(
            code: "AUDIO_SESSION_ERROR",
            message: "Failed to configure audio session: \(error.localizedDescription)",
            details: nil))
        }
      case "disableBackgroundAudio":
        do {
          try AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
          )
          result(true)
        } catch {
          result(FlutterError(
            code: "AUDIO_SESSION_ERROR",
            message: "Failed to deactivate audio session: \(error.localizedDescription)",
            details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    webPreviewChannel = FlutterMethodChannel(
      name: "com.lantern/web",
      binaryMessenger: messenger)
    webPreviewChannel?.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else {
        result(FlutterError(code: "APP_UNAVAILABLE", message: "App delegate unavailable", details: nil))
        return
      }
      guard call.method == "openPreview" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any],
            let urlString = args["url"] as? String,
            let url = URL(string: urlString) else {
        result(FlutterError(code: "INVALID_URL", message: "A valid preview URL is required", details: nil))
        return
      }
      self.presentWebPreview(url, result: result)
    }
  }

  // MARK: - Distributed Web Preview

  private func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = scenes.flatMap { $0.windows }
    let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first
    var controller = window?.rootViewController
    while let presented = controller?.presentedViewController {
      controller = presented
    }
    if let navigation = controller as? UINavigationController {
      return navigation.visibleViewController ?? navigation
    }
    if let tabs = controller as? UITabBarController {
      return tabs.selectedViewController ?? tabs
    }
    return controller
  }

  private func presentWebPreview(_ url: URL, result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        result(FlutterError(code: "APP_UNAVAILABLE", message: "App delegate unavailable", details: nil))
        return
      }
      if let existing = self.webPreviewController, existing.isPresented {
        existing.load(url)
        result(true)
        return
      }
      guard let presenter = self.topViewController() else {
        result(FlutterError(code: "NO_VIEW_CONTROLLER", message: "No active view controller", details: nil))
        return
      }
      let controller = LanternWebPreviewController(url: url)
      controller.load(url)
      controller.onFinish = { [weak self, weak controller] in
        controller?.dismiss(animated: true)
        if self?.webPreviewController === controller {
          self?.webPreviewController = nil
        }
      }
      controller.modalPresentationStyle = .fullScreen
      self.webPreviewController = controller
      presenter.present(controller, animated: true) {
        result(true)
      }
    }
  }

  // MARK: - Background Tasks

  private func registerBackgroundTasks() {
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: refreshTaskIdentifier,
      using: nil
    ) { [weak self] task in
      self?.handleRefresh(task as! BGAppRefreshTask)
    }
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: processingTaskIdentifier,
      using: nil
    ) { [weak self] task in
      self?.handleProcessing(task as! BGProcessingTask)
    }
  }

  private func scheduleBackgroundTasks() {
    let refresh = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
    refresh.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
    try? BGTaskScheduler.shared.submit(refresh)

    let processing = BGProcessingTaskRequest(identifier: processingTaskIdentifier)
    processing.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    processing.requiresNetworkConnectivity = true
    processing.requiresExternalPower = false
    try? BGTaskScheduler.shared.submit(processing)
  }

  private func cancelBackgroundTasks() {
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshTaskIdentifier)
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processingTaskIdentifier)
  }

  private func handleRefresh(_ task: BGAppRefreshTask) {
    scheduleBackgroundTasks()
    var completed = false
    let finish: (Bool) -> Void = { success in
      guard !completed else { return }
      completed = true
      task.setTaskCompleted(success: success)
    }
    task.expirationHandler = { finish(false) }
    backgroundChannel?.invokeMethod("onBackgroundFetch", arguments: nil) { _ in
      finish(true)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
      finish(false)
    }
  }

  private func handleProcessing(_ task: BGProcessingTask) {
    scheduleBackgroundTasks()
    var completed = false
    let finish: (Bool) -> Void = { success in
      guard !completed else { return }
      completed = true
      task.setTaskCompleted(success: success)
    }
    task.expirationHandler = { finish(false) }
    backgroundChannel?.invokeMethod("onBackgroundFetch", arguments: nil) { _ in
      finish(true)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
      finish(false)
    }
  }

  // MARK: - Legacy Background Fetch

  override func application(
    _ application: UIApplication,
    performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    var completed = false
    let finish: (UIBackgroundFetchResult) -> Void = { result in
      guard !completed else { return }
      completed = true
      completionHandler(result)
    }
    backgroundChannel?.invokeMethod("onBackgroundFetch", arguments: nil) { _ in
      finish(.newData)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
      finish(.noData)
    }
  }
}

private final class LanternWebPreviewController: UIViewController, WKNavigationDelegate {
  private let webView: WKWebView
  private let initialURL: URL
  var onFinish: (() -> Void)?

  var isPresented: Bool {
    presentingViewController != nil || viewIfLoaded?.window != nil
  }

  init(url: URL) {
    initialURL = url
    let configuration = WKWebViewConfiguration()
    configuration.allowsInlineMediaPlayback = true
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init(nibName: nil, bundle: nil)
    webView.navigationDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    webView.isOpaque = false
    webView.backgroundColor = .systemBackground
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    let toolbar = UIView()
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    toolbar.backgroundColor = .secondarySystemBackground

    let closeButton = UIButton(type: .system)
    closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
    closeButton.accessibilityLabel = "Close preview"
    closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

    let reloadButton = UIButton(type: .system)
    reloadButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
    reloadButton.accessibilityLabel = "Reload preview"
    reloadButton.addTarget(self, action: #selector(reloadTapped), for: .touchUpInside)

    let titleLabel = UILabel()
    titleLabel.text = "Lantern Files"
    titleLabel.font = .preferredFont(forTextStyle: .headline)
    titleLabel.textAlignment = .center

    let stack = UIStackView(arrangedSubviews: [closeButton, titleLabel, reloadButton])
    stack.axis = .horizontal
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false
    closeButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
    reloadButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
    toolbar.addSubview(stack)

    webView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(toolbar)
    view.addSubview(webView)
    NSLayoutConstraint.activate([
      toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      toolbar.heightAnchor.constraint(equalToConstant: 52),
      stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
      stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
      stack.topAnchor.constraint(equalTo: toolbar.topAnchor),
      stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
      webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
      webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  @objc private func closeTapped() {
    close()
  }

  @objc private func reloadTapped() {
    load(webView.url ?? initialURL)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if webView.url == nil { load(initialURL) }
  }

  func load(_ url: URL) {
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 10
    webView.load(request)
  }

  private func close() {
    if let onFinish = onFinish {
      onFinish()
    } else {
      dismiss(animated: true)
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    presentError(error)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    presentError(error)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    webView.backgroundColor = .systemBackground
  }

  func webView(
    _ webView: WKWebView,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    // This is an unauthenticated local HTTP server, so default handling is
    // sufficient. No TLS or password challenge should be accepted blindly.
    completionHandler(.performDefaultHandling, nil)
  }

  private func presentError(_ error: Error) {
    let urlText = webView.url?.absoluteString ?? initialURL.absoluteString
    let alert = UIAlertController(
      title: "Preview unavailable",
      message: "\(error.localizedDescription)\n\nURL: \(urlText)",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
      guard let self = self, let url = self.webView.url else { return }
      self.load(url)
    })
    alert.addAction(UIAlertAction(title: "Close", style: .cancel) { [weak self] _ in
      self?.close()
    })
    present(alert, animated: true)
  }
}
