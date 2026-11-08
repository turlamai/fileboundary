// Online update flow for the FileBoundary window (docs/update-contract.md,
// ADR-0011), ported from taskly's MainWindow.Update.cpp — the family UI
// skeleton (silent throttled launch check, manual check, 400 ms progress
// polling, quit-and-install handoff with .old rollback + failure markers)
// with FileBoundary's String-returning update RPCs: every backend answer is
// a JSON document parsed here. The install handoff covers both Windows
// faces: MSI installs upgrade via a passive msiexec batch, portable zip
// installs swap the extracted archive over the install directory.

#include "pch.h"
#include "MainWindow.xaml.h"
#include "GeneratedBackend.hpp"

#include <shellapi.h>

#include <chrono>
#include <cwctype>
#include <fstream>
#include <functional>
#include <string>

#include <winrt/Windows.ApplicationModel.DataTransfer.h>
#include <winrt/Windows.Data.Json.h>

namespace winrt::RivetHost::implementation {
namespace {

namespace mx = winrt::Microsoft::UI::Xaml;
namespace mxc = winrt::Microsoft::UI::Xaml::Controls;

constexpr wchar_t kReleasesUrl[] =
    L"https://github.com/turlamai/fileboundary/releases";

std::int64_t epoch_seconds() {
  FILETIME now{};
  ::GetSystemTimeAsFileTime(&now);
  ULARGE_INTEGER value{};
  value.LowPart = now.dwLowDateTime;
  value.HighPart = now.dwHighDateTime;
  // FILETIME is 100 ns ticks since 1601-01-01; the constant converts to
  // unix epoch seconds.
  return static_cast<std::int64_t>(
      (value.QuadPart - 116444736000000000ULL) / 10000000ULL);
}

std::wstring lowercase(std::wstring text) {
  for (auto& c : text) {
    c = static_cast<wchar_t>(::towlower(c));
  }
  return text;
}

std::wstring wide(std::string const& text) {
  return std::wstring{winrt::to_hstring(text).c_str()};
}

// The backend answers with JSON documents (update-check/update-state
// snapshots); a small tolerant reader beats plumbing typed records here.
std::wstring json_string(std::string const& json, wchar_t const* key,
                         std::wstring const& fallback = L"") {
  try {
    auto const obj =
        winrt::Windows::Data::Json::JsonObject::Parse(winrt::to_hstring(json));
    auto member = obj.TryLookup(key);
    if (member && member.ValueType() ==
                      winrt::Windows::Data::Json::JsonValueType::String) {
      return std::wstring{member.GetString().c_str()};
    }
  } catch (...) {
  }
  return fallback;
}

// %TEMP%\fileboundary-update — handoff script, extract dir, and markers
// live here.
std::filesystem::path update_work_dir() {
  wchar_t buffer[MAX_PATH]{};
  std::filesystem::path base;
  auto const length = ::GetEnvironmentVariableW(L"TEMP", buffer, MAX_PATH);
  if (length > 0 && length < MAX_PATH) {
    base = std::filesystem::path(buffer);
  } else {
    auto const fallback_length =
        ::GetEnvironmentVariableW(L"TMP", buffer, MAX_PATH);
    if (fallback_length > 0 && fallback_length < MAX_PATH) {
      base = std::filesystem::path(buffer);
    }
  }
  if (base.empty()) {
    return {};
  }
  auto const dir = base / L"fileboundary-update";
  std::error_code ec;
  std::filesystem::create_directories(dir, ec);
  return dir;
}

std::filesystem::path update_failure_marker() {
  return update_work_dir() / L"update-failed.txt";
}

std::filesystem::path update_success_marker() {
  return update_work_dir() / L"update-success.txt";
}

// The detached handoff batch. ASCII on purpose: cmd parses batches in the
// ANSI code page, so paths travel as quoted %~1…%~5 arguments instead of
// being embedded in the script body. Order matters: extract and verify
// BEFORE touching the old install, so a corrupt zip can never break the
// running copy. Args: %1 zip, %2 install dir, %3 exe, %4 failure marker,
// %5 success marker.
std::string update_handoff_batch(unsigned long pid) {
  std::string const pid_text = std::to_string(pid);
  std::string batch;
  batch += "@echo off\r\n";
  batch += "rem FileBoundary update handoff - auto-generated, safe to delete.\r\n";
  batch += "set /a n=0\r\n";
  batch += ":wait\r\n";
  batch += "tasklist /FI \"PID eq " + pid_text + "\" 2>nul | find \"" +
           pid_text + "\" >nul\r\n";
  batch += "if errorlevel 1 goto extract\r\n";
  batch += "ping -n 2 127.0.0.1 >nul\r\n";
  batch += "set /a n+=1\r\n";
  batch += "if %n% LSS 30 goto wait\r\n";
  // The app never freed itself within 30 s: leave it running and report.
  batch += "> \"%~4\" echo process-exit-timeout\r\n";
  batch += "exit /b 1\r\n";
  batch += ":extract\r\n";
  batch += "set \"extract=%~dp0extract\"\r\n";
  batch += "if exist \"%extract%\" rmdir /s /q \"%extract%\"\r\n";
  batch += "mkdir \"%extract%\" 2>nul\r\n";
  batch += "tar -xf \"%~1\" -C \"%extract%\"\r\n";
  batch += "if errorlevel 1 goto fail_extract\r\n";
  batch += "if exist \"%~2.old\" rmdir /s /q \"%~2.old\"\r\n";
  batch += "move \"%~2\" \"%~2.old\" >nul 2>&1\r\n";
  batch += "if errorlevel 1 goto fail_rename\r\n";
  batch += "robocopy \"%extract%\" \"%~2\" /E /MOVE /NFL /NDL /NJH /NJS /NP >nul\r\n";
  batch += "if errorlevel 8 goto fail_swap\r\n";
  batch += "start \"\" \"%~3\"\r\n";
  batch += "> \"%~5\" echo ok\r\n";
  batch += "exit /b 0\r\n";
  batch += ":fail_swap\r\n";
  batch += "> \"%~4\" echo swap-failed (%errorlevel%)\r\n";
  batch += "move \"%~2.old\" \"%~2\" >nul 2>&1\r\n";
  batch += "goto restart_old\r\n";
  batch += ":fail_rename\r\n";
  batch += "> \"%~4\" echo rename-failed (%errorlevel%)\r\n";
  batch += "goto restart_old\r\n";
  batch += ":fail_extract\r\n";
  batch += "> \"%~4\" echo extract-failed (%errorlevel%)\r\n";
  batch += ":restart_old\r\n";
  batch += "start \"\" \"%~3\"\r\n";
  batch += "exit /b 1\r\n";
  return batch;
}

// MSI installs upgrade in place: wait for this process to exit, then a
// passive msiexec upgrade. Per-machine installs surface one UAC consent
// (unavoidable under /passive); a failure keeps the old install working —
// the batch relaunches it and leaves the failure marker for next launch.
// Args: %1 msi, %2 msiexec log, %3 exe, %4 failure marker.
std::string msi_install_batch(unsigned long pid) {
  std::string const pid_text = std::to_string(pid);
  std::string batch;
  batch += "@echo off\r\n";
  batch += "rem FileBoundary MSI update handoff - auto-generated, safe to delete.\r\n";
  batch += "set /a n=0\r\n";
  batch += ":wait\r\n";
  batch += "tasklist /FI \"PID eq " + pid_text + "\" 2>nul | find \"" +
           pid_text + "\" >nul\r\n";
  batch += "if errorlevel 1 goto install\r\n";
  batch += "ping -n 2 127.0.0.1 >nul\r\n";
  batch += "set /a n+=1\r\n";
  batch += "if %n% LSS 30 goto wait\r\n";
  batch += "> \"%~4\" echo process-exit-timeout\r\n";
  batch += "exit /b 1\r\n";
  batch += ":install\r\n";
  batch += "msiexec /passive /norestart /i \"%~1\" /l* \"%~2\"\r\n";
  batch += "if errorlevel 1 goto fail\r\n";
  batch += "start \"\" \"%~3\"\r\n";
  batch += "exit /b 0\r\n";
  batch += ":fail\r\n";
  batch += "> \"%~4\" echo msiexec failed (%errorlevel%)\r\n";
  batch += "start \"\" \"%~3\"\r\n";
  batch += "exit /b 1\r\n";
  return batch;
}

std::filesystem::path executable_path() {
  wchar_t buffer[MAX_PATH]{};
  auto const length = ::GetModuleFileNameW(nullptr, buffer, MAX_PATH);
  return std::filesystem::path(std::wstring{buffer, buffer + length});
}

void open_releases_page() {
  ::ShellExecuteW(nullptr, L"open", kReleasesUrl, nullptr, nullptr,
                  SW_SHOWNORMAL);
}

}  // namespace

// ---------- entry points ------------------------------------------------------

void MainWindow::UpdateCheck_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  RunUpdateCheck(/*silent=*/false);
}

