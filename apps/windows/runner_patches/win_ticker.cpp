#include "win_ticker.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <d2d1.h>
#include <dwrite.h>
#include <windowsx.h>
#include <wrl/client.h>

#include <cmath>
#include <cstdlib>
#include <cwchar>
#include <map>
#include <memory>
#include <string>
#include <variant>
#include <vector>

#pragma comment(lib, "d2d1.lib")
#pragma comment(lib, "dwrite.lib")
#pragma comment(lib, "advapi32.lib")

namespace qp_ticker {
namespace {

using Microsoft::WRL::ComPtr;

// ---- 逻辑尺寸常量(DIP,96dpi 基准)----
constexpr float kPadX = 12.0f;       // 文字区左右内边距
constexpr float kHeight = 30.0f;     // 浮窗逻辑高
constexpr float kFontSize = 14.0f;
constexpr float kGap = 44.0f;        // 滚动一圈尾到头的空隙(与 macOS 一致)
constexpr float kCorner = 9.0f;      // 圆角
constexpr float kDotRadius = 4.0f;   // 状态圆点半径
constexpr float kMargin = 16.0f;     // 默认贴边留白
constexpr UINT_PTR kAnimTimer = 1;
constexpr UINT_PTR kFsTimer = 2;
constexpr wchar_t kClassName[] = L"QuotaPulseTickerWnd";
constexpr wchar_t kDot = L'\x25CF';  // ● 实心圆(用 drawing effect 上色当状态点)

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return L"";
  int n = ::MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
  std::wstring w(n, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), &w[0], n);
  return w;
}

const flutter::EncodableValue* Find(const flutter::EncodableMap& m, const char* k) {
  auto it = m.find(flutter::EncodableValue(std::string(k)));
  return it == m.end() ? nullptr : &it->second;
}
bool GetBool(const flutter::EncodableMap& m, const char* k, bool d) {
  if (auto v = Find(m, k)) if (auto p = std::get_if<bool>(v)) return *p;
  return d;
}
double GetDouble(const flutter::EncodableMap& m, const char* k, double d) {
  if (auto v = Find(m, k)) {
    if (auto p = std::get_if<double>(v)) return *p;
    if (auto p = std::get_if<int32_t>(v)) return (double)*p;
    if (auto p = std::get_if<int64_t>(v)) return (double)*p;
  }
  return d;
}
int GetInt(const flutter::EncodableMap& m, const char* k, int d) {
  if (auto v = Find(m, k)) {
    if (auto p = std::get_if<int32_t>(v)) return (int)*p;
    if (auto p = std::get_if<int64_t>(v)) return (int)*p;
    if (auto p = std::get_if<double>(v)) return (int)*p;
  }
  return d;
}

bool SystemDark() {
  DWORD val = 1, sz = sizeof(val);
  if (::RegGetValueW(HKEY_CURRENT_USER,
                     L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                     L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &val,
                     &sz) != ERROR_SUCCESS) {
    return false;  // 读不到当浅色
  }
  return val == 0;
}

D2D1_COLOR_F ColorFromArgb(UINT32 c) {
  return D2D1::ColorF(((c >> 16) & 0xFF) / 255.0f, ((c >> 8) & 0xFF) / 255.0f,
                      (c & 0xFF) / 255.0f, ((c >> 24) & 0xFF) / 255.0f);
}

struct Seg {
  UINT32 color;
  std::wstring text;
};

// ---- 单例浮窗 ----
class Ticker {
 public:
  Ticker(flutter::MethodChannel<flutter::EncodableValue>* ch, HWND owner)
      : channel_(ch), owner_(owner) {
    dark_ = SystemDark();  // 兜底默认;每次 update 会按 app 主题覆盖
  }

  void Apply(const flutter::EncodableMap& args) {
    bool enabled = GetBool(args, "enabled", true);
    if (!enabled) {
      if (hwnd_) ::ShowWindow(hwnd_, SW_HIDE);
      shown_ = false;
      StopAnim();
      return;
    }
    pps_ = GetDouble(args, "pps", 100.0);
    width_ = (float)GetDouble(args, "width", 150.0);
    if (width_ < 1.0f) width_ = 1.0f;
    scrollPref_ = GetBool(args, "scroll", false);
    hideOnFullscreen_ = GetBool(args, "hideOnFullscreen", false);
    bool dark = GetBool(args, "dark", dark_);
    if (dark != dark_) {
      dark_ = dark;  // 主题切换 → 丢弃基础画刷,EnsureDevice 会按新明暗重建
      bgBrush_.Reset();
      textBrush_.Reset();
      outlineBrush_.Reset();
    }

    ParseSegments(args);

    bool created = EnsureCreated(GetInt(args, "x", -1), GetInt(args, "y", -1));
    (void)created;

    RebuildLayout();
    UpdateScrollState();
    UpdateFsTimer();
    Render();
    if (!fsHidden_) {
      ::ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
      shown_ = true;
    }
  }

