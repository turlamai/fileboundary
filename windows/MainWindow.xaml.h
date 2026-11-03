#pragma once

#include "pch.h"
#include "MainWindow.g.h"
#include "system_services.hpp"
#include "winui_window.hpp"

namespace winrt::RivetHost::implementation {

struct MainWindow : MainWindowT<MainWindow> {
  MainWindow();

  // Stable HWND access for platform-owned features such as global hotkeys,
  // clipboard listeners, window subclassing, topmost policy, and tray icons.
  [[nodiscard]] HWND WindowHandle() {
    return rivet::system::NativeWindowHandle(*this);
  }

  // Thread-safe orderly backend stop shared by the window-close path and
  // the console-control shutdown hook (logoff/CTRL events).
  void StopBackendOrderly();

  // Panel actions.
  void Scan_Click(winrt::Windows::Foundation::IInspectable const& sender,
                  Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void Doctor_Click(winrt::Windows::Foundation::IInspectable const& sender,
                    Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void Verify_Click(winrt::Windows::Foundation::IInspectable const& sender,
                    Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void Decrypt_Click(winrt::Windows::Foundation::IInspectable const& sender,
                     Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void Twin_Click(winrt::Windows::Foundation::IInspectable const& sender,
                  Microsoft::UI::Xaml::RoutedEventArgs const& args);

  // Navigation + file pickers + result copy.
  void Nav_SelectionChanged(
      winrt::Windows::Foundation::IInspectable const& sender,
      Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const& args);
  void PathBox_KeyDown(winrt::Windows::Foundation::IInspectable const& sender,
                       Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const& args);
  void BrowseScan_Click(winrt::Windows::Foundation::IInspectable const& sender,
                        Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void BrowseVerifyOriginal_Click(
      winrt::Windows::Foundation::IInspectable const& sender,
      Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void BrowseVerifyExport_Click(
      winrt::Windows::Foundation::IInspectable const& sender,
      Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void BrowseDecryptInput_Click(
      winrt::Windows::Foundation::IInspectable const& sender,
      Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void BrowseDecryptOutput_Click(
      winrt::Windows::Foundation::IInspectable const& sender,
      Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void BrowseTwinPlain_Click(winrt::Windows::Foundation::IInspectable const& sender,
                             Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void BrowseTwinCipher_Click(winrt::Windows::Foundation::IInspectable const& sender,
                              Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void BrowseTwinOutput_Click(winrt::Windows::Foundation::IInspectable const& sender,
                              Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void CopyResult_Click(winrt::Windows::Foundation::IInspectable const& sender,
                        Microsoft::UI::Xaml::RoutedEventArgs const& args);

 private:
  winrt::fire_and_forget InitializeBackendAsync();
  void RunScanAsync();
  void RunDoctorAsync();
  void RunVerifyAsync();
  void RunDecryptAsync();
  void RunTwinAsync();
  void SetBusyUi(bool busy);
  void ShowPanel(std::wstring const& tag);
  void ShowTextResult(std::wstring const& title, winrt::hstring const& body,
                      Microsoft::UI::Xaml::Controls::InfoBarSeverity severity,
                      std::wstring const& status_message);
  void ShowDecryptResult(std::string const& json);
  void ShowTwinResult(std::string const& json);
  void ShowFailed(std::string const& what);
  void SetReadyUi();
  void SetErrorUi(std::string const& message);

  std::shared_ptr<rivet::windows::Backend> backend_;
  winrt::hstring last_result_text_;
};

}  // namespace winrt::RivetHost::implementation

namespace winrt::RivetHost::factory_implementation {

struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow> {};

}  // namespace winrt::RivetHost::factory_implementation
