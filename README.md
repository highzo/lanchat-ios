# LANChat iOS（局域网聊天 iPhone 版）

iPhone 原生 App：手机自己就是一台独立设备（自带 HTTP 服务 8090 端口 + UDP 发现 + SQLite 数据库），
与电脑版 / 安卓版完全互通。界面复用网页版（内嵌 WKWebView），聊天数据存在 App 沙盒里。

## 目录结构

```
project.yml              XcodeGen 工程描述
Sources/
  AppDelegate.swift      应用入口
  WebViewController.swift  WKWebView 界面 + 文件下载分享面板
  ChatService.swift      核心业务（发现/消息/文件/群聊），接口与电脑版一致
  HTTPServer.swift       Network.framework 实现的 HTTP 服务器
  Discovery.swift        UDP 广播发现（52347 端口，协议 lanchat1）
  Store.swift            SQLite 持久化（表结构与电脑版一致）
Resources/
  index.html             聊天界面（与安卓版同一份）
  icon-*.png             应用图标
.github/workflows/build-ios.yml   GitHub Actions 云编译出 IPA
```

## 出 IPA（不需要 Mac）

1. 把本目录推到 GitHub（public 仓库 Actions 免费）
2. Actions 会自动用 macOS 机器编译出 `LANChat-unsigned.ipa`（未签名）
3. Windows 上用 **Sideloadly**（https://sideloadly.io）给 IPA 签名并装进 iPhone：
   - 数据线连 iPhone，打开 Sideloadly，拖入 IPA
   - 输入 Apple ID（免费账号即可，有开发者账号更好）
   - 点 Start，完成后 iPhone 上「设置 → 通用 → VPN与设备管理」信任证书
   - 免费 Apple ID 签名 7 天有效，到期重签；付费开发者账号 1 年有效

## 上架 App Store 还需要

- 付费开发者账号（688 元/年）
- 在 Mac/云上用分发证书签名（或继续用 CI，把证书上传为 Secrets）
- 中国区 App Store 需要 APP 备案（工信部）
- 纯 WKWebView 壳有被 4.2（Minimum Functionality）拒绝的风险，上架前建议换成原生界面