// Silent launch check: once, 3 s after the backend is ready, throttled to
// one attempt per 4 h (update contract triggers); failures never nag.
// resume_after resumes on the threadpool, so the continuation re-marshals
// through the dispatcher before touching window state.
winrt::fire_and_forget MainWindow::AutoCheckUpdatesAsync() {
  auto const weak = get_weak();
  auto const dispatcher = DispatcherQueue();
  co_await winrt::resume_after(std::chrono::seconds{3});
  dispatcher.TryEnqueue([weak] {
    if (auto window = weak.get()) {
      window->RunSilentUpdateCheck();
    }
  });
}

void MainWindow::RunSilentUpdateCheck() {
  if (backend_ == nullptr || !backend_->running() || update_downloading_) {
    return;
  }
  if (IsDevCopy()) {
    return;  // dev copies never phone home (update contract silent mode)
  }
  if (!auto_check_updates_) {
    return;  // auto-check toggle: silent checks skip
  }
  // Host-side throttle: at most one silent check per 4 h, persisted as the
  // last-update-check setting (unix epoch seconds; the backend writes the
  // stamp when a check settles — an answer or a definitive failure).
  // Manual checks bypass this entirely.
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = backend_;
  try {
    rivet_app::API api(*backend);
    (void)api.update_settings_get_async(
        "last-update-check",
        [dispatcher, weak](rivet_app::Result<std::string> result) {
          std::int64_t last = 0;
          try {
            last = std::stoll(result.get());
          } catch (...) {
            last = 0;  // empty or non-numeric → never checked
          }
          if (epoch_seconds() - last < 4 * 60 * 60) {
            return;  // throttled
          }
          dispatcher.TryEnqueue([weak] {
            if (auto window = weak.get()) {
              window->RunUpdateCheck(/*silent=*/true);
            }
          });
        });
  } catch (...) {
    // Deliberately silent: launch path. Any failure here (backend not yet
    // up, dispatcher gone) must never block startup or pop UI; the 4-hour
    // throttle window simply retries on a later launch.
  }
}

