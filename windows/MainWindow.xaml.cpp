#include "pch.h"
#include "MainWindow.xaml.h"
#if __has_include("MainWindow.g.cpp")
#include "MainWindow.g.cpp"
#endif
#include "GeneratedBackend.hpp"

#include <cstdint>
#include <stdexcept>

#include <ShObjIdl_core.h>

#include <winrt/Microsoft.UI.Windowing.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include <winrt/Windows.ApplicationModel.DataTransfer.h>
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Graphics.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Pickers.h>
#include <winrt/Windows.System.h>

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
  // Comfortable default; the layout is fluid and scrolls on smaller sizes.
  AppWindow().ResizeClient(winrt::Windows::Graphics::SizeInt32{980, 660});
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

// ---------------- navigation ----------------

void MainWindow::Nav_SelectionChanged(
    winrt::Windows::Foundation::IInspectable const& sender,
    Microsoft::UI::Xaml::Controls::NavigationViewSelectionChangedEventArgs const&) {
  auto nav = sender.try_as<Microsoft::UI::Xaml::Controls::NavigationView>();
  if (!nav) {
    return;
  }
  auto item = nav.SelectedItem().try_as<Microsoft::UI::Xaml::Controls::NavigationViewItem>();
  if (!item) {
    return;
  }
  ShowPanel(std::wstring{winrt::unbox_value<winrt::hstring>(item.Tag()).c_str()});
}

void MainWindow::ShowPanel(std::wstring const& tag) {
  // a result belongs to the panel that produced it: switching panels
  // retires it, otherwise a stale '诊断完成' card follows the user around
  ResultCard().Visibility(Microsoft::UI::Xaml::Visibility::Collapsed);
  PanelScan().Visibility(tag == L"scan" ? Microsoft::UI::Xaml::Visibility::Visible
                                        : Microsoft::UI::Xaml::Visibility::Collapsed);
  PanelDoctor().Visibility(tag == L"doctor" ? Microsoft::UI::Xaml::Visibility::Visible
                                            : Microsoft::UI::Xaml::Visibility::Collapsed);
  PanelVerify().Visibility(tag == L"verify" ? Microsoft::UI::Xaml::Visibility::Visible
                                            : Microsoft::UI::Xaml::Visibility::Collapsed);
  PanelDecrypt().Visibility(tag == L"decrypt" ? Microsoft::UI::Xaml::Visibility::Visible
                                              : Microsoft::UI::Xaml::Visibility::Collapsed);
  PanelTwin().Visibility(tag == L"twin" ? Microsoft::UI::Xaml::Visibility::Visible
                                        : Microsoft::UI::Xaml::Visibility::Collapsed);
  PanelUpdate().Visibility(tag == L"update" ? Microsoft::UI::Xaml::Visibility::Visible
                                            : Microsoft::UI::Xaml::Visibility::Collapsed);
}

