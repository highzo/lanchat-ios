import UIKit
import WebKit

/// 全屏 WKWebView，加载本机 8090 端口的聊天界面；
/// 点击文件/图片下载链接时弹出系统分享面板（可存到"文件"、微信等）。
final class WebViewController: UIViewController, WKNavigationDelegate, WKScriptMessageHandler {

    private var webView: WKWebView!
    /// 上次下载到的临时文件（分享面板引用期间保持）
    private var pendingShareURL: URL?

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        // 网页「我的 → 设置」里的权限按钮，通过这个桥跳到系统设置页
        config.userContentController.add(self, name: "lanchat")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.scrollView.bounces = false
        view = webView
    }

    // MARK: - 网页 → 原生

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "lanchat",
              let body = message.body as? [String: Any],
              let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "openNotificationSettings", "openBatterySettings",
             "openAutoStartSettings", "openSettings":
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        default:
            break
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadPage()
        // 掉线/白屏时下拉重载
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func reload() {
        if webView.url == nil { loadPage() }
    }

    private func loadPage() {
        if let url = URL(string: "http://127.0.0.1:\(ChatService.shared.httpPort)/") {
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }

    // MARK: - 下载拦截

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        if let url, url.path == "/api/file",
           let fid = URLComponents(url: url, resolvingAgainstBaseURL: false)?
               .queryItems?.first(where: { $0.name == "id" })?.value {
            decisionHandler(.cancel)
            downloadAndShare(fileID: fid)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target="_blank" 的下载链接也拦下来
        if let url = navigationAction.request.url, url.path == "/api/file",
           let fid = URLComponents(url: url, resolvingAgainstBaseURL: false)?
               .queryItems?.first(where: { $0.name == "id" })?.value {
            downloadAndShare(fileID: fid)
            return nil
        }
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // 服务可能还没起来，稍后重试
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            if self.webView.url == nil { self.loadPage() }
        }
    }

    private func downloadAndShare(fileID: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let f = self.chatStoreFile(fileID),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: f.path)) else {
                DispatchQueue.main.async { self.toast("文件不存在") }
                return
            }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(f.name)
            try? FileManager.default.removeItem(at: tmp)
            do { try data.write(to: tmp) } catch {
                DispatchQueue.main.async { self.toast("保存失败") }
                return
            }
            DispatchQueue.main.async {
                self.pendingShareURL = tmp
                let vc = UIActivityViewController(activityItems: [tmp], applicationActivities: nil)
                if let pop = vc.popoverPresentationController {
                    pop.sourceView = self.view
                    pop.sourceRect = CGRect(x: self.view.bounds.midX,
                                            y: self.view.bounds.midY, width: 1, height: 1)
                }
                self.present(vc, animated: true)
            }
        }
    }

    private func chatStoreFile(_ fid: String) -> (name: String, path: String)? {
        Store.shared.fileByID(fid)
    }

    private func toast(_ msg: String) {
        let label = UILabel()
        label.text = msg
        label.textColor = .white
        label.backgroundColor = UIColor(white: 0, alpha: 0.75)
        label.textAlignment = .center
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.frame = CGRect(x: 0, y: 0, width: 200, height: 40)
        label.center = CGPoint(x: view.bounds.midX, y: view.bounds.height - 90)
        view.addSubview(label)
        UIView.animate(withDuration: 0.3, delay: 1.6, options: [],
                       animations: { label.alpha = 0 }) { _ in label.removeFromSuperview() }
    }
}