// A manual check surfaces every outcome; a silent (launch-time) check never
// nags — it only reports an available update through the consent dialog.
// MSI installs participate fully: the backend downloads the sibling .msi
// asset and the install step runs a passive msiexec upgrade (update
// contract). Selection happens in the backend, so persist the host-detected
// install shape before asking it to choose an artifact — this ordering is
// part of the contract: a fire-and-forget startup stamp can otherwise race
// the first check and make an MSI install download the ZIP.
void MainWindow::RunUpdateCheck(bool silent) {
  if (backend_ == nullptr || !backend_->running() || update_downloading_) {
    return;
  }
  if (IsDevCopy()) {
    if (!silent) {
      ShowUpdateDialog(L"FileBoundary", L"开发副本不支持自动更新。",
                       L"打开发布页", L"确定", [] { open_releases_page(); });
    }
    return;
  }
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = backend_;
  if (!silent) {
    SetBusyUi(true);
  }
  try {
    rivet_app::API api(*backend);
    auto const flavor = IsMsiInstall() ? "msi" : "zip";
    (void)api.update_settings_set_async(
        "install-flavor", flavor,
        [dispatcher, weak, silent](
            rivet_app::Result<std::string> result) {
          std::string failure;
          try {
            (void)result.get();
          } catch (std::exception const& e) {
            failure = e.what();
          }
          dispatcher.TryEnqueue(
              [weak, silent, failure = std::move(failure)] {
                if (auto window = weak.get()) {
                  if (failure.empty()) {
                    window->ContinueUpdateCheck(silent);
                  } else {
                    window->HandleUpdateCheckResult("", failure, silent);
                  }
                }
              });
        });
  } catch (std::exception const& e) {
    HandleUpdateCheckResult("", std::string(e.what()), silent);
  }
}