  void ResetPosition() {
    if (!hwnd_) return;
    pos_ = DefaultPos();
    ::SetWindowPos(hwnd_, HWND_TOPMOST, pos_.x, pos_.y, 0, 0,
                   SWP_NOSIZE | SWP_NOACTIVATE);
    ReportMoved();
    Render();
  }

  // 主面板弹出 → 浮窗降为非置顶(落到置顶的主面板之下,仍在普通窗口之上);收起 → 恢复置顶。
  void SetPopoverOpen(bool open) {
    if (!hwnd_) return;
    ::SetWindowPos(hwnd_, open ? HWND_NOTOPMOST : HWND_TOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }

  // 点击浮窗唤起主面板时:把主面板(owner_=主窗口 HWND)移到浮窗附近。
  // 全程物理像素 + 真实 HWND,规避 Dart/window_manager 的坐标系换算。
  void PositionOwnerNearTicker() {
    if (!hwnd_ || !owner_) return;
    RECT tr, pr;
    if (!::GetWindowRect(hwnd_, &tr)) return;   // 浮窗矩形
    if (!::GetWindowRect(owner_, &pr)) return;  // 主面板矩形(取当前尺寸)
    int pw = pr.right - pr.left, ph = pr.bottom - pr.top;
    int gap = (int)std::ceil(8 * dpi_ / 96.0);
    int x = (tr.left + tr.right) / 2 - pw / 2;  // 水平居中对齐浮窗
    int y = tr.top - ph - gap;                  // 默认放浮窗上方
    HMONITOR mon = ::MonitorFromWindow(hwnd_, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi = {sizeof(mi)};
    ::GetMonitorInfoW(mon, &mi);
    if (y < mi.rcWork.top) y = tr.bottom + gap;  // 上方放不下 → 放下方
    if (x + pw > mi.rcWork.right) x = mi.rcWork.right - pw;
    if (x < mi.rcWork.left) x = mi.rcWork.left;
    if (y + ph > mi.rcWork.bottom) y = mi.rcWork.bottom - ph;
    if (y < mi.rcWork.top) y = mi.rcWork.top;
    ::SetWindowPos(owner_, nullptr, x, y, 0, 0,
                   SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  }

  void Destroy() {
    StopAnim();
    if (hwnd_) {
      ::KillTimer(hwnd_, kFsTimer);
      ::DestroyWindow(hwnd_);
      hwnd_ = nullptr;
    }
  }

  LRESULT WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
      case WM_TIMER:
        if (wp == kAnimTimer) {
          double loop = contentWidth_ + kGap;
          offset_ += pps_ / 60.0;
          if (loop > 0 && offset_ >= loop) offset_ -= loop;
          Render();
        } else if (wp == kFsTimer) {
          CheckFullscreen();
        }
        return 0;
      case WM_LBUTTONDOWN:
        ::SetCapture(hwnd);
        tracking_ = true;
        dragged_ = false;
        ::GetCursorPos(&downPt_);
        winAtDown_ = pos_;
        return 0;
      case WM_MOUSEMOVE:
        if (tracking_) {
          POINT cur;
          ::GetCursorPos(&cur);
          int dx = cur.x - downPt_.x, dy = cur.y - downPt_.y;
          if (!dragged_ && (std::abs(dx) >= ::GetSystemMetrics(SM_CXDRAG) ||
                            std::abs(dy) >= ::GetSystemMetrics(SM_CYDRAG))) {
            dragged_ = true;
          }
          if (dragged_) {
            pos_.x = winAtDown_.x + dx;
            pos_.y = winAtDown_.y + dy;
            ::SetWindowPos(hwnd, nullptr, pos_.x, pos_.y, 0, 0,
                           SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
          }
        }
        return 0;
      case WM_LBUTTONUP:
        if (tracking_) {
          tracking_ = false;
          ::ReleaseCapture();
          if (dragged_)
            ReportMoved();
          else if (channel_)
            channel_->InvokeMethod("onClick", nullptr);
        }
        return 0;
      case WM_CAPTURECHANGED:
        tracking_ = false;
        return 0;
      case WM_DPICHANGED:
        dpi_ = HIWORD(wp);
        Render();
        return 0;
      case WM_SETTINGCHANGE:
        // 系统明暗/主题变化 → 丢弃基础画刷 + 标记 layout 重建,下次 Render 按新色重建。
        bgBrush_.Reset();
        textBrush_.Reset();
        outlineBrush_.Reset();
        colorBrushes_.clear();
        layoutDirty_ = true;
        Render();
        return 0;
      case WM_NCHITTEST:
        return HTCLIENT;  // 整窗可点/可拖(我们自己处理拖拽)
    }
    return ::DefWindowProcW(hwnd, msg, wp, lp);
  }

 private:
  void ParseSegments(const flutter::EncodableMap& args) {
    segs_.clear();
    if (auto v = Find(args, "segments")) {
      if (auto list = std::get_if<flutter::EncodableList>(v)) {
        for (const auto& e : *list) {
          if (auto sm = std::get_if<flutter::EncodableMap>(&e)) {
            Seg s;
            s.color = (UINT32)GetInt(*sm, "color", (int)0xFF8E8E93);
            s.color |= 0xFF000000;  // 圆点不透明
            const flutter::EncodableValue* t = Find(*sm, "text");
            std::string txt = (t && std::get_if<std::string>(t))
                                  ? *std::get_if<std::string>(t)
                                  : std::string();
            s.text = Utf8ToWide(txt);
            segs_.push_back(std::move(s));
          }
        }
      }
    }
    if (segs_.empty()) segs_.push_back({0xFF8E8E93, L"quota-pulse"});
  }

  bool EnsureCreated(int savedX, int savedY) {
    if (hwnd_) return false;
    EnsureClass();
    // owner 必须为 nullptr:owned window 会被系统强制置于其 owner 之上(MSDN:
    // "An owned window is always above its owner"),那样主面板永远盖不住浮窗。
    // WS_EX_TOOLWINDOW 已保证不进任务栏/Alt-Tab,无需 owner。owner_ 仅留作默认定位用。
    hwnd_ = ::CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        kClassName, L"quota-pulse", WS_POPUP, 0, 0, 10, 10, /*owner*/ nullptr,
        nullptr, ::GetModuleHandleW(nullptr), this);
    if (!hwnd_) return false;
    dpi_ = QueryDpi();
    if (savedX >= 0 && savedY >= 0) {
      pos_ = {savedX, savedY};
      ClampToWork();
    } else {
      pos_ = DefaultPos();
    }
    memDC_ = ::CreateCompatibleDC(nullptr);
    return true;
  }

  static void EnsureClass() {
    static bool done = false;
    if (done) return;
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = &Ticker::Thunk;
    wc.hInstance = ::GetModuleHandleW(nullptr);
    wc.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = kClassName;
    ::RegisterClassExW(&wc);
    done = true;
  }

  static LRESULT CALLBACK Thunk(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    Ticker* self = nullptr;
    if (msg == WM_NCCREATE) {
      auto cs = reinterpret_cast<CREATESTRUCTW*>(lp);
      self = reinterpret_cast<Ticker*>(cs->lpCreateParams);
      ::SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    } else {
      self = reinterpret_cast<Ticker*>(::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    }
    if (self) return self->WndProc(hwnd, msg, wp, lp);
    return ::DefWindowProcW(hwnd, msg, wp, lp);
  }

  UINT QueryDpi() {
    UINT d = ::GetDpiForWindow(hwnd_);
    return d ? d : 96;
  }

  POINT DefaultPos() {
    HMONITOR mon = ::MonitorFromWindow(owner_ ? owner_ : hwnd_,
                                       MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO mi = {sizeof(mi)};
    ::GetMonitorInfoW(mon, &mi);
    float scale = dpi_ / 96.0f;
    int w = (int)std::ceil((2 * kPadX + width_) * scale);
    int h = (int)std::ceil(kHeight * scale);
    int m = (int)std::ceil(kMargin * scale);
    return {mi.rcWork.right - w - m, mi.rcWork.bottom - h - m};
  }

  void ClampToWork() {
    HMONITOR mon = ::MonitorFromPoint(pos_, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi = {sizeof(mi)};
    ::GetMonitorInfoW(mon, &mi);
    float scale = dpi_ / 96.0f;
    int w = (int)std::ceil((2 * kPadX + width_) * scale);
    int h = (int)std::ceil(kHeight * scale);
    if (pos_.x > mi.rcWork.right - w) pos_.x = mi.rcWork.right - w;
    if (pos_.y > mi.rcWork.bottom - h) pos_.y = mi.rcWork.bottom - h;
    if (pos_.x < mi.rcWork.left) pos_.x = mi.rcWork.left;
    if (pos_.y < mi.rcWork.top) pos_.y = mi.rcWork.top;
  }

  void ReportMoved() {
    if (!channel_) return;
    channel_->InvokeMethod(
        "onMoved",
        std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
            {flutter::EncodableValue("x"), flutter::EncodableValue((int32_t)pos_.x)},
            {flutter::EncodableValue("y"), flutter::EncodableValue((int32_t)pos_.y)},
        }));
  }

  // ---- Direct2D 资源 ----
  bool EnsureDevice() {
    if (!d2dFactory_) {
      if (FAILED(::D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                                     d2dFactory_.GetAddressOf())))
        return false;
    }
    if (!dwrite_) {
      if (FAILED(::DWriteCreateFactory(
              DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
              reinterpret_cast<IUnknown**>(dwrite_.GetAddressOf()))))
        return false;
    }
    if (!textFormat_) {
      if (FAILED(dwrite_->CreateTextFormat(
              L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_NORMAL,
              DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, kFontSize,
              L"", textFormat_.GetAddressOf())))
        return false;
      textFormat_->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
      textFormat_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    }
    if (!target_) {
      D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
          D2D1_RENDER_TARGET_TYPE_DEFAULT,
          D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                            D2D1_ALPHA_MODE_PREMULTIPLIED),
          0, 0, D2D1_RENDER_TARGET_USAGE_NONE, D2D1_FEATURE_LEVEL_DEFAULT);
      if (FAILED(d2dFactory_->CreateDCRenderTarget(&props,
                                                   target_.GetAddressOf())))
        return false;
    }
    if (!bgBrush_) {
      bool dark = dark_;  // 由 app 主题决定(update 传入),非系统明暗
      target_->CreateSolidColorBrush(
          dark ? D2D1::ColorF(0.12f, 0.12f, 0.13f, 0.90f)
               : D2D1::ColorF(0.97f, 0.97f, 0.98f, 0.92f),
          bgBrush_.GetAddressOf());
      target_->CreateSolidColorBrush(
          dark ? D2D1::ColorF(1, 1, 1, 0.92f) : D2D1::ColorF(0.08f, 0.08f, 0.09f, 1),
          textBrush_.GetAddressOf());
      target_->CreateSolidColorBrush(
          dark ? D2D1::ColorF(1, 1, 1, 0.14f) : D2D1::ColorF(0, 0, 0, 0.12f),
          outlineBrush_.GetAddressOf());
    }
    return target_ && bgBrush_ && textBrush_ && outlineBrush_;
  }

  ID2D1SolidColorBrush* ColorBrush(UINT32 c) {
    auto it = colorBrushes_.find(c);
    if (it != colorBrushes_.end()) return it->second.Get();
    ComPtr<ID2D1SolidColorBrush> b;
    if (FAILED(target_->CreateSolidColorBrush(ColorFromArgb(c), b.GetAddressOf())))
      return textBrush_.Get();
    auto* raw = b.Get();
    colorBrushes_.emplace(c, std::move(b));
    return raw;
  }

  void DiscardDevice() {
    target_.Reset();
    bgBrush_.Reset();
    textBrush_.Reset();
    outlineBrush_.Reset();
    colorBrushes_.clear();
    // layout_ 可保留(与设备无关),但其 drawing effect 指向已失效的画刷 → 重建。
    layoutDirty_ = true;
  }

  // 由 segs_ 组装一行文本:每段前一个 ●(状态色)+ 文本,段间 "   ·   "。
  void RebuildLayout() {
    if (!EnsureDevice()) return;
    std::wstring s;
    struct Mark {
      UINT32 start;
      UINT32 color;
    };
    std::vector<Mark> marks;
    for (size_t i = 0; i < segs_.size(); ++i) {
      if (i) s += L"   \x00B7   ";  // 段间分隔 · (与 macOS join 一致风格)
      marks.push_back({(UINT32)s.size(), segs_[i].color});
      s += kDot;
      s += L' ';
      s += segs_[i].text;
    }
    content_ = s;
    layout_.Reset();
    if (FAILED(dwrite_->CreateTextLayout(content_.c_str(), (UINT32)content_.size(),
                                         textFormat_.Get(), 100000.0f, kHeight,
                                         layout_.GetAddressOf()))) {
      return;
    }
    DWRITE_TEXT_METRICS dm = {};
    layout_->GetMetrics(&dm);
    contentWidth_ = dm.widthIncludingTrailingWhitespace;
    for (const auto& mk : marks) {
      layout_->SetDrawingEffect(ColorBrush(mk.color),
                                DWRITE_TEXT_RANGE{mk.start, 1});
    }
    layoutDirty_ = false;
  }

  void UpdateScrollState() {
    bool want = scrollPref_ && contentWidth_ > width_;
    if (want && !scrolling_) {
      offset_ = 0;
      scrolling_ = true;
      ::SetTimer(hwnd_, kAnimTimer, 16, nullptr);
    } else if (!want && scrolling_) {
      StopAnim();
    }
  }
  void StopAnim() {
    if (scrolling_ && hwnd_) ::KillTimer(hwnd_, kAnimTimer);
    scrolling_ = false;
    offset_ = 0;
  }

  void UpdateFsTimer() {
    if (!hwnd_) return;
    if (hideOnFullscreen_)
      ::SetTimer(hwnd_, kFsTimer, 1000, nullptr);
    else {
      ::KillTimer(hwnd_, kFsTimer);
      if (fsHidden_) {
        fsHidden_ = false;
        if (shown_) ::ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
      }
    }
  }

  void CheckFullscreen() {
    HWND fg = ::GetForegroundWindow();
    bool full = false;
    if (fg && fg != hwnd_) {
      wchar_t cls[64] = {};
      ::GetClassNameW(fg, cls, 63);
      // 排除桌面/任务栏 shell
      if (wcscmp(cls, L"Progman") && wcscmp(cls, L"WorkerW") &&
          wcscmp(cls, L"Shell_TrayWnd")) {
        RECT wr;
        if (::GetWindowRect(fg, &wr)) {
          HMONITOR mon = ::MonitorFromWindow(fg, MONITOR_DEFAULTTONEAREST);
          MONITORINFO mi = {sizeof(mi)};
          ::GetMonitorInfoW(mon, &mi);
          full = wr.left <= mi.rcMonitor.left && wr.top <= mi.rcMonitor.top &&
                 wr.right >= mi.rcMonitor.right && wr.bottom >= mi.rcMonitor.bottom;
        }
      }
    }
    if (full && !fsHidden_) {
      fsHidden_ = true;
      ::ShowWindow(hwnd_, SW_HIDE);
    } else if (!full && fsHidden_) {
      fsHidden_ = false;
      if (shown_) ::ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
    }
  }

  void EnsureDib(int w, int h) {
    if (dib_ && w == dibW_ && h == dibH_) return;
    if (dib_) {
      ::SelectObject(memDC_, oldBmp_);
      ::DeleteObject(dib_);
      dib_ = nullptr;
    }
    BITMAPINFO bmi = {};
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h;  // 顶向下
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;
    void* bits = nullptr;
    dib_ = ::CreateDIBSection(nullptr, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
    oldBmp_ = (HBITMAP)::SelectObject(memDC_, dib_);
    dibW_ = w;
    dibH_ = h;
  }

  void Render() {
    if (!hwnd_ || !memDC_) return;
    if (!EnsureDevice()) return;
    if (layoutDirty_ || !layout_) RebuildLayout();

    float scale = dpi_ / 96.0f;
    float logicalW = 2 * kPadX + width_;
    int physW = (int)std::ceil(logicalW * scale);
    int physH = (int)std::ceil(kHeight * scale);
    if (physW < 1) physW = 1;
    if (physH < 1) physH = 1;
    EnsureDib(physW, physH);

    RECT rc = {0, 0, physW, physH};
    if (FAILED(target_->BindDC(memDC_, &rc))) return;
    target_->SetDpi((float)dpi_, (float)dpi_);
    target_->BeginDraw();
    target_->SetTransform(D2D1::Matrix3x2F::Identity());
    target_->Clear(D2D1::ColorF(0, 0, 0, 0));

    D2D1_ROUNDED_RECT rr = {{0.5f, 0.5f, logicalW - 0.5f, kHeight - 0.5f}, kCorner,
                            kCorner};
    target_->FillRoundedRectangle(rr, bgBrush_.Get());
    target_->DrawRoundedRectangle(rr, outlineBrush_.Get(), 1.0f);

    target_->PushAxisAlignedClip(
        D2D1::RectF(kPadX, 0, kPadX + width_, kHeight),
        D2D1_ANTIALIAS_MODE_ALIASED);
    if (layout_) {
      if (scrolling_) {
        float loop = contentWidth_ + kGap;
        float x = kPadX - (float)offset_;
        while (x < kPadX + width_) {
          target_->DrawTextLayout(D2D1::Point2F(x, 0), layout_.Get(),
                                  textBrush_.Get());
          if (loop <= 0) break;
          x += loop;
        }
      } else {
        target_->DrawTextLayout(D2D1::Point2F(kPadX, 0), layout_.Get(),
                                textBrush_.Get());
      }
    }
    target_->PopAxisAlignedClip();

    HRESULT hr = target_->EndDraw();
    if (hr == D2DERR_RECREATE_TARGET) {
      DiscardDevice();
      return;
    }

    POINT ptDst = pos_;
    SIZE sz = {physW, physH};
    POINT ptSrc = {0, 0};
    BLENDFUNCTION bf = {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    HDC screen = ::GetDC(nullptr);
    ::UpdateLayeredWindow(hwnd_, screen, &ptDst, &sz, memDC_, &ptSrc, 0, &bf,
                          ULW_ALPHA);
    ::ReleaseDC(nullptr, screen);
  }

  // 状态
  flutter::MethodChannel<flutter::EncodableValue>* channel_ = nullptr;
  HWND owner_ = nullptr;
  HWND hwnd_ = nullptr;
  UINT dpi_ = 96;
  POINT pos_ = {0, 0};
  float width_ = 150.0f;
  double pps_ = 100.0;
  bool scrollPref_ = false;
  bool scrolling_ = false;
  double offset_ = 0;
  bool hideOnFullscreen_ = false;
  bool fsHidden_ = false;
  bool shown_ = false;
  bool dark_ = false;  // 明暗:由 app 主题设置决定(每次 update 传入)

  std::vector<Seg> segs_;
  std::wstring content_;
  float contentWidth_ = 0;
  bool layoutDirty_ = true;

  // 拖拽
  bool tracking_ = false;
  bool dragged_ = false;
  POINT downPt_ = {0, 0};
  POINT winAtDown_ = {0, 0};

  // GDI DIB(layered 源)
  HDC memDC_ = nullptr;
  HBITMAP dib_ = nullptr;
  HBITMAP oldBmp_ = nullptr;
  int dibW_ = 0, dibH_ = 0;

  // D2D / DWrite
  ComPtr<ID2D1Factory> d2dFactory_;
  ComPtr<IDWriteFactory> dwrite_;
  ComPtr<IDWriteTextFormat> textFormat_;
  ComPtr<ID2D1DCRenderTarget> target_;
  ComPtr<ID2D1SolidColorBrush> bgBrush_;
  ComPtr<ID2D1SolidColorBrush> textBrush_;
  ComPtr<ID2D1SolidColorBrush> outlineBrush_;
  std::map<UINT32, ComPtr<ID2D1SolidColorBrush>> colorBrushes_;
  ComPtr<IDWriteTextLayout> layout_;
};

std::unique_ptr<Ticker> g_ticker;
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

}  // namespace

void Attach(flutter::BinaryMessenger* messenger, HWND owner) {
  if (g_channel) return;  // 只挂一次
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "quota_pulse/ticker",
      &flutter::StandardMethodCodec::GetInstance());
  g_ticker = std::make_unique<Ticker>(g_channel.get(), owner);
  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const auto& method = call.method_name();
        if (method == "update") {
          if (auto* m = std::get_if<flutter::EncodableMap>(call.arguments()))
            g_ticker->Apply(*m);
          result->Success();
        } else if (method == "setPopoverOpen") {
          if (auto b = std::get_if<bool>(call.arguments()))
            g_ticker->SetPopoverOpen(*b);
          result->Success();
        } else if (method == "positionNearTicker") {
          g_ticker->PositionOwnerNearTicker();
          result->Success();
        } else if (method == "resetPosition") {
          g_ticker->ResetPosition();
          result->Success();
        } else if (method == "destroy") {
          g_ticker->Destroy();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

}  // namespace qp_ticker