void MainWindow::RunUpdateCheckAsync() {
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
    (void)api.update_check_summary_async("",
        [dispatcher, weak](rivet_app::Result<std::string> result) mutable {
          try {
            auto message = result.get();
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) window->ShowTextResult(
                    L"检查更新完成",
                    winrt::to_hstring(message),
                    Microsoft::UI::Xaml::Controls::InfoBarSeverity::Informational,
                    L"检查完成。");
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

// ---------------- file pickers ----------------

// Desktop WinUI 3 pickers must be HWND-associated or they silently no-op.
// XAML Click handlers return void, so the coroutine bodies live in the
// free functions below; PickSingleFileAsync/PickSaveFileAsync may resume
// on a background thread, and the WinAppSDK DispatcherQueue has no
// resume_foreground in this projection - completion hops via TryEnqueue.
namespace {

winrt::fire_and_forget PickOpenInto(Microsoft::UI::Xaml::Controls::TextBox box,
                                    HWND hwnd,
                                    Microsoft::UI::Dispatching::DispatcherQueue dq) {
  try {
    winrt::Windows::Storage::Pickers::FileOpenPicker picker;
    picker.FileTypeFilter().ReplaceAll({L"*"});
    picker.as<::IInitializeWithWindow>()->Initialize(hwnd);
    auto file = co_await picker.PickSingleFileAsync();
    dq.TryEnqueue([box, file]() mutable {
      if (file) {
        box.Text(file.Path());
      }
    });
  } catch (...) {
    // A cancelled picker is not an error; anything else stays silent here.
  }
}

winrt::fire_and_forget PickSaveInto(
    Microsoft::UI::Xaml::Controls::TextBox box, HWND hwnd,
    Microsoft::UI::Dispatching::DispatcherQueue dq, winrt::hstring suggested,
    std::vector<std::pair<winrt::hstring, std::vector<winrt::hstring>>> const&
        choices) {
  try {
    winrt::Windows::Storage::Pickers::FileSavePicker picker;
    picker.SuggestedFileName(suggested);
    for (auto const& [label, extensions] : choices) {
      std::vector<winrt::hstring> copy(extensions);
      picker.FileTypeChoices().Insert(
          label, winrt::single_threaded_vector<winrt::hstring>(std::move(copy)));
    }
    picker.as<::IInitializeWithWindow>()->Initialize(hwnd);
    auto file = co_await picker.PickSaveFileAsync();
    dq.TryEnqueue([box, file]() mutable {
      if (file) {
        box.Text(file.Path());
      }
    });
  } catch (...) {
  }
}

}  // namespace

void MainWindow::BrowseScan_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  PickOpenInto(PathBox(), WindowHandle(), DispatcherQueue());
}

void MainWindow::BrowseVerifyOriginal_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  PickOpenInto(VerifyOriginalBox(), WindowHandle(), DispatcherQueue());
}

void MainWindow::BrowseVerifyExport_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  PickOpenInto(VerifyExportBox(), WindowHandle(), DispatcherQueue());
}

void MainWindow::BrowseDecryptInput_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  PickOpenInto(DecryptInputBox(), WindowHandle(), DispatcherQueue());
}

void MainWindow::BrowseDecryptOutput_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  // Type choices give the dialog a sane filter without restricting the
  // written bytes (the engine writes what it writes).
  PickSaveInto(
      DecryptOutputBox(), WindowHandle(), DispatcherQueue(), L"decrypted",
      {{L"文档", {L".docx", L".xlsx", L".pptx"}}, {L"PDF", {L".pdf"}}});
}

void MainWindow::BrowseDecryptPad_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  PickOpenInto(DecryptPadBox(), WindowHandle(), DispatcherQueue());
}

void MainWindow::BrowseTwinPlain_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  PickOpenInto(TwinPlainBox(), WindowHandle(), DispatcherQueue());
}

void MainWindow::BrowseTwinCipher_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  PickOpenInto(TwinCipherBox(), WindowHandle(), DispatcherQueue());
}

void MainWindow::BrowseTwinOutput_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  PickSaveInto(TwinOutputBox(), WindowHandle(), DispatcherQueue(),
               L"fileboundary-key",
               {{L"密钥文件", {L".json"}}});
}

// ---------------- panel actions ----------------

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

void MainWindow::Decrypt_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  RunDecryptAsync();
}

void MainWindow::Twin_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  RunTwinAsync();
}

void MainWindow::UpdateCheck_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  RunUpdateCheckAsync();
}

void MainWindow::PathBox_KeyDown(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const& args) {
  if (args.Key() == winrt::Windows::System::VirtualKey::Enter) {
    RunScanAsync();
  }
}

void MainWindow::CopyResult_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  try {
    winrt::Windows::ApplicationModel::DataTransfer::DataPackage package;
    package.SetText(last_result_text_);
    winrt::Windows::ApplicationModel::DataTransfer::Clipboard::SetContent(package);
  } catch (...) {
    // Clipboard access can fail on locked-down sessions; not worth a dialog.
  }
}