void MainWindow::ContinueUpdateCheck(bool silent) {
  if (backend_ == nullptr || !backend_->running() || update_downloading_) {
    if (!silent) SetBusyUi(false);
    return;
  }
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = backend_;
  try {
    rivet_app::API api(*backend);
    (void)api.update_check_async(
        [dispatcher, weak, silent](
            rivet_app::Result<std::string> result) {
          // The check answer JSON lands on the UI thread either way; the
          // backend already settled the throttle stamp inside the RPC.
          bool ok = false;
          std::string check;
          std::string failure;
          try {
            check = result.get();
            ok = true;
          } catch (std::exception const& e) {
            failure = e.what();
          }
          dispatcher.TryEnqueue(
              [weak, silent, ok, check = std::move(check),
               failure = std::move(failure)] {
                if (auto window = weak.get()) {
                  if (ok) {
                    window->HandleUpdateCheckResult(check, "", silent);
                  } else {
                    window->HandleUpdateCheckResult("", failure, silent);
                  }
                }
              });
        });
  } catch (std::exception const& e) {
    if (!silent) {
      SetBusyUi(false);
      // Primary action = the escape hatch: when the check cannot reach the
      // feed (offline, blocked CDN), the user can still download manually.
      ShowUpdateDialog(L"FileBoundary",
                       L"检查更新失败：" + wide(e.what()), L"打开发布页",
                       L"确定", [] { open_releases_page(); }, L"复制错误");
    }
  }
}

// check_json empty means the RPC itself failed (failure carries the reason).
void MainWindow::HandleUpdateCheckResult(std::string const& check_json,
                                         std::string const& failure,
                                         bool silent) {
  if (!silent) {
    SetBusyUi(false);  // clear the busy state from the manual check
  }
  if (check_json.empty()) {
    if (!silent) {
      // Same escape hatch as the sync catch: a failed check should always
      // leave the manual download one click away.
      ShowUpdateDialog(L"FileBoundary", L"检查更新失败：" + wide(failure),
                       L"打开发布页", L"确定", [] { open_releases_page(); },
                       L"复制错误");
    }
    return;
  }
  auto const status = json_string(check_json, L"status");
  if (status == L"available") {
    auto const version = json_string(check_json, L"availableVersion",
                                     L"?");
    auto const bytes = json_string(check_json, L"sizeBytes");
    std::wstring body = L"最新版本：" + version;
    if (!bytes.empty()) {
      try {
        auto const size = std::stoll(std::wstring{bytes.c_str()});
        wchar_t buffer[64]{};
        swprintf_s(buffer, L"%.1f MB",
                   static_cast<double>(size) / (1024.0 * 1024.0));
        body += L"（约 " + std::wstring{buffer} + L"）";
      } catch (...) {
      }
    }
    ShowUpdateDialog(L"发现新版本", body, L"立即更新", L"取消",
                     [weak = get_weak()] {
                       if (auto window = weak.get()) {
                         window->StartDownload();
                       }
                     });
    return;
  }
  if (silent) {
    return;  // up-to-date / errors never nag in silent mode
  }
  if (status == L"up-to-date") {
    auto const current = json_string(check_json, L"currentVersion");
    ShowUpdateDialog(L"已是最新版本",
                     L"当前版本：" + current + L"，无需更新。", L"", L"确定",
                     nullptr);
    return;
  }
  auto const detail = json_string(check_json, L"message", status);
  ShowUpdateDialog(L"FileBoundary", L"检查更新失败：" + detail, L"打开发布页",
                   L"确定", [] { open_releases_page(); }, L"复制错误");
}

// ---------- download -----------------------------------------------------------

