#include "pch.h"
#include "MainWindow.xaml.h"
#if __has_include("MainWindow.g.cpp")
#include "MainWindow.g.cpp"
#endif
#include "GeneratedBackend.hpp"

#include <cstdint>
#include <stdexcept>

#include <winrt/Microsoft.UI.Windowing.h>

namespace winrt::RivetHost::implementation {
namespace {

std::filesystem::path executable_path() {
  std::wstring buffer(32768, L'\0');
  auto const length = ::GetModuleFileNameW(nullptr, buffer.data(),
                                          static_cast<DWORD>(buffer.size()));
  if (length == 0 || length == buffer.size()) {
    throw std::runtime_error("GetModuleFileNameW failed");
  }
  buffer.resize(length);
  return std::filesystem::path(buffer);
}

std::string utf8(std::filesystem::path const& path) {
  auto const wide = path.wstring();
  if (wide.empty()) {
    return {};
  }
  auto const size = ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                          wide.data(),
                                          static_cast<int>(wide.size()),
                                          nullptr, 0, nullptr, nullptr);
  if (size <= 0) {
    throw std::runtime_error("WideCharToMultiByte failed");
  }
  std::string result(static_cast<std::size_t>(size), '\0');
  if (::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                            wide.data(), static_cast<int>(wide.size()),
                            result.data(), size, nullptr, nullptr) != size) {
    throw std::runtime_error("WideCharToMultiByte failed");
  }
  return result;
}

rivet::windows::RacketRuntimeConfig runtime_config() {
  auto const exe = executable_path();
  auto const root = exe.parent_path();
  auto const runtime = root / L"runtime";

  rivet::windows::RacketRuntimeConfig config;
  config.executable_path = utf8(exe);
  config.petite_boot = utf8(runtime / L"petite.boot");
  config.scheme_boot = utf8(runtime / L"scheme.boot");
  config.racket_boot = utf8(runtime / L"racket.boot");
  config.backend_bundle = utf8(root / L"res" / L"core.zo");
  config.module_name = rivet_app::kModuleName;
  config.entry_symbol = rivet_app::kEntryName;
  config.dll_dir = runtime.wstring();
  return config;
}

}  // namespace

MainWindow::MainWindow() {
  InitializeComponent();
  Title(L"FileBoundary");
  // WinUI shows a generic placeholder in the title bar unless the
  // window is handed an icon explicitly; rivet embeds the project
  // icon in the exe at resource ID 1 (rivet-cli/build.rkt), so
  // surface it here. Projects without a windows-icon declaration
  // keep the placeholder.
  if (HICON const icon =
          ::LoadIconW(::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(1))) {
    AppWindow().SetIcon(winrt::Microsoft::UI::IconId{
        static_cast<std::uint64_t>(reinterpret_cast<UINT_PTR>(icon))});
  }
  // Ordinary window close and OS session end (logoff/shutdown) both funnel
  // into the same orderly backend stop. The console-control callback runs
  // on its own thread, so it only touches the thread-safe stop() — never
  // XAML state.
  Closed([this](auto const&, auto const&) { StopBackendOrderly(); });
  try {
    rivet::system::InstallShutdownHook([this] { StopBackendOrderly(); });
  } catch (std::exception const&) {
    // Signal coverage is platform policy and never blocks startup; the
    // window-close path above still runs the orderly shutdown.
  }
  InitializeBackendAsync();
}

void MainWindow::StopBackendOrderly() {
  if (auto backend = std::atomic_load(&backend_); backend != nullptr) {
    backend->stop();
  }
}


winrt::fire_and_forget MainWindow::InitializeBackendAsync() {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = std::make_shared<rivet::windows::Backend>(runtime_config());
  try {
    co_await winrt::resume_background();
    backend->start();
    dispatcher.TryEnqueue([weak, backend = std::move(backend)]() mutable {
      if (auto window = weak.get()) {
        window->backend_ = std::move(backend);
        window->SetReadyUi();
      } else {
        std::thread([backend = std::move(backend)]() mutable {
          backend->stop();
        }).detach();
      }
    });
  } catch (std::exception const& e) {
    auto message = std::string(e.what());
    dispatcher.TryEnqueue([weak, message = std::move(message)] {
      if (auto window = weak.get()) window->SetErrorUi(message);
    });
  }
}

void MainWindow::Scan_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  RunScanAsync();
}

