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
constexpr float kHeight = 30.0f;     // 浮窗逻辑高(单行模式)
constexpr float kPadYMulti = 8.0f;   // 多行模式上下内边距
constexpr float kMaxContentW = 600.0f; // 多行模式卡片最大内容宽(超出按卡片边缘截断)
constexpr float kTabGap = 14.0f;     // 多行模式列间距(第一列「标签 用量」与「· 重置」之间)
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
  bool newAccount;  // 账户起始段:滚动行账户之间用更大间隔
};

// 多行模式的一行:可选前导状态圆点 + 缩进 + 文本。
struct Line {
  bool dot;
  UINT32 color;
  int indent;
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
    // 宽度:只在 Dart 端「目标宽」真正变化时(设置滑块改动、或拖拽回写后的新值)才覆盖
    // width_;否则保留当前 width_。关键:用户直接拖拽浮窗边缘改宽时,Dart 目标宽并未变,
    // 后续每个 tick 都推同一个旧目标宽 —— 若无条件覆盖,松手后就会被立刻弹回原宽。
    // 这样不依赖 onResized 回调是否成功:即便回调没回到 Dart,拖出来的宽也不会被盖掉。
    // 拖拽进行中(tracking_ && resizeEdge_)更不覆盖。
    {
      float wArg = (float)GetDouble(args, "width", 150.0);
      if (wArg < 1.0f) wArg = 1.0f;
      bool resizing = tracking_ && resizeEdge_;
      if (!resizing && (lastWidthArg_ < 0.0f || wArg != lastWidthArg_)) {
        width_ = wArg;
        lastWidthArg_ = wArg;
      }
    }
    scrollPref_ = GetBool(args, "scroll", false);
    multiline_ = GetBool(args, "multiline", false);
    hideOnFullscreen_ = GetBool(args, "hideOnFullscreen", false);
    bool dark = GetBool(args, "dark", dark_);
    if (dark != dark_) {
      dark_ = dark;  // 主题切换 → 丢弃基础画刷,EnsureDevice 会按新明暗重建
      bgBrush_.Reset();
      textBrush_.Reset();
      outlineBrush_.Reset();
    }

    ParseSegments(args);
    ParseLines(args);

    bool created = EnsureCreated(GetInt(args, "x", -1), GetInt(args, "y", -1));
    (void)created;