// Nothing downloads before the user picks "立即更新" — an update is an
// offer, never an ambient side effect.
void MainWindow::StartDownload() {
  if (backend_ == nullptr || !backend_->running() || update_downloading_) {
    return;
  }
  update_downloading_ = true;
  update_download_start_ = epoch_seconds();
  // The full-width notice above the body — a status line alone is too easy
  // to miss during a multi-minute download.
  // InfoBar.Title is an hstring property, not an IInspectable slot.
  UpdateDownloadBar().Title(L"正在下载更新…");
  UpdateDownloadPercentText().Text(L"");
  UpdateDownloadProgress().IsIndeterminate(true);
  UpdateDownloadBar().IsOpen(true);

  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = backend_;
  try {
    rivet_app::API api(*backend);
    (void)api.update_download_async(
        [dispatcher, weak](rivet_app::Result<std::string> result) {
          std::string failure;
          try {
            (void)result.get();
          } catch (std::exception const& e) {
            failure = e.what();
          }
          if (!failure.empty()) {
            dispatcher.TryEnqueue([weak, failure = std::move(failure)] {
              if (auto window = weak.get()) {
                window->FailDownload(failure);
              }
            });
          }
        });
  } catch (std::exception const& e) {
    FailDownload(e.what());
    return;
  }

  // Poll update_state while the backend downloads (the family 400 ms timer).
  update_timer_ = mx::DispatcherTimer();
  update_timer_.Interval(std::chrono::milliseconds{400});
  update_timer_.Tick([weak, backend](auto&&, auto&&) {
    if (auto window = weak.get()) {
      window->PollUpdateState(backend);
    }
  });
  update_timer_.Start();
}

void MainWindow::UpdateCancel_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  if (!update_downloading_ || backend_ == nullptr || !backend_->running()) {
    return;
  }
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = backend_;
  try {
    rivet_app::API api(*backend);
    // update_download is a start/cancel toggle while a transfer is active.
    (void)api.update_download_async(
        [dispatcher, weak](rivet_app::Result<std::string> result) {
          std::string failure;
          try {
            (void)result.get();
          } catch (std::exception const& e) {
            failure = e.what();
          }
          dispatcher.TryEnqueue(
              [weak, failure = std::move(failure)] {
                if (auto window = weak.get()) {
                  if (!failure.empty()) {
                    window->FailDownload(failure);
                    return;
                  }
                  if (window->update_timer_) {
                    window->update_timer_.Stop();
                    window->update_timer_ = nullptr;
                  }
                  window->update_downloading_ = false;
                  window->UpdateDownloadBar().IsOpen(false);
                  window->SetBusyUi(false);
                  // Re-check immediately so cancellation returns to the
                  // available-update offer with the candidate still usable.
                  window->RunUpdateCheck(/*silent=*/false);
                }
              });
        });
  } catch (std::exception const& e) {
    FailDownload(e.what());
  }
}

void MainWindow::PollUpdateState(
    std::shared_ptr<rivet::windows::Backend> const& backend) {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  try {
    rivet_app::API api(*backend);
    (void)api.update_state_async(
        [dispatcher, weak](rivet_app::Result<std::string> result) {
          std::string json;
          try {
            json = result.get();
          } catch (...) {
            return;  // transient poll error: the next tick retries
          }
          dispatcher.TryEnqueue([weak, json = std::move(json)] {
            if (auto window = weak.get()) {
              window->HandleUpdatePoll(json);
            }
          });
        });
  } catch (...) {
    // A transient RPC failure is not a download failure; keep polling.
  }
}