void MainWindow::SetBusyUi(bool busy) {
  ScanButton().IsEnabled(!busy && backend_ && backend_->running());
  DoctorButton().IsEnabled(!busy && backend_ && backend_->running());
  VerifyButton().IsEnabled(!busy && backend_ && backend_->running());
  DecryptButton().IsEnabled(!busy && backend_ && backend_->running());
  TwinButton().IsEnabled(!busy && backend_ && backend_->running());
  // the banner only speaks while something is happening; an idle app
  // stays quiet (owner feedback: the permanent ready banner is noise)
  StatusBar().IsOpen(busy);
  if (busy) {
    StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Informational);
    StatusBar().Message(L"正在处理，请稍候...");
  }
}

// ---------------- async runs ----------------

void MainWindow::RunScanAsync() {
  auto backend = backend_;
  if (!backend || !backend->running()) {
    SetErrorUi("Racket backend not running");
    return;
  }
  auto const path = winrt::to_string(PathBox().Text());
  if (path.empty()) {
    SetErrorUi("Choose a file or directory path first");
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
              if (auto window = weak.get()) {
                window->ShowTextResult(
                    L"扫描完成",
                    winrt::to_hstring(message),
                    Microsoft::UI::Xaml::Controls::InfoBarSeverity::Success,
                    L"扫描完成：识别出加密壳不代表文件已解密。");
              }
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
              if (auto window = weak.get()) {
                window->ShowTextResult(
                    L"诊断完成",
                    winrt::to_hstring(message),
                    Microsoft::UI::Xaml::Controls::InfoBarSeverity::Success,
                    L"诊断完成：这只是枚举结果，不代表加密状态。");
              }
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
  auto const original = winrt::to_string(VerifyOriginalBox().Text());
  auto const exported = winrt::to_string(VerifyExportBox().Text());
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
              if (auto window = weak.get()) {
                if (message.rfind("Authorized export comparison: FAILED", 0) == 0 ||
                    message.rfind("Authorized export comparison: ERROR", 0) == 0) {
                  window->ShowTextResult(
                      L"比对结论：导出文件仍是加密状态（FAILED）",
                      winrt::to_hstring(message),
                      Microsoft::UI::Xaml::Controls::InfoBarSeverity::Error,
                      L"导出比对未通过。任何情况下都不要删除加密原文件。");
                } else {
                  window->ShowTextResult(
                      L"比对结论：未发现阻碍（UNVERIFIED）",
                      winrt::to_hstring(message),
                      Microsoft::UI::Xaml::Controls::InfoBarSeverity::Warning,
                      L"UNVERIFIED 不代表解密成功。请在授权的阅读器里独立验证导出文件。");
                }
              }
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

void MainWindow::RunDecryptAsync() {
  auto backend = backend_;
  if (!backend || !backend->running()) {
    SetErrorUi("Racket backend not running");
    return;
  }
  auto const input = winrt::to_string(DecryptInputBox().Text());
  auto const output = winrt::to_string(DecryptOutputBox().Text());
  auto const pad = winrt::to_string(DecryptPadBox().Text());
  if (input.empty() || output.empty() || pad.empty()) {
    SetErrorUi("选择加密文件、输出位置和密钥文件 / Choose the encrypted file, the output location and the key file");
    return;
  }
  SetBusyUi(true);
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  try {
    rivet_app::API api(*backend);
    (void)api.decrypt_summary_async(input, output, pad,
        [dispatcher, weak](rivet_app::Result<std::string> result) mutable {
          try {
            auto message = result.get();
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) window->ShowDecryptResult(message);
            });
          } catch (std::exception const& e) {
            auto error = std::string(e.what());
            dispatcher.TryEnqueue([weak, error = std::move(error)] {
              if (auto window = weak.get()) {
                window->ShowFailed(error);
              }
            });
          }
        });
  } catch (std::exception const& e) {
    SetErrorUi(e.what());
  }
}

