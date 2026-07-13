# 安装 QuotaDot

## 系统要求

- macOS 14 Sonoma 或更高版本。
- 至少一个已登录的服务：Codex 或 Claude Code。

## 推荐安装方式

1. 在 GitHub Releases 下载最新的 `QuotaDot-x.y.z.dmg`。
2. 双击打开 DMG。
3. 把 QuotaDot 拖到 Applications 文件夹。
4. 从“应用程序”启动 QuotaDot。

QuotaDot 是菜单栏应用，不会出现在 Dock 中。启动后，菜单栏会显示双环图标与当前最低剩余额度，桌面上会出现可自动收起的悬浮窗口。

## 首次使用

- 天气背景：macOS 询问定位权限时选择允许；拒绝后额度功能仍可使用。
- 自动启动：打开 QuotaDot 菜单栏菜单 → 设置，开启“登录后自动启动”。如果 macOS 要求确认，按提示前往“系统设置 → 通用 → 登录项”。
- 中英文：展开悬浮窗后点击状态行里的 `EN` / `ZH`，或在设置中选择显示语言；无需重启。
- 数据为空：先确认 Codex 或 Claude Code 已在当前 macOS 用户下登录，然后点击“立即刷新”。

## 卸载

1. 在 QuotaDot 设置中关闭“登录后自动启动”。
2. 从菜单栏选择“退出 QuotaDot”。
3. 将 Applications 中的 QuotaDot 移到废纸篓。

## 关于未签名测试包

文件名含 `UNSIGNED` 的 DMG 仅用于开发者本机验证，未经 Apple 公证。普通用户应只安装 GitHub Releases 中经过签名与公证的正式包。