void MainWindow::HandleUpdatePoll(std::string const& json) {
  if (!update_downloading_) {
    return;
  }
  auto const phase = json_string(json, L"phase");
  // Total-limit watchdog: the backend has its own stall/total bounds, but
  // if it died mid-download (or a poll never resolves again) the host still
  // must reach a terminal state instead of resting on a frozen percent.
  if (update_download_start_ > 0 &&
      epoch_seconds() - update_download_start_ > 30 * 60) {
    if (update_timer_) {
      update_timer_.Stop();
      update_timer_ = nullptr;
    }
    update_downloading_ = false;
    FailDownload("download timed out");
    return;
  }
  if (phase == L"downloaded") {
    if (update_timer_) {
      update_timer_.Stop();
      update_timer_ = nullptr;
    }
    update_downloading_ = false;
    UpdateDownloadBar().IsOpen(false);
    auto const path = json_string(json, L"downloadedPath");
    if (path.empty()) {
      FailDownload("downloaded file path missing");
      return;
    }
    ShowInstallConsent(path);
    return;
  }
  if (phase == L"cancelled") {
    if (update_timer_) {
      update_timer_.Stop();
      update_timer_ = nullptr;
    }
    update_downloading_ = false;
    UpdateDownloadBar().IsOpen(false);
    return;
  }
  if (phase == L"error") {
    if (update_timer_) {
      update_timer_.Stop();
      update_timer_ = nullptr;
    }
    update_downloading_ = false;
    UpdateDownloadBar().IsOpen(false);
    FailDownload(winrt::to_string(json_string(json, L"message",
                                              L"download failed")));
    return;
  }
  // Content-Length can be missing behind proxies/mirrors (size 0 →
  // indeterminate ring); once a real percent arrives, switch the bar to
  // determinate and title it with the number.
  try {
    auto const obj =
        winrt::Windows::Data::Json::JsonObject::Parse(winrt::to_hstring(json));
    auto const percent = static_cast<std::int64_t>(obj.GetNamedNumber(L"percent"));
    if (percent > 0) {
      if (UpdateDownloadProgress().IsIndeterminate()) {
        UpdateDownloadProgress().IsIndeterminate(false);
      }
      UpdateDownloadProgress().Value(static_cast<double>(percent));
      UpdateDownloadPercentText().Text(std::to_wstring(percent) + L"%");
    }
  } catch (...) {
  }
}

void MainWindow::FailDownload(std::string const& message) {
  update_downloading_ = false;
  if (update_timer_) {
    update_timer_.Stop();
    update_timer_ = nullptr;
  }
  UpdateDownloadBar().IsOpen(false);
  SetBusyUi(false);
  ShowUpdateDialog(L"FileBoundary", L"更新下载失败：" + wide(message), L"",
                   L"确定", nullptr, L"复制错误");
}

// ---------- install handoff ------------------------------------------------------

// Installing is a separate, explicit step: the download is complete and
// verified (backend-side, family mode), and only the user's consent closes
// the app.
winrt::fire_and_forget MainWindow::ShowInstallConsent(
    std::wstring const& path) {
  ShowUpdateDialog(L"下载完成", L"更新已下载并通过校验，是否立即安装？",
                   L"退出并安装", L"取消",
                   [weak = get_weak(), path] {
                     if (auto window = weak.get()) {
                       window->InstallDownloadedUpdate(path);
                     }
                   });
  co_return;
}

void MainWindow::InstallDownloadedUpdate(std::wstring const& update_path) {
  auto const work = update_work_dir();
  if (work.empty()) {
    ShowUpdateDialog(L"FileBoundary", L"安装失败：临时目录不可用。", L"",
                     L"确定", nullptr);
    return;
  }
  std::error_code ec;
  // Dispatch the bytes that were selected, signed, downloaded and verified;
  // never re-infer their type from the install directory.
  auto const extension = lowercase(
      std::filesystem::path(update_path).extension().wstring());
  if (extension != L".msi" && extension != L".zip") {
    ShowUpdateDialog(L"FileBoundary", L"安装失败：安装包类型异常。", L"",
                     L"确定", nullptr);
    return;
  }
  auto const msi = extension == L".msi";
  auto const script = work / (msi ? L"msi-install.cmd" : L"update-install.cmd");
  // Stale markers from earlier attempts must not survive this one.
  std::filesystem::remove(update_failure_marker(), ec);
  std::filesystem::remove(update_success_marker(), ec);

  {
    std::ofstream file(script, std::ios::binary | std::ios::trunc);
    if (!file) {
      ShowUpdateDialog(L"FileBoundary", L"安装失败：脚本写入失败。", L"",
                       L"确定", nullptr);
      return;
    }
    auto const batch =
        msi ? msi_install_batch(::GetCurrentProcessId())
            : update_handoff_batch(::GetCurrentProcessId());
    file.write(batch.data(), static_cast<std::streamsize>(batch.size()));
    file.close();
    if (!file) {
      ShowUpdateDialog(L"FileBoundary", L"安装失败：脚本写入失败。", L"",
                       L"确定", nullptr);
      return;
    }
  }

  std::wstring const exe = executable_path().wstring();
  std::wstring parameters;
  if (msi) {
    auto const msi_log = work / L"msiexec.log";
    parameters = L"/c call \"" + script.wstring() + L"\" \"" + update_path +
                 L"\" \"" + msi_log.wstring() + L"\" \"" + exe + L"\" \"" +
                 update_failure_marker().wstring() + L"\"";
  } else {
    std::wstring const install_dir =
        executable_path().parent_path().wstring();
    parameters = L"/c call \"" + script.wstring() + L"\" \"" + update_path +
                 L"\" \"" + install_dir + L"\" \"" + exe + L"\" \"" +
                 update_failure_marker().wstring() + L"\" \"" +
                 update_success_marker().wstring() + L"\"";
  }
  SHELLEXECUTEINFOW info{};
  info.cbSize = sizeof(info);
  info.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
  info.lpVerb = L"open";
  info.lpFile = L"cmd.exe";
  info.lpParameters = parameters.c_str();
  info.nShow = SW_HIDE;
  if (!ShellExecuteExW(&info)) {
    ShowUpdateDialog(L"FileBoundary", L"安装失败：安装程序启动失败。", L"",
                     L"确定", nullptr);
    return;
  }
  // The handoff script takes it from here: it waits for this process to
  // exit, swaps the zip in (or runs the passive msiexec upgrade), relaunches,
  // and leaves markers behind either way (a failure marker is the next
  // launch's failure report input).
  winrt::Microsoft::UI::Xaml::Application::Current().Exit();
}

