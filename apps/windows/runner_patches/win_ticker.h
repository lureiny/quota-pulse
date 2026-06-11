#ifndef RUNNER_WIN_TICKER_H_
#define RUNNER_WIN_TICKER_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

// Windows 桌面悬浮跑马灯(原生 Win32 浮层 + Direct2D 像素级滚动)。
// 对应 macOS 菜单栏滚动文字(NSStatusItem);Windows 托盘无承载文字处,故用置顶浮窗自绘。
// Dart 侧通道见 apps/windows/lib/win_ticker.dart。
namespace qp_ticker {

// 在 Flutter 引擎就绪后调用一次:挂上 quota_pulse/ticker 通道,惰性创建/管理浮窗。
// owner = 主 Flutter 窗口 HWND(浮窗的 owner,用于默认定位与置顶层级)。
void Attach(flutter::BinaryMessenger* messenger, HWND owner);

}  // namespace qp_ticker

#endif  // RUNNER_WIN_TICKER_H_