    RebuildLayout();
    // 尺寸在 RebuildLayout 后才确定(多行高度随行数变):默认位置据此重算贴右下角;
    // 已拖拽/已保存的位置则按当前尺寸夹回工作区,避免变高后越出屏幕。
    if (posIsDefault_)
      pos_ = DefaultPos();
    else
      ClampToWork();
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
    posIsDefault_ = true;  // 回归默认位置:后续随内容高度变化继续贴右下角
    pos_ = DefaultPos();
    // 只移动、不动 z-order(SWP_NOZORDER):若此时主面板开着,浮窗保持在其下方,
    // 不能像以前那样强制 HWND_TOPMOST 又把自己顶到面板上面;面板关闭后由
    // setPopoverOpen(false) 恢复置顶。
    ::SetWindowPos(hwnd_, nullptr, pos_.x, pos_.y, 0, 0,
                   SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
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

  // 当前实际可见宽(逻辑像素,四舍五入)。供 update 的返回值带回 Dart 同步配置。
  int32_t CurrentWidth() const { return (int32_t)std::lround(width_); }

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
        resizeEdge_ = EdgeHit(downPt_);  // 命中边缘 → 本次为拉伸,否则移动
        widthAtDown_ = width_;
        dpiAtDown_ = dpi_;  // 整个拉伸用按下时的 DPI / 显示器,避免中途变化导致失配
        monAtDown_ = ::MonitorFromPoint(downPt_, MONITOR_DEFAULTTONEAREST);
        return 0;
      case WM_MOUSEMOVE:
        if (tracking_) {
          POINT cur;
          ::GetCursorPos(&cur);
          int dx = cur.x - downPt_.x, dy = cur.y - downPt_.y;
          if (!dragged_ && (std::abs(dx) >= ::GetSystemMetrics(SM_CXDRAG) ||
                            std::abs(dy) >= ::GetSystemMetrics(SM_CYDRAG))) {
            dragged_ = true;
            posIsDefault_ = false;  // 用户接管位置/尺寸 → 不再自动贴右下角
          }
          if (dragged_ && resizeEdge_) {
            // 边缘拉伸:物理位移换算成逻辑宽变化(全程用按下时的 scale,按绝对位移计算)。
            float scale = dpiAtDown_ / 96.0f;
            float dLogical = dx / scale;
            float neww = (resizeEdge_ == 1) ? widthAtDown_ - dLogical
                                            : widthAtDown_ + dLogical;
            ClampWidth(&neww, monAtDown_);
            if (resizeEdge_ == 1) {
              // 左边缘:把右边缘钉住,据新旧物理宽差反推左上角 x。
              int newPhysW = (int)std::ceil((2 * kPadX + neww) * scale);
              int oldPhysW = (int)std::ceil((2 * kPadX + widthAtDown_) * scale);
              pos_.x = (winAtDown_.x + oldPhysW) - newPhysW;
            }
            width_ = neww;
            UpdateScrollState();
            Render();  // UpdateLayeredWindow 一次性改尺寸+位置,无需额外 SetWindowPos
          } else if (dragged_) {
            // 普通移动
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
          if (dragged_) {
            if (resizeEdge_)
              ReportResized();  // 拉伸:持久化新宽(+左边缘拖带来的新位置)
            else
              ReportMoved();
          } else if (channel_) {
            // 未越过拖拽阈值(含边缘轻点)→ 视为点击,弹主面板
            channel_->InvokeMethod("onClick", nullptr);
          }
          resizeEdge_ = 0;
        }
        return 0;
      case WM_CAPTURECHANGED:
        tracking_ = false;
        resizeEdge_ = 0;
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
      case WM_SETCURSOR:
        // 滚动模式下悬停在左/右边缘 → 显示水平拉伸光标「↔」;其余落默认箭头。
        if (!multiline_ && LOWORD(lp) == HTCLIENT) {
          POINT pt;
          ::GetCursorPos(&pt);
          if (EdgeHit(pt)) {
            ::SetCursor(::LoadCursorW(nullptr, IDC_SIZEWE));
            return TRUE;
          }
        }
        break;  // 落到 DefWindowProc → 类默认箭头光标
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
            s.newAccount = GetBool(*sm, "newAccount", false);
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
    if (segs_.empty()) segs_.push_back({0xFF8E8E93, L"quota-pulse", true});
  }

  void ParseLines(const flutter::EncodableMap& args) {
    lines_.clear();
    if (auto v = Find(args, "lines")) {
      if (auto list = std::get_if<flutter::EncodableList>(v)) {
        for (const auto& e : *list) {
          if (auto lm = std::get_if<flutter::EncodableMap>(&e)) {
            Line ln;
            ln.dot = GetBool(*lm, "dot", false);
            ln.color = (UINT32)GetInt(*lm, "color", (int)0xFF8E8E93);
            ln.color |= 0xFF000000;  // 圆点不透明
            ln.indent = GetInt(*lm, "indent", 0);
            const flutter::EncodableValue* t = Find(*lm, "text");
            std::string txt = (t && std::get_if<std::string>(t))
                                  ? *std::get_if<std::string>(t)
                                  : std::string();
            ln.text = Utf8ToWide(txt);
            lines_.push_back(std::move(ln));
          }
        }
      }
    }
    if (lines_.empty()) lines_.push_back({false, 0xFF8E8E93, 0, L"quota-pulse"});
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
      posIsDefault_ = false;  // 用保存位置;夹回工作区延后到 RebuildLayout 后(尺寸才定)
    } else {
      posIsDefault_ = true;  // 默认右下角:RebuildLayout 后据真实尺寸算
      pos_ = {0, 0};
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

  // 当前逻辑尺寸(DIP):单行=2*kPadX+width_ × kHeight;
  // 多行=2*kPadX+内容宽(封顶 kMaxContentW) × 2*kPadYMulti+内容高。
  void CurrentLogicalSize(float* w, float* h) const {
    if (multiline_) {
      float cw = contentWidth_ > kMaxContentW ? kMaxContentW : contentWidth_;
      *w = 2 * kPadX + cw;
      *h = 2 * kPadYMulti + contentHeight_;
    } else {
      *w = 2 * kPadX + width_;
      *h = kHeight;
    }
  }

  // 当前物理尺寸(像素,按 DPI 取整,至少 1)。
  void CurrentPhysSize(int* w, int* h) const {
    float lw, lh;
    CurrentLogicalSize(&lw, &lh);
    float scale = dpi_ / 96.0f;
    *w = (int)std::ceil(lw * scale);
    *h = (int)std::ceil(lh * scale);
    if (*w < 1) *w = 1;
    if (*h < 1) *h = 1;
  }

  POINT DefaultPos() {
    HMONITOR mon = ::MonitorFromWindow(owner_ ? owner_ : hwnd_,
                                       MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO mi = {sizeof(mi)};
    ::GetMonitorInfoW(mon, &mi);
    int w, h;
    CurrentPhysSize(&w, &h);
    int m = (int)std::ceil(kMargin * dpi_ / 96.0f);
    return {mi.rcWork.right - w - m, mi.rcWork.bottom - h - m};
  }

  void ClampToWork() {
    HMONITOR mon = ::MonitorFromPoint(pos_, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi = {sizeof(mi)};
    ::GetMonitorInfoW(mon, &mi);
    int w, h;
    CurrentPhysSize(&w, &h);
    if (pos_.x > mi.rcWork.right - w) pos_.x = mi.rcWork.right - w;
    if (pos_.y > mi.rcWork.bottom - h) pos_.y = mi.rcWork.bottom - h;
    if (pos_.x < mi.rcWork.left) pos_.x = mi.rcWork.left;
    if (pos_.y < mi.rcWork.top) pos_.y = mi.rcWork.top;
  }

  // 命中测试:鼠标(屏幕坐标)落在浮窗左/右边缘约 6px 命中区返回 1/2,否则 0。
  // 仅滚动模式可拉伸(多行宽度由内容自适应,直接返回 0)。
  int EdgeHit(POINT screenPt) const {
    if (multiline_) return 0;
    int physW, physH;
    CurrentPhysSize(&physW, &physH);
    int x = screenPt.x - pos_.x;
    int y = screenPt.y - pos_.y;
    if (y < 0 || y > physH) return 0;
    int margin = (int)std::ceil(6.0f * dpi_ / 96.0f);
    if (margin < 4) margin = 4;
    if (x <= margin) return 1;             // 左边缘
    if (x >= physW - margin) return 2;     // 右边缘
    return 0;
  }

  // 把逻辑宽夹到 [60, 指定显示器整屏宽对应的内容宽],保证浮窗永不越屏。
  // [mon] 为拉伸按下时锁定的显示器(避免左边缘拖动越界后 pos_ 取到别的屏);
  // 为空则回退到当前位置所在屏。scale 用按下时的 DPI,与拉伸换算保持一致。
  void ClampWidth(float* w, HMONITOR mon) const {
    const float minW = 60.0f;
    if (!mon) mon = ::MonitorFromPoint(pos_, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi = {sizeof(mi)};
    ::GetMonitorInfoW(mon, &mi);
    float scale = dpiAtDown_ / 96.0f;
    // 窗口物理宽 =(2*kPadX + w)*scale,不得超过整屏物理宽 → 反推 w 上限。
    float maxW = (mi.rcMonitor.right - mi.rcMonitor.left) / scale - 2 * kPadX;
    if (maxW < minW) maxW = minW;
    if (*w < minW) *w = minW;
    if (*w > maxW) *w = maxW;
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

  // 拖拽边缘改宽结束:回报新宽(逻辑 DIP)+ 当前位置(左边缘拖会同时移动左上角)。
  void ReportResized() {
    if (!channel_) return;
    channel_->InvokeMethod(
        "onResized",
        std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
            {flutter::EncodableValue("w"),
             flutter::EncodableValue((int32_t)std::lround(width_))},
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

  void RebuildLayout() {
    if (!EnsureDevice()) return;
    if (multiline_)
      RebuildLayoutMulti();
    else
      RebuildLayoutSingle();
  }

  // 单行滚动:由 segs_ 组装一行文本,每段前一个 ●(状态色)+ 文本,段间 "   ·   ";
  // CENTER(继承自 textFormat_)在 kHeight 内垂直居中。
  void RebuildLayoutSingle() {
    std::wstring s;
    struct Mark {
      UINT32 start;
      UINT32 color;
    };
    std::vector<Mark> marks;
    for (size_t i = 0; i < segs_.size(); ++i) {
      // 账户之间用「   ·   」、账户内各窗口段之间用双空格,圆点颜色已区分状态/用量。
      if (i) s += segs_[i].newAccount ? L"   \x00B7   " : L"  ";
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

  // 测一段文本在当前字体下的宽度(DIP);用于多行模式列对齐(NO_WRAP 已在 textFormat_ 上)。
  float MeasureWidth(const std::wstring& t) {
    if (t.empty() || !dwrite_ || !textFormat_) return 0.0f;
    ComPtr<IDWriteTextLayout> tmp;
    if (FAILED(dwrite_->CreateTextLayout(t.c_str(), (UINT32)t.size(),
                                         textFormat_.Get(), 100000.0f, kHeight,
                                         tmp.GetAddressOf())))
      return 0.0f;
    DWRITE_TEXT_METRICS m = {};
    tmp->GetMetrics(&m);
    return m.widthIncludingTrailingWhitespace;
  }

  // 多行:每行 = 缩进(每级 4 空格)+ (可选 ● 圆点) + 文本,行间 '\n';NEAR 顶对齐。
  // 窗口行 text 内以 '\t' 分「标签 用量」与「· 重置」两列;测最长第一列宽设增量制表位,
  // 使各行 \t 后的重置列对齐到同一 x(比例字体下空格无法对齐,故走制表位)。
  void RebuildLayoutMulti() {
    std::wstring s;
    struct Mark {
      UINT32 start;
      UINT32 color;
    };
    std::vector<Mark> marks;
    float maxCol1 = 0.0f;  // 含 \t 的行,第一列(到 \t 前,含缩进+圆点)最大宽
    for (size_t i = 0; i < lines_.size(); ++i) {
      if (i) s += L'\n';
      const Line& ln = lines_[i];
      std::wstring prefix;
      for (int k = 0; k < ln.indent; ++k) prefix += L"    ";
      s += prefix;
      std::wstring dotPrefix;
      if (ln.dot) {
        marks.push_back({(UINT32)s.size(), ln.color});
        s += kDot;
        s += L' ';
        dotPrefix.push_back(kDot);
        dotPrefix.push_back(L' ');
      }
      s += ln.text;
      size_t tabIdx = ln.text.find(L'\t');
      if (tabIdx != std::wstring::npos) {
        float w = MeasureWidth(prefix + dotPrefix + ln.text.substr(0, tabIdx));
        if (w > maxCol1) maxCol1 = w;
      }
    }
    content_ = s;
    layout_.Reset();
    if (FAILED(dwrite_->CreateTextLayout(content_.c_str(), (UINT32)content_.size(),
                                         textFormat_.Get(), 100000.0f, 100000.0f,
                                         layout_.GetAddressOf()))) {
      return;
    }
    layout_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_NEAR);  // 顶对齐(覆写)
    if (maxCol1 > 0.0f) {
      // 增量制表位 > 最长第一列 → 每行 \t 都推进到同一制表位 x,重置列全局对齐。
      layout_->SetIncrementalTabStop(maxCol1 + kTabGap);
    }
    DWRITE_TEXT_METRICS dm = {};
    layout_->GetMetrics(&dm);
    contentWidth_ = dm.widthIncludingTrailingWhitespace;
    contentHeight_ = dm.height;
    for (const auto& mk : marks) {
      layout_->SetDrawingEffect(ColorBrush(mk.color),
                                DWRITE_TEXT_RANGE{mk.start, 1});
    }
    layoutDirty_ = false;
  }

  void UpdateScrollState() {
    bool want = !multiline_ && scrollPref_ && contentWidth_ > width_;
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

    float logicalW, logicalH;
    CurrentLogicalSize(&logicalW, &logicalH);
    int physW, physH;
    CurrentPhysSize(&physW, &physH);
    EnsureDib(physW, physH);

    RECT rc = {0, 0, physW, physH};
    if (FAILED(target_->BindDC(memDC_, &rc))) return;
    target_->SetDpi((float)dpi_, (float)dpi_);
    target_->BeginDraw();
    target_->SetTransform(D2D1::Matrix3x2F::Identity());
    target_->Clear(D2D1::ColorF(0, 0, 0, 0));

    D2D1_ROUNDED_RECT rr = {{0.5f, 0.5f, logicalW - 0.5f, logicalH - 0.5f}, kCorner,
                            kCorner};
    target_->FillRoundedRectangle(rr, bgBrush_.Get());
    target_->DrawRoundedRectangle(rr, outlineBrush_.Get(), 1.0f);

    if (multiline_) {
      // 多行:顶对齐铺开,不裁剪不滚动(超出卡片宽的极端长行由 DIB 边界自然截断)。
      if (layout_)
        target_->DrawTextLayout(D2D1::Point2F(kPadX, kPadYMulti), layout_.Get(),
                                textBrush_.Get());
    } else {
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
    }

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
  float lastWidthArg_ = -1.0f;  // 上次 Dart 推来的目标宽;仅其变化时才覆盖 width_(见 Apply)
  double pps_ = 100.0;
  bool scrollPref_ = false;
  bool scrolling_ = false;
  double offset_ = 0;
  bool multiline_ = false;       // 显示模式:false=单行滚动,true=多行铺开
  bool posIsDefault_ = false;    // 位置是否取默认(尺寸变化时随之重算贴右下角)
  bool hideOnFullscreen_ = false;
  bool fsHidden_ = false;
  bool shown_ = false;
  bool dark_ = false;  // 明暗:由 app 主题设置决定(每次 update 传入)

  std::vector<Seg> segs_;
  std::vector<Line> lines_;          // 多行模式内容
  std::wstring content_;
  float contentWidth_ = 0;
  float contentHeight_ = kHeight;    // 多行模式内容总高(逻辑 DIP)
  bool layoutDirty_ = true;

  // 拖拽 / 边缘拉伸
  bool tracking_ = false;
  bool dragged_ = false;
  POINT downPt_ = {0, 0};
  POINT winAtDown_ = {0, 0};
  int resizeEdge_ = 0;     // 本次按下命中的拉伸边:0=无(走移动)/ 1=左 / 2=右
  float widthAtDown_ = 0;  // 按下时的 width_(逻辑 DIP),拉伸按绝对位移计算避免漂移
  UINT dpiAtDown_ = 96;    // 按下时的 DPI:整个拉伸手势用同一 scale,避免中途跨屏失配
  HMONITOR monAtDown_ = nullptr;  // 按下时所在显示器:拉伸全程按它算整屏宽上限

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
          // 返回原生当前实际宽度(逻辑像素):用户拖拽边缘改宽后,这里会与 Dart 推下去的
          // 宽不同;Dart 据此把配置同步过来(走可靠的 Dart→native 返回值,不依赖
          // native→Dart 的 onResized 回调)。
          result->Success(flutter::EncodableValue(g_ticker->CurrentWidth()));
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