// Surface a previous failed install once: read the error the handoff script
// left behind, clear the marker, and report. A success marker means the
// swapped-in version launched — retire the .old fallback copy.
void MainWindow::HandleInstallMarkers() {
  auto const work = update_work_dir();
  if (work.empty()) {
    return;
  }
  std::error_code ec;
  auto const success = update_success_marker();
  if (std::filesystem::exists(success, ec)) {
    std::filesystem::remove(success, ec);
    try {
      auto const install_dir = executable_path().parent_path();
      std::filesystem::remove_all(
          std::filesystem::path(install_dir.wstring() + L".old"), ec);
    } catch (...) {
      // The fallback copy is expendable; never block startup on it.
    }
    return;
  }
  auto const marker = update_failure_marker();
  if (!std::filesystem::exists(marker, ec)) {
    return;
  }
  std::ifstream file(marker);
  std::string code;
  std::getline(file, code);
  file.close();
  std::filesystem::remove(marker, ec);
  ShowUpdateDialog(L"FileBoundary",
                   L"上次更新安装失败：" +
                       wide(code.empty() ? std::string("unknown") : code),
                   L"", L"确定", nullptr);
}

// Portable-layout semantics: a copy without the packaged layout (embedded
// backend at res/core.zo) or one running from a temp path is a dev copy —
// auto-update is unavailable there.
bool MainWindow::IsDevCopy() {
  try {
    auto const install_dir = executable_path().parent_path();
    std::error_code ec;
    if (!std::filesystem::exists(install_dir / L"res" / L"core.zo", ec)) {
      return true;
    }
    return lowercase(install_dir.wstring()).find(L"temp") !=
           std::wstring::npos;
  } catch (...) {
    return true;
  }
}

// MSI 安装版语义: the MSI lands under Program Files, where the in-place
// zip swap has no write access — those installs upgrade via the passive
// msiexec handoff; per-user zip installs swap in place.
bool MainWindow::IsMsiInstall() {
  wchar_t buffer[32768]{};
  auto const under_program_files = [&](wchar_t const* variable) {
    DWORD const length = ::GetEnvironmentVariableW(variable, buffer, 32768);
    if (length == 0 || length >= 32768) return false;
    std::wstring program_files = lowercase(std::wstring{buffer});
    while (!program_files.empty() && program_files.back() == L'\\') {
      program_files.pop_back();
    }
    if (program_files.empty()) return false;
    std::wstring const directory =
        lowercase(executable_path().parent_path().wstring());
    return directory == program_files ||
           directory.rfind(program_files + L"\\", 0) == 0;
  };
  return under_program_files(L"ProgramFiles") ||
         under_program_files(L"ProgramFiles(x86)") ||
         under_program_files(L"ProgramW6432");
}

// ---------- update dialogs -------------------------------------------------------

