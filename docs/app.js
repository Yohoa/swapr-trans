(function () {
  "use strict";

  const strings = {
    zh: {
      pageTitle: "SwaprTrans · 选词即翻，回车原地覆写",
      brandBadge: "原地瞬译",
      navFeatures: "特性",
      navInstall: "安装",
      navSdk: "开发库",
      ctaDownload: "下载 DMG",

      // Hero
      eyebrow: "macOS 15+ 官方端侧驱动 · 选词瞬译",
      heroTitle1: "选词即翻，",
      heroTitle2: "回车原地覆写。",
      heroSub:
        "彻底告别切屏复制与反复粘贴。在任意输入框中划选文字，按下快捷键，轻敲一次回车键，原文即刻原子级蜕变为地道外文。",
      ctaDownloadHero: "下载 SwaprTrans v1.0.2 (DMG)",
      metaChip: " Apple 原生神经引擎",
      metaPrivacy: "100% 隐私·不上云",
      metaWeight: "轻量 < 2MB",

      // Demo Box
      demoTitle: "Teams / Slack 沉浸输入体验",
      editorPlaceholder: "把想去的地方排进每天的行程...",
      pill1: "✍️ 聊天输入 · 原地覆写",
      pill2: "📖 网页浏览 · 划词即翻",
      pill3: "✉️ 商务邮件 · 原地覆写",
      pill4: "💻 终端报错 · 查词对照",

      // Features
      feat1Title: " Apple 官方原生端侧模型",
      feat1Desc:
        "深度集成 macOS 15+ Translation.framework。纯芯片本地神经引擎离线运算，零网络依赖，商业机密与私密沟通 100% 安全。",
      feat2Title: "⚡️ 回车瞬间「原地覆写」",
      feat2Desc:
        "消灭多余的鼠标操作与复制粘贴。浮窗浮起后轻触 Enter 回车，原文直接替换为地道译文，光标位置平滑保持。",
      feat3Title: "🌐 三引擎智能容灾与自适应",
      feat3Desc:
        "默认 Apple 本地端侧推理；辅以 Microsoft Edge 极速免 Key 通道与 Google Translate 自动无感平滑兜底。",
      feat4Title: "🪟 焦点无损与开源 SwaprTransKit",
      feat4Desc:
        "纯 Swift 原生打造，常驻内存微量。浮窗绝不夺取焦点；核心 SwaprTransKit 作为 Swift Package 完全开源开放。",

      // Install
      installTitle: "快速安装与授权",
      installStep1: "下载 <strong>SwaprTrans-1.0.2.dmg</strong> 并将 App 拖拽至 <strong>Applications</strong>；",
      installStep2: "首次打开：若遇 Gatekeeper 提示，在访达中<strong>右键点击 App → 点击「打开」</strong>；",
      installStep3: "按系统提示授予<strong>「辅助功能」(Accessibility)</strong> 权限，即刻开启选词原地覆写体验。",
      btnDownloadBox: "下载 SwaprTrans-1.0.2.dmg (1.9MB)",

      // Footer
      footerText: "SwaprTrans · 专为 macOS 打造的极简原生选词瞬译与原地覆写工具",
    },

    en: {
      pageTitle: "SwaprTrans · Select to Translate, Enter to In-Place Rewrite",
      brandBadge: "In-Place Translator",
      navFeatures: "Features",
      navInstall: "Download",
      navSdk: "SPM SDK",
      ctaDownload: "Download DMG",

      // Hero
      eyebrow: "macOS 15+ Native On-Device Engine · Instant Translation",
      heroTitle1: "Select to Translate,",
      heroTitle2: "Enter to In-Place Rewrite.",
      heroSub:
        "Break free from the friction of copy-pasting and window switching. Select text in any app, hit shortcut, and tap Enter—original text transforms atomically in-place.",
      ctaDownloadHero: "Download SwaprTrans v1.0.2 (DMG)",
      metaChip: " Apple Native Neural Engine",
      metaPrivacy: "100% Private · On-Device",
      metaWeight: "Lightweight < 2MB",

      // Demo Box
      demoTitle: "Teams / Slack Frictionless Experience",
      editorPlaceholder: "Plan your trip into everyday itinerary...",
      pill1: "✍️ Chat · In-Place Rewrite",
      pill2: "📖 Web · Select to Translate",
      pill3: "✉️ Email · In-Place Rewrite",
      pill4: "💻 Terminal · Error Lookup",

      // Features
      feat1Title: " Apple Official Native Neural Engine",
      feat1Desc:
        "Deeply integrated with macOS 15+ Translation.framework. Computes entirely on local Apple Silicon chips with zero network reliance.",
      feat2Title: "⚡️ Instant In-Place Rewrite",
      feat2Desc:
        "Eliminates clumsy copy-pasting. Tap Enter when HUD floats to atomically replace the selected text with authentic translation.",
      feat3Title: "🌐 Tri-Engine Smart Failover",
      feat3Desc:
        "Defaults to Apple local offline engine, with seamless fallback to Microsoft Edge fast keyless lane and Google Translate.",
      feat4Title: "🪟 Non-Activating HUD & Open SPM",
      feat4Desc:
        "Pure Swift native build with negligible RAM usage. Never steals window focus; core SwaprTransKit open source via Swift Package.",

      // Install
      installTitle: "Quick Start & Setup",
      installStep1: "Download <strong>SwaprTrans-1.0.2.dmg</strong> and drag the App to <strong>Applications</strong>;",
      installStep2: "First run: if prompted by Gatekeeper, right-click <strong>SwaprTrans.app → Open</strong> in Finder;",
      installStep3: "Grant <strong>Accessibility</strong> permission to allow instant selection detection and in-place rewrite.",
      btnDownloadBox: "Download SwaprTrans-1.0.2.dmg (1.9MB)",

      // Footer
      footerText: "SwaprTrans · The lightweight native in-place translation tool for macOS",
    },
  };

  const scenarios = [
    // 1. Chat input: In-place rewrite
    {
      mode: "replace",
      theme: "chat",
      appTitle: {
        zh: "Teams / Slack · 输入框原地覆写体验",
        en: "Teams / Slack · In-Place Chat Rewrite"
      },
      zh: {
        prefix: "",
        input: "我的英语不怎么好",
        suffix: "",
        dir: "ZH → EN",
        provider: "Microsoft (Edge)",
        orig: "我的英语不怎么好",
        trans: "My English isn't very good"
      },
      en: {
        prefix: "",
        input: "我的英语不怎么好",
        suffix: "",
        dir: "ZH → EN",
        provider: "Microsoft (Edge)",
        orig: "我的英语不怎么好",
        trans: "My English isn't very good"
      }
    },
    // 2. Web browsing: Select-to-translate & read (no overwrite)
    {
      mode: "read",
      theme: "browser",
      browserUrl: "developer.apple.com/documentation/translation",
      appTitle: {
        zh: "Safari · 网页划词即翻与双语对照",
        en: "Safari · Select to Translate & Lookup"
      },
      zh: {
        prefix: "The M4 chip delivers ",
        input: "industry-leading performance and power efficiency",
        suffix: " across demanding creative workflows.",
        dir: "EN → ZH",
        provider: "Apple (Native)",
        orig: "industry-leading performance and power efficiency",
        trans: "行业领先的超强性能与出色能效表现"
      },
      en: {
        prefix: "The M4 chip delivers ",
        input: "industry-leading performance and power efficiency",
        suffix: " across demanding creative workflows.",
        dir: "EN → ZH",
        provider: "Apple (Native)",
        orig: "industry-leading performance and power efficiency",
        trans: "行业领先的超强性能与出色能效表现"
      }
    },
    // 3. Business Email: In-place rewrite
    {
      mode: "replace",
      theme: "chat",
      appTitle: {
        zh: "Mail / Outlook · 商务邮件草稿原地蜕变",
        en: "Mail / Outlook · Fluent Business Email Rewrite"
      },
      zh: {
        prefix: "",
        input: "期待与贵司团队建立长期稳固的合作关系，共促业务增长。",
        dir: "ZH → EN",
        provider: "Apple (Native)",
        orig: "期待与贵司团队建立长期稳固的合作关系，共促业务增长。",
        trans: "We look forward to establishing a solid partnership with your team to drive mutual growth."
      },
      en: {
        prefix: "",
        input: "期待与贵司团队建立长期稳固的合作关系，共促业务增长。",
        dir: "ZH → EN",
        provider: "Apple (Native)",
        orig: "期待与贵司团队建立长期稳固的合作关系，共促业务增长。",
        trans: "We look forward to establishing a solid partnership with your team to drive mutual growth."
      }
    },
    // 4. Terminal/Docs: Tech term & error lookup (no overwrite)
    {
      mode: "read",
      theme: "terminal",
      terminalPrompt: "linrol@iMac ~ % ",
      appTitle: {
        zh: "Terminal — zsh — 80×24",
        en: "Terminal — zsh — 80×24"
      },
      zh: {
        prefix: "Error: connect ECONNREFUSED — ",
        input: "Check if the backend daemon is actively listening.",
        suffix: "",
        dir: "EN → ZH",
        provider: "Apple (Native)",
        orig: "Check if the backend daemon is actively listening.",
        trans: "检查后台守护进程是否已正常启动并监听端口。"
      },
      en: {
        prefix: "Error: connect ECONNREFUSED — ",
        input: "Check if the backend daemon is actively listening.",
        suffix: "",
        dir: "EN → ZH",
        provider: "Apple (Native)",
        orig: "Check if the backend daemon is actively listening.",
        trans: "检查后台守护进程是否已正常启动并监听端口。"
      }
    }
  ];

  const root = document.documentElement;
  const langButtons = document.querySelectorAll("[data-set-lang]");
  const textStream = document.getElementById("text-stream");
  const swaprHud = document.getElementById("swapr-hud");
  const hudDirText = document.getElementById("hud-dir-text");
  const hudProviderTag = document.getElementById("hud-provider-tag");
  const hudOrigText = document.getElementById("hud-orig-text");
  const hudTransText = document.getElementById("hud-trans-text");
  const hudReplaceBtn = document.getElementById("hud-replace-btn");
  const hudCopyBtn = document.getElementById("hud-copy-btn");
  const hudCopyLabel = document.getElementById("hud-copy-label");
  const demoWindowTitle = document.getElementById("demo-window-title");
  const demoPills = document.querySelectorAll(".demo-pill");

  let currentLang = localStorage.getItem("st-lang") || "zh";
  let activeScenarioIndex = 0;
  let demoTimer = 0;
  let demoToken = 0;

  function t(key) {
    return strings[currentLang][key] ?? strings.zh[key] ?? key;
  }

  function applyLanguage(next) {
    currentLang = next in strings ? next : "zh";
    localStorage.setItem("st-lang", currentLang);
    root.lang = currentLang === "zh" ? "zh-CN" : "en";
    document.title = t("pageTitle");

    document.querySelectorAll("[data-i18n]").forEach((el) => {
      const key = el.getAttribute("data-i18n");
      if (!key) return;
      const value = t(key);
      if (el.getAttribute("data-html") === "true") {
        el.innerHTML = value;
      } else {
        el.textContent = value;
      }
    });

    langButtons.forEach((btn) => {
      btn.setAttribute("aria-pressed", String(btn.getAttribute("data-set-lang") === currentLang));
    });

    restartDemo();
  }

  function sleep(ms, token) {
    return new Promise((resolve, reject) => {
      demoTimer = window.setTimeout(() => {
        if (token !== demoToken) reject(new Error("cancelled"));
        else resolve();
      }, ms);
    });
  }

  async function runDemo(token) {
    if (!textStream || !swaprHud) return;

    const scene = scenarios[activeScenarioIndex];
    const data = scene[currentLang];

    const demoCard = document.getElementById("demo-card");
    const demoBarTitleWrap = document.getElementById("demo-bar-title-wrap");
    const demoBrowserBar = document.getElementById("demo-browser-bar");
    const browserUrlText = document.getElementById("browser-url-text");
    const terminalPrompt = document.getElementById("terminal-prompt");
    const editorFakeToolbar = document.getElementById("editor-fake-toolbar");
    const terminalFakeStatusbar = document.getElementById("terminal-fake-statusbar");
    const demoCaret = document.getElementById("demo-caret");

    if (demoCard) {
      demoCard.className = `demo-card theme-${scene.theme || "chat"}`;
    }

    if (scene.theme === "browser") {
      if (demoBarTitleWrap) demoBarTitleWrap.style.display = "none";
      if (demoBrowserBar) {
        demoBrowserBar.style.display = "flex";
        if (browserUrlText) browserUrlText.textContent = scene.browserUrl || "developer.apple.com";
      }
      if (terminalPrompt) terminalPrompt.style.display = "none";
      if (editorFakeToolbar) editorFakeToolbar.style.display = "none";
      if (terminalFakeStatusbar) terminalFakeStatusbar.style.display = "none";
      if (demoCaret) demoCaret.style.display = "none";
    } else if (scene.theme === "terminal") {
      if (demoBarTitleWrap) demoBarTitleWrap.style.display = "flex";
      if (demoBrowserBar) demoBrowserBar.style.display = "none";
      if (terminalPrompt) {
        terminalPrompt.style.display = "inline";
        terminalPrompt.textContent = scene.terminalPrompt || "linrol@iMac ~ % ";
      }
      if (editorFakeToolbar) editorFakeToolbar.style.display = "none";
      if (terminalFakeStatusbar) terminalFakeStatusbar.style.display = "flex";
      if (demoCaret) demoCaret.style.display = "none";
    } else {
      if (demoBarTitleWrap) demoBarTitleWrap.style.display = "flex";
      if (demoBrowserBar) demoBrowserBar.style.display = "none";
      if (terminalPrompt) terminalPrompt.style.display = "none";
      if (editorFakeToolbar) editorFakeToolbar.style.display = "flex";
      if (terminalFakeStatusbar) terminalFakeStatusbar.style.display = "none";
      if (demoCaret) demoCaret.style.display = "inline-block";
    }

    if (demoWindowTitle && scene.appTitle) {
      demoWindowTitle.textContent = scene.appTitle[currentLang] || scene.appTitle.zh;
    }

    textStream.innerHTML = "";
    swaprHud.classList.remove("is-visible");
    if (hudReplaceBtn) hudReplaceBtn.classList.remove("active");
    if (hudCopyBtn) {
      hudCopyBtn.classList.remove("active");
      if (hudCopyLabel) hudCopyLabel.textContent = "Copy";
    }

    demoPills.forEach((pill, idx) => {
      pill.classList.toggle("active", idx === activeScenarioIndex);
    });

    try {
      if (scene.mode === "replace") {
        // --- MODE 1: TYPE & REPLACE IN-PLACE ---
        // 1. Type
        for (let i = 1; i <= data.input.length; i++) {
          textStream.textContent = data.input.slice(0, i);
          await sleep(35 + (i % 4 === 0 ? 30 : 0), token);
        }

        await sleep(350, token);

        // 2. Select text (mint green selection highlight)
        textStream.innerHTML = `<span class="text-selected">${data.input}</span>`;
        await sleep(350, token);

        // 3. Float SwaprTrans HUD
        if (hudDirText) hudDirText.textContent = data.dir;
        if (hudProviderTag) hudProviderTag.textContent = data.provider;
        if (hudOrigText) hudOrigText.textContent = data.orig;
        if (hudTransText) hudTransText.textContent = data.trans;
        swaprHud.classList.add("is-visible");

        await sleep(1400, token);

        // 4. Trigger Replace (Click / Enter effect)
        if (hudReplaceBtn) hudReplaceBtn.classList.add("active");
        await sleep(220, token);
        if (hudReplaceBtn) hudReplaceBtn.classList.remove("active");

        // 5. In-Place Rewrite
        swaprHud.classList.remove("is-visible");
        textStream.innerHTML = `<span class="text-replaced">${data.trans}</span>`;

        // 6. Pause to appreciate
        await sleep(3500, token);
      } else {
        // --- MODE 2: READING SELECTION TRANSLATE (NO OVERWRITE) ---
        // 1. Full paragraph appears as read-only article / doc
        textStream.innerHTML = `${data.prefix}${data.input}${data.suffix}`;
        await sleep(400, token);

        // 2. Mouse selection highlights target phrase
        textStream.innerHTML = `${data.prefix}<span class="text-selected">${data.input}</span>${data.suffix}`;
        await sleep(400, token);

        // 3. Float SwaprTrans HUD with translation
        if (hudDirText) hudDirText.textContent = data.dir;
        if (hudProviderTag) hudProviderTag.textContent = data.provider;
        if (hudOrigText) hudOrigText.textContent = data.orig;
        if (hudTransText) hudTransText.textContent = data.trans;
        swaprHud.classList.add("is-visible");

        await sleep(1500, token);

        // 4. User copies translation to clipboard (or just reads it)
        if (hudCopyBtn) {
          hudCopyBtn.classList.add("active");
          if (hudCopyLabel) hudCopyLabel.textContent = "Copied!";
        }
        await sleep(650, token);
        if (hudCopyBtn) hudCopyBtn.classList.remove("active");

        // 5. HUD smoothly fades out, original article text stays completely intact!
        await sleep(400, token);
        swaprHud.classList.remove("is-visible");
        textStream.innerHTML = `${data.prefix}${data.input}${data.suffix}`;

        // 6. Pause to appreciate
        await sleep(3000, token);
      }

      // Next loop
      activeScenarioIndex = (activeScenarioIndex + 1) % scenarios.length;
      if (token === demoToken) {
        runDemo(token);
      }
    } catch {
      /* cancelled */
    }
  }

  function restartDemo() {
    demoToken += 1;
    window.clearTimeout(demoTimer);
    runDemo(demoToken);
  }

  langButtons.forEach((btn) => {
    btn.addEventListener("click", () => {
      const next = btn.getAttribute("data-set-lang");
      if (next) applyLanguage(next);
    });
  });

  demoPills.forEach((pill, index) => {
    pill.addEventListener("click", () => {
      activeScenarioIndex = index;
      restartDemo();
    });
  });

  applyLanguage(currentLang);
})();
