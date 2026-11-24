#include "message_notifications.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <algorithm>

#include "resource.h"

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;
constexpr UINT kTrayMessage = WM_APP + 72;
constexpr wchar_t kSettingsKey[] = L"Software\\Whisplot";
constexpr wchar_t kEnabledValue[] = L"MessageNotificationsEnabled";

bool EnabledPreference() {
  DWORD value = 1;
  DWORD size = sizeof(value);
  return RegGetValueW(HKEY_CURRENT_USER, kSettingsKey, kEnabledValue,
                     RRF_RT_REG_DWORD, nullptr, &value, &size) != ERROR_SUCCESS ||
         value != 0;
}

bool SavePreference(bool enabled) {
  const DWORD value = enabled ? 1 : 0;
  return RegSetKeyValueW(HKEY_CURRENT_USER, kSettingsKey, kEnabledValue,
                        REG_DWORD, &value, sizeof(value)) == ERROR_SUCCESS;
}

NOTIFYICONDATAW TrayData(HWND window) {
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window;
  data.uID = 1;
  return data;
}

template <typename T>
const T* Argument(const EncodableMap* args, const char* key) {
  if (!args) return nullptr;
  const auto found = args->find(EncodableValue(key));
  return found == args->end() ? nullptr : std::get_if<T>(&found->second);
}

bool ValidToken(const std::string* token) {
  return token && token->size() == 24 &&
         std::all_of(token->begin(), token->end(), [](char c) {
           return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') ||
                  (c >= 'a' && c <= 'z') || c == '-' || c == '_';
         });
}
}  // namespace

WindowsMessageNotifications::WindowsMessageNotifications(
    HWND window, flutter::BinaryMessenger* messenger)
    : window_(window),
      taskbar_created_(RegisterWindowMessageW(L"TaskbarCreated")),
      channel_(messenger, "nearlink/message_notifications",
               &flutter::StandardMethodCodec::GetInstance()),
      enabled_(EnabledPreference()) {
  channel_.SetMethodCallHandler(
      [this](const auto& call, auto result) { Handle(call, std::move(result)); });
}

WindowsMessageNotifications::~WindowsMessageNotifications() {
  channel_.SetMethodCallHandler(nullptr);
  Clear();
}

void WindowsMessageNotifications::Handle(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto& method = call.method_name();
  const auto* args = call.arguments()
                         ? std::get_if<EncodableMap>(call.arguments())
                         : nullptr;
  const bool no_args = !call.arguments() || call.arguments()->IsNull();
  const auto reply_state = [this, &result] {
    result->Success(EncodableValue(EncodableMap{
        {EncodableValue("enabled"), EncodableValue(enabled_)},
        {EncodableValue("granted"), EncodableValue(GetShellWindow() != nullptr)},
        {EncodableValue("prompted"), EncodableValue(true)},
        {EncodableValue("canRequest"), EncodableValue(false)},
    }));
  };
  if (method == "state" && no_args) {
    reply_state();
    return;
  }
  if (method == "setEnabled" && args && args->size() == 1) {
    const auto* enabled = Argument<bool>(args, "enabled");
    if (enabled) {
      if (!SavePreference(*enabled)) {
        result->Error("NOTIFICATION_SETTINGS", "Could not save notification settings.");
        return;
      }
      enabled_ = *enabled;
      if (!enabled_) Clear();
      reply_state();
      return;
    }
  }
  if (method == "openSettings" && no_args) {
    const auto launched = reinterpret_cast<INT_PTR>(ShellExecuteW(
        window_, L"open", L"ms-settings:notifications", nullptr, nullptr, SW_SHOWNORMAL));
    if (launched > 32) result->Success();
    else result->Error("NOTIFICATION_SETTINGS", "Could not open Windows notification settings.");
    return;
  }
  if (method == "clearAll" && no_args) {
    Clear();
    result->Success();
    return;
  }
  if (method == "clear" || method == "show") {
    const auto* token = Argument<std::string>(args, "token");
    if (ValidToken(token)) {
      if (method == "clear" && args->size() == 2) {
        if (*token == current_token_) Clear();
        result->Success();
        return;
      }
      const auto* sound = Argument<bool>(args, "sound");
      if (method == "show" && args->size() == 4 && sound) {
        if (!enabled_ || Show(*token, *sound)) result->Success();
        else result->Error("NOTIFICATION_FAILED", "Could not deliver a Windows notification.");
        return;
      }
    }
  } else if (method != "state" && method != "setEnabled" &&
             method != "openSettings" && method != "clearAll") {
    result->NotImplemented();
    return;
  }
  result->Error("INVALID_ARGUMENTS", "Invalid notification arguments.");
}

bool WindowsMessageNotifications::Show(const std::string& token, bool sound) {
  auto data = TrayData(window_);
  if (!registered_) {
    data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    data.uCallbackMessage = kTrayMessage;
    data.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
    wcscpy_s(data.szTip, L"Whisplot");
    if (!Shell_NotifyIconW(NIM_ADD, &data)) return false;
    registered_ = true;
  }
  data = TrayData(window_);
  data.uFlags = NIF_INFO;
  data.dwInfoFlags = NIIF_INFO | NIIF_RESPECT_QUIET_TIME | (sound ? 0 : NIIF_NOSOUND);
  wcscpy_s(data.szInfoTitle, L"Whisplot");
  wcscpy_s(data.szInfo, PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_CHINESE
                            ? L"\u4f60\u6709\u65b0\u6d88\u606f"
                            : L"You have new messages");
  if (!Shell_NotifyIconW(NIM_MODIFY, &data)) return false;
  current_token_ = token;
  return true;
}

void WindowsMessageNotifications::Clear() {
  if (registered_) {
    auto data = TrayData(window_);
    Shell_NotifyIconW(NIM_DELETE, &data);
    registered_ = false;
  }
  current_token_.clear();
}

bool WindowsMessageNotifications::HandleWindowMessage(UINT message, LPARAM event) {
  if (taskbar_created_ && message == taskbar_created_) {
    registered_ = false;
    current_token_.clear();
    return false;
  }
  if (message != kTrayMessage) return false;
  if (event == NIN_BALLOONUSERCLICK) {
    // The shell may queue balloons. Restore Whisplot without guessing a group.
    ShowWindow(window_, SW_RESTORE);
    SetForegroundWindow(window_);
  }
  return true;
}