// One dialog helper for the whole update flow. An empty primary label hides
// the primary button (WinUI), so info dialogs pass L"". A second dialog
// while one is open throws — swallow it instead of stacking modals.
winrt::fire_and_forget MainWindow::ShowUpdateDialog(
    std::wstring const& title, std::wstring const& body,
    std::wstring const& primary_button, std::wstring const& close_button,
    std::function<void()> on_primary, std::wstring const& copy_button) {
  auto dialog = mxc::ContentDialog{};
  dialog.Title(winrt::box_value(title));
  dialog.Content(winrt::box_value(body));
  if (!primary_button.empty()) {
    dialog.PrimaryButtonText(primary_button);
    dialog.DefaultButton(mxc::ContentDialogButton::Primary);
  }
  if (!copy_button.empty()) {
    dialog.SecondaryButtonText(copy_button);
  }
  dialog.CloseButtonText(close_button);
  dialog.XamlRoot(Content().XamlRoot());

  auto const weak = get_weak();
  mxc::ContentDialogResult result{mxc::ContentDialogResult::None};
  try {
    result = co_await dialog.ShowAsync();
  } catch (...) {
    co_return;  // another dialog is already up; the flow can be retried
  }
  if (result == mxc::ContentDialogResult::Primary && on_primary &&
      weak.get()) {
    on_primary();
  }
  if (result == mxc::ContentDialogResult::Secondary) {
    try {
      winrt::Windows::ApplicationModel::DataTransfer::DataPackage package;
      package.SetText(body);
      winrt::Windows::ApplicationModel::DataTransfer::Clipboard::SetContent(
          package);
    } catch (...) {
      // The clipboard can be briefly held by another process; the failure
      // text also lands in update-failed.txt, so nothing is lost.
    }
  }
}

void MainWindow::RefreshUpdateVersionLabel() {
  auto const weak = get_weak();
  auto const dispatcher = DispatcherQueue();
  auto backend = backend_;
  if (backend == nullptr || !backend->running()) {
    return;
  }
  try {
    rivet_app::API api(*backend);
    (void)api.update_state_async(
        [weak, dispatcher](rivet_app::Result<std::string> result) {
          std::string json;
          try {
            json = result.get();
          } catch (...) {
            return;
          }
          dispatcher.TryEnqueue([weak, json = std::move(json)] {
            if (auto window = weak.get()) {
              auto const version = json_string(json, L"currentVersion");
              if (!version.empty()) {
                window->UpdateCurrentVersionText().Text(L"当前版本：" + version);
              }
            }
          });
        });
  } catch (...) {
    // Cosmetic; the label simply keeps its placeholder.
  }
}

void MainWindow::LoadAutoCheckUpdatesSetting() {
  auto const weak = get_weak();
  auto const dispatcher = DispatcherQueue();
  auto backend = backend_;
  if (backend == nullptr || !backend->running()) {
    return;
  }
  try {
    rivet_app::API api(*backend);
    (void)api.update_settings_get_async(
        "auto-check-updates",
        [dispatcher, weak](rivet_app::Result<std::string> result) {
          bool on = true;
          try {
            on = result.get() != "0";  // missing or unreadable → default on
          } catch (...) {
          }
          dispatcher.TryEnqueue([weak, on] {
            if (auto window = weak.get()) {
              window->auto_check_updates_ = on;
              window->UpdateAutoCheckToggle().IsChecked(on);
            }
          });
        });
  } catch (...) {
    // Silent: the toggle defaults to on until the backend answers.
  }
}

void MainWindow::UpdateAutoCheck_Toggled(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  auto_check_updates_ = UpdateAutoCheckToggle().IsChecked().GetBoolean();
  SaveUpdateSetting(L"auto-check-updates", auto_check_updates_ ? L"1" : L"0");
}

void MainWindow::SaveUpdateSetting(std::wstring const& key,
                                   std::wstring const& value) {
  auto backend = backend_;
  if (backend == nullptr || !backend->running()) {
    return;
  }
  try {
    rivet_app::API api(*backend);
    (void)api.update_settings_set_async(
        winrt::to_string(key), winrt::to_string(value),
        [](rivet_app::Result<std::string> result) {
          try {
            (void)result.get();
          } catch (...) {
            // Best-effort persistence; the toggle state stays in the UI.
          }
        });
  } catch (...) {
  }
}

}  // namespace winrt::RivetHost::implementation
