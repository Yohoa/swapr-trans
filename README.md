# SwaprTrans ⚡

<p align="center">
  <b>简体中文</b> | <b><a href="README_en.md">English</a></b>
</p>

<p align="center">
  <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/platform-macOS%2014.2%2B-lightgrey.svg" alt="Platform"></a>
  <a href="https://swift.org"><img src="https://img.shields.io/badge/language-Swift%206-orange.svg" alt="Language"></a>
  <a href="https://developer.apple.com/xcode/swiftui/"><img src="https://img.shields.io/badge/framework-AppKit%20%7C%20SwiftUI-blue.svg" alt="Framework"></a>
  <a href="https://github.com/linrol/swapr-trans/releases"><img src="https://img.shields.io/badge/binary-Universal%202%20(Intel%20%2B%20M--chip)-success.svg" alt="Universal 2"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License"></a>
</p>

**SwaprTrans** 是一款专为 macOS 设计的极致轻量、纯原生的**全局划词翻译与原位覆写工具**。
彻底打破“划词 -> 复制 -> 切换窗口 -> 粘贴 -> 翻译 -> 再复制回来”的传统低效链条。

> **🚀 选词空格即翻，回车原地覆写！**  
> 在任意聊天框（Teams、Slack、微信、邮件、终端）中敲好文字，划选后按默认触发键 **`Space` 空格键** 唤起轻盈翻译浮窗；满意后轻敲一下 **`Enter` 回车键**，原文即可平滑蜕变为地道外文！

---

## ✨ 核心特性

- ** Apple 官方原生端侧模型（macOS 15+ 深度集成）**：
  - **端侧芯片推理·无需联网**：基于 Apple 官方 `Translation.framework` 原生神经引擎驱动，零网络依赖；
  - **100% 隐私安全**：商业机密沟通不上云，纯本地芯片运算；
- **三引擎智能协同与容灾**：
  - **Apple (Native)**：系统级原生端侧引擎；
  - **Microsoft Edge**：免 Key 专线极速互译通道；
  - **Google Translate**：多链路自动降级兜底；
- **双向智能语种识别**：中英混合输入自动侦测，中文自动转英文、外文自动转中文；
- **绝不夺取系统焦点的毛玻璃浮窗**：浮窗浮起时，当前编辑窗口的光标与选区完好如初；
- **纯原生零负载**：纯 Swift + SwiftUI + AppKit 重构，内存仅微量常驻，体积不足 1MB。

---

## 📦 作为 Swift Package (SPM) 库引用

`SwaprTrans` 不仅是一个独立的 macOS 菜单栏应用，它的核心能力以 `SwaprTransKit` 完整对外开放。你可以在其他 macOS 应用程序中直接引入：

```swift
// Package.swift
dependencies: [
    .package(url: "https://gitee.com/linrol/swapr-trans.git", from: "1.0.0")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "SwaprTransKit", package: "swapr-trans")
        ]
    )
]
```

在你的 App 中直接调用与嵌入：
```swift
import SwaprTransKit

// 启动服务
SwaprTransConfig.shared.isEnabled = true

// 在 SwiftUI 菜单或设置窗口中直接嵌入开箱即用的设置面板
SwaprTransSettingsView()
```

---

## 📥 下载与安装

### 方式一：下载 Release 安装包（推荐）
前往 [Releases 页面](https://github.com/linrol/swapr-trans/releases) 下载最新版本的 `SwaprTrans-x.x.x.dmg`：
1. 打开 DMG 文件；
2. 将 `SwaprTrans.app` 拖入 `Applications`（应用程序目录）；
3. 首次启动：由于当前为个人签名，首次打开如遇 Gatekeeper 拦截提示，请在 Finder 中**右键点击 SwaprTrans.app -> 点击「打开」**；
4. 授权：首次使用时请按系统提示授予 **辅助功能 (Accessibility)** 权限，以支持实时光标侦测与选区原地覆写；
5. **Apple 原生端侧模型提示**：若选用 Apple 原生端侧翻译模型（macOS 15+），首次使用时系统会弹窗提示下载离线语言包，亦可在 **「系统设置」→「通用」→「语言与地区」→「翻译语言」** 中提前下载需要的离线语言包，完成后即可完全脱网离线运行。

---

## 🛠️ 本地构建与开发

```bash
# 本地编译并就地安装至 /Applications
./scripts/install.sh
```

## ⚖️ 许可证
本项目基于 [MIT License](LICENSE) 开源。

