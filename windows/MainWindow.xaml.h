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
  // Update panel actions (flow lives in MainWindow.Update.cpp).
  void UpdateCheck_Click(winrt::Windows::Foundation::IInspectable const& sender,
                         Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void UpdateCancel_Click(winrt::Windows::Foundation::IInspectable const& sender,
                          Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void UpdateAutoCheck_Toggled(
      winrt::Windows::Foundation::IInspectable const& sender,
      Microsoft::UI::Xaml::RoutedEventArgs const& args);

  // Navigation + file pickers + result copy.
  void Nav_SelectionChanged(
      winrt::Windows::Foundation::IInspectable const& sender,
      Microsoft::UI::Xaml::Controls::NavigationViewSelectionChangedEventArgs const& args);
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
  void BrowseDecryptPad_Click(
      winrt::Windows::Foundation::IInspectable const& sender,
      Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void BrowseTwinPlain_Click(winrt::Windows::Foundation::IInspectable const& sender,
                             Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void BrowseTwinCipher_Click(winrt::Windows::Foundation::IInspectable const& sender,
                              Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void BrowseTwinOutput_Click(winrt::Windows::Foundation::IInspectable const& sender,
                              Microsoft::UI::Xaml::RoutedEventArgs const& args);
  // Drag-and-drop a file from Explorer onto any path input box.
  // WinUI 3 keeps DragEventArgs/DataPackage types in Microsoft::UI::Xaml.
  void FileBox_DragOver(winrt::Windows::Foundation::IInspectable const& sender,
                        winrt::Microsoft::UI::Xaml::DragEventArgs const& args);
  void FileBox_Drop(winrt::Windows::Foundation::IInspectable const& sender,
                    winrt::Microsoft::UI::Xaml::DragEventArgs const& args);
  void ResultCollapse_Click(winrt::Windows::Foundation::IInspectable const& sender,
                            Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void CopyResult_Click(winrt::Windows::Foundation::IInspectable const& sender,
                        Microsoft::UI::Xaml::RoutedEventArgs const& args);

  // Result card writer, callable from the free drop-handler functions.
  void ShowTextResult(std::wstring const& title, winrt::hstring const& body,
                      Microsoft::UI::Xaml::Controls::InfoBarSeverity severity,
                      std::wstring const& status_message);

 private:
  winrt::fire_and_forget InitializeBackendAsync();
  void RunScanAsync();
  void RunDoctorAsync();
  void RunVerifyAsync();
  void RunDecryptAsync();
  void RunTwinAsync();
  void SetBusyUi(bool busy);
  void SetResultCollapsed(bool collapsed);
  void ShowPanel(std::wstring const& tag);
  void ShowDecryptResult(std::string const& json);
  void ShowTwinResult(std::string const& json);
  void ShowFailed(std::string const& what);
  void SetReadyUi();
  void SetErrorUi(std::string const& message);

  // Online update flow (MainWindow.Update.cpp, update contract).
  winrt::fire_and_forget AutoCheckUpdatesAsync();
  void RunSilentUpdateCheck();
  void RunUpdateCheck(bool silent);
  void ContinueUpdateCheck(bool silent);
  void HandleUpdateCheckResult(std::string const& check_json,
                               std::string const& failure, bool silent);
  void StartDownload();
  void PollUpdateState(
      std::shared_ptr<rivet::windows::Backend> const& backend);
  void HandleUpdatePoll(std::string const& json);
  void FailDownload(std::string const& message);
  winrt::fire_and_forget ShowInstallConsent(std::wstring const& path);
  void InstallDownloadedUpdate(std::wstring const& update_path);
  void HandleInstallMarkers();
  bool IsDevCopy();
  bool IsMsiInstall();
  winrt::fire_and_forget ShowUpdateDialog(
      std::wstring const& title, std::wstring const& body,
      std::wstring const& primary_button, std::wstring const& close_button,
      std::function<void()> on_primary,
      std::wstring const& copy_button = L"");
  void LoadAutoCheckUpdatesSetting();
  void RefreshUpdateVersionLabel();
  void SaveUpdateSetting(std::wstring const& key, std::wstring const& value);
  winrt::fire_and_forget ShowAboutDialog();

  std::shared_ptr<rivet::windows::Backend> backend_;
  winrt::hstring last_result_text_;
  // Elevation blocks Explorer drag-drop (UIPI); surfaced in SetReadyUi.
  bool running_elevated_ = false;
  // Update flow state: one active download, its start time (the host-side
  // 30-min watchdog), the auto-check toggle, and the progress poll timer.
  bool update_downloading_ = false;
  std::int64_t update_download_start_ = 0;
  bool auto_check_updates_ = true;
  winrt::Microsoft::UI::Xaml::DispatcherTimer update_timer_{nullptr};
  // Shell state: the running version (title + About dialog) and the last
  // real panel item so the About footer entry can restore the selection.
  std::wstring current_version_;
  winrt::Microsoft::UI::Xaml::Controls::NavigationViewItem last_nav_item_{
      nullptr};
};

}  // namespace winrt::RivetHost::implementation

namespace winrt::RivetHost::factory_implementation {

struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow> {};

}  // namespace winrt::RivetHost::factory_implementation