void MainWindow::RunTwinAsync() {
  auto backend = backend_;
  if (!backend || !backend->running()) {
    SetErrorUi("Racket backend not running");
    return;
  }
  auto const plain = winrt::to_string(TwinPlainBox().Text());
  auto const cipher = winrt::to_string(TwinCipherBox().Text());
  auto const output = winrt::to_string(TwinOutputBox().Text());
  if (plain.empty() || cipher.empty() || output.empty()) {
    SetErrorUi("Enter the twin plaintext path, the twin ciphertext path and the pad output path");
    return;
  }
  SetBusyUi(true);
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  try {
    rivet_app::API api(*backend);
    (void)api.pad_twin_summary_async(plain, cipher, output,
        [dispatcher, weak](rivet_app::Result<std::string> result) mutable {
          try {
            auto message = result.get();
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) window->ShowTwinResult(message);
            });
          } catch (std::exception const& e) {
            auto error = std::string(e.what());
            dispatcher.TryEnqueue([weak, error = std::move(error)] {
              if (auto window = weak.get()) {
                window->ShowFailed(error);
              }
            });
          }
        });
  } catch (std::exception const& e) {
    SetErrorUi(e.what());
  }
}

// ---------------- result rendering ----------------

void MainWindow::ShowTextResult(
    std::wstring const& title, winrt::hstring const& body,
    Microsoft::UI::Xaml::Controls::InfoBarSeverity severity,
    std::wstring const& status_message) {
  SetBusyUi(false);
  ResultCard().Visibility(Microsoft::UI::Xaml::Visibility::Visible);
  ResultTitle().Text(title);
  ResultText().Text(body);
  last_result_text_ = winrt::hstring(body);
  (void)severity;  // the result card carries the verdict
  (void)status_message;
  StatusBar().IsOpen(false);
}

// The decrypt RPC returns JSON (names, booleans, counters — never file
// contents). Turn it into a verdict a first-time reader understands.
void MainWindow::ShowDecryptResult(std::string const& json) {
  SetBusyUi(false);
  try {
    auto const obj =
        winrt::Windows::Data::Json::JsonObject::Parse(winrt::to_hstring(json));
    auto const kind = obj.GetNamedString(L"kind");
    auto const output = obj.GetNamedString(L"output");
    std::wstring body;
    std::wstring title;
    if (kind == L"ooxml") {
      auto const verified = static_cast<int>(obj.GetNamedNumber(L"verified"));
      auto const total = static_cast<int>(obj.GetNamedNumber(L"total"));
      title = (verified == total) ? L"解密成功" : L"解密完成（有校验未通过）";
      body = L"逐条目完整性校验：" + std::to_wstring(verified) + L" / " +
             std::to_wstring(total) + L" 通过\n";
      auto const entries = obj.GetNamedArray(L"entries");
      for (auto const& item : entries) {
        auto const entry = item.GetObject();
        auto const name = entry.GetNamedString(L"name");
        auto const ok = entry.GetNamedBoolean(L"crcOk");
        body += ok ? L"  \u2713 " : L"  \u2717 ";
        body += std::wstring{winrt::to_hstring(name).c_str()};
        body += L"\n";
      }
      body += (verified == total)
          ? L"输出文件：" + std::wstring{winrt::to_hstring(output).c_str()} +
                L"\n全部组成部分校验通过，输出文件可以直接打开。原始文件未被改动。"
          : L"输出文件：" + std::wstring{winrt::to_hstring(output).c_str()} +
                L"\n有组成部分未通过校验，请勿使用该输出文件。";
    } else {
      auto const head_rebuilt = obj.GetNamedBoolean(L"headRebuilt");
      auto const pages = static_cast<int>(obj.GetNamedNumber(L"pages"));
      auto const xref_checked = static_cast<int>(obj.GetNamedNumber(L"xrefChecked"));
      auto const xref_bad = static_cast<int>(obj.GetNamedNumber(L"xrefBad"));
      title = (xref_bad == 0) ? L"解密成功" : L"解密完成（交叉引用有损坏）";
      body = L"PDF 已重建：共 " + std::to_wstring(pages) + L" 页，交叉引用校验 " +
             std::to_wstring(xref_checked) + L" 处（损坏 " +
             std::to_wstring(xref_bad) + L" 处）\n输出文件：" +
             std::wstring{winrt::to_hstring(output).c_str()} +
             (head_rebuilt ? L"\n文件头已重建，可用 PDF 阅读器直接打开。原始文件未被改动。"
                           : L"\n原始文件未被改动。");
    }
    ResultCard().Visibility(Microsoft::UI::Xaml::Visibility::Visible);
    ResultTitle().Text(title);
    ResultText().Text(body);
    last_result_text_ = winrt::to_hstring(json);
    StatusBar().IsOpen(false);  // the result card carries the verdict
  } catch (...) {
    // Malformed JSON from the engine should never crash the UI; fall back
    // to showing the raw text.
    ShowTextResult(L"解密完成", winrt::to_hstring(json),
                   Microsoft::UI::Xaml::Controls::InfoBarSeverity::Success,
                   L"解密完成。");
  }
}