void MainWindow::Doctor_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  RunDoctorAsync();
}

void MainWindow::Verify_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  RunVerifyAsync();
}

void MainWindow::SetBusyUi(bool busy) {
  ScanButton().IsEnabled(!busy && backend_ && backend_->running());
  DoctorButton().IsEnabled(!busy && backend_ && backend_->running());
  VerifyButton().IsEnabled(!busy && backend_ && backend_->running());
  if (busy) {
    StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Informational);
    StatusBar().Message(L"Read-only operation running...");
  }
}

void MainWindow::RunScanAsync() {
  auto backend = backend_;
  if (!backend || !backend->running()) {
    SetErrorUi("Racket backend not running");
    return;
  }
  auto const path = winrt::to_string(PathBox().Text());
  if (path.empty()) {
    SetErrorUi("Choose a file or directory path");
    return;
  }
  SetBusyUi(true);
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  try {
    rivet_app::API api(*backend);
    (void)api.scan_summary_async(path,
        [dispatcher, weak](rivet_app::Result<std::string> result) mutable {
          try {
            auto message = result.get();
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) window->ShowResult(message);
            });
          } catch (std::exception const& e) {
            auto error = std::string(e.what());
            dispatcher.TryEnqueue([weak, error = std::move(error)] {
              if (auto window = weak.get()) window->SetErrorUi(error);
            });
          }
        });
  } catch (std::exception const& e) {
    SetErrorUi(e.what());
  }
}

void MainWindow::RunDoctorAsync() {
  auto backend = backend_;
  if (!backend || !backend->running()) {
    SetErrorUi("Racket backend not running");
    return;
  }
  SetBusyUi(true);
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  try {
    rivet_app::API api(*backend);
    (void)api.doctor_summary_async(
        [dispatcher, weak](rivet_app::Result<std::string> result) mutable {
          try {
            auto message = result.get();
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) window->ShowResult(message);
            });
          } catch (std::exception const& e) {
            auto error = std::string(e.what());
            dispatcher.TryEnqueue([weak, error = std::move(error)] {
              if (auto window = weak.get()) window->SetErrorUi(error);
            });
          }
        });
  } catch (std::exception const& e) {
    SetErrorUi(e.what());
  }
}

void MainWindow::RunVerifyAsync() {
  auto backend = backend_;
  if (!backend || !backend->running()) {
    SetErrorUi("Racket backend not running");
    return;
  }
  auto const original = winrt::to_string(PathBox().Text());
  auto const exported = winrt::to_string(ExportPathBox().Text());
  if (original.empty() || exported.empty()) {
    SetErrorUi("Select both the encrypted original and the approved export");
    return;
  }
  SetBusyUi(true);
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  try {
    rivet_app::API api(*backend);
    (void)api.verify_export_summary_async(original, exported,
        [dispatcher, weak](rivet_app::Result<std::string> result) mutable {
          try {
            auto message = result.get();
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) window->ShowResult(message);
            });
          } catch (std::exception const& e) {
            auto error = std::string(e.what());
            dispatcher.TryEnqueue([weak, error = std::move(error)] {
              if (auto window = weak.get()) window->SetErrorUi(error);
            });
          }
        });
  } catch (std::exception const& e) {
    SetErrorUi(e.what());
  }
}

void MainWindow::ShowResult(std::string const& message) {
  OutputText().Text(winrt::to_hstring(message));
  SetBusyUi(false);
  if (message.rfind("Authorized export comparison: FAILED", 0) == 0 ||
      message.rfind("Authorized export comparison: ERROR", 0) == 0) {
    StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Error);
    StatusBar().Message(L"Export check failed or could not complete. No files were changed.");
  } else if (message.rfind("Authorized export comparison: UNVERIFIED", 0) == 0) {
    StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Warning);
    StatusBar().Message(L"Export is unverified, not confirmed as decrypted.");
  } else {
    StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Success);
    StatusBar().Message(L"Read-only operation finished");
  }
}

void MainWindow::SetReadyUi() {
  SetBusyUi(false);
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Success);
  StatusBar().Message(L"Embedded Racket CS ready");
}

void MainWindow::SetErrorUi(std::string const& message) {
  SetBusyUi(false);
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Error);
  StatusBar().Message(winrt::to_hstring(message));
}

}  // namespace winrt::RivetHost::implementation
