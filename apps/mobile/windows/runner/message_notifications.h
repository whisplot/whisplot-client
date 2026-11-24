#ifndef RUNNER_MESSAGE_NOTIFICATIONS_H_
#define RUNNER_MESSAGE_NOTIFICATIONS_H_

#include <windows.h>
#include <flutter/method_channel.h>

#include <string>

class WindowsMessageNotifications {
 public:
  WindowsMessageNotifications(HWND window, flutter::BinaryMessenger* messenger);
  ~WindowsMessageNotifications();
  bool HandleWindowMessage(UINT message, LPARAM event);

 private:
  void Handle(const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Clear();
  bool Show(const std::string& token, bool sound);

  HWND window_;
  UINT taskbar_created_;
  flutter::MethodChannel<flutter::EncodableValue> channel_;
  bool enabled_;
  bool registered_ = false;
  std::string current_token_;
};
#endif  // RUNNER_MESSAGE_NOTIFICATIONS_H_