void MainWindow::ShowTwinResult(std::string const& json) {
  SetBusyUi(false);
  try {
    auto const obj =
        winrt::Windows::Data::Json::JsonObject::Parse(winrt::to_hstring(json));
    auto const covered = static_cast<int>(obj.GetNamedNumber(L"covered"));
    auto const missing = static_cast<int>(obj.GetNamedNumber(L"missingCount"));
    auto const complete = obj.GetNamedBoolean(L"complete");
    auto const output = obj.GetNamedString(L"output");
    std::wstring title;
    std::wstring body;
    if (complete) {
      title = L"密钥恢复成功";
      body = L"密钥已完整恢复（" + std::to_wstring(covered) + L" / 512 列），" +
             L"保存为：" + std::wstring{winrt::to_hstring(output).c_str()} +
             L"\n要用它解密文件：先设置环境变量 FILEBOUNDARY_PAD 指向这个密钥文件，"
             L"再从「解密文件」面板操作。";
    } else {
      title = L"密钥只恢复了一部分";
      body = L"只恢复了 " + std::to_wstring(covered) + L" / 512 列（缺 " +
             std::to_wstring(missing) + L" 列）。\n"
             L"两份文件的内容可能不是同一个文件。请确认「明文版本」能正常打开、"
             L"「加密版本」是同一个文件的加密副本，然后重试。";
    }
    ResultCard().Visibility(Microsoft::UI::Xaml::Visibility::Visible);
    ResultTitle().Text(title);
    ResultText().Text(body);
    last_result_text_ = winrt::to_hstring(json);
    // incomplete recovery keeps a warning banner up; success is carried
    // by the result card alone
    StatusBar().IsOpen(!complete);
    if (!complete) {
      StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Warning);
      StatusBar().Message(L"密钥未完整恢复，需要重新提供文件对。");
    }
  } catch (...) {
    ShowTextResult(L"恢复结果", winrt::to_hstring(json),
                   Microsoft::UI::Xaml::Controls::InfoBarSeverity::Success,
                   L"恢复完成。");
  }
}

void MainWindow::ShowFailed(std::string const& what) {
  SetBusyUi(false);
  ResultCard().Visibility(Microsoft::UI::Xaml::Visibility::Visible);
  ResultTitle().Text(L"操作没有完成");
  std::wstring body = L"没有生成任何输出文件。\n原因：";
  body += std::wstring{winrt::to_hstring(what).c_str()};
  body += L"\n常见原因：本机未配置密钥文件（FILEBOUNDARY_PAD），或输入的不是加密文件。";
  ResultText().Text(body);
  last_result_text_ = winrt::to_hstring(what);
  StatusBar().IsOpen(false);  // the result card carries the failure
}

void MainWindow::SetReadyUi() {
  SetBusyUi(false);
  StatusBar().IsOpen(false);  // an idle app stays quiet
}

void MainWindow::SetErrorUi(std::string const& message) {
  SetBusyUi(false);
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Error);
  StatusBar().Message(winrt::to_hstring(message));
}

}  // namespace winrt::RivetHost::implementation
