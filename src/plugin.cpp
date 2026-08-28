#include <windows.h>

#include <atomic>
#include <cstddef>
#include <string>
#include <vector>

#include "path_normalizer.h"

namespace {

constexpr UINT kAutorunAddFunction = 1;
constexpr int kAutorunResultOk = 0;
constexpr DWORD kWorkerStopTimeoutMs = 2000;
constexpr UINT kProcessPathEnter = WM_APP + 0x351;

using AutorunAdapter = int(__stdcall*)(UINT, void*);

struct AutorunInterface {
  DWORD size;
  HWND main_window;
  void* adapter;
};

struct AutorunFunctionInfo {
  DWORD size;
  DWORD flags;
  const wchar_t* name;
  void* address;
};

HMODULE g_module = nullptr;
std::atomic<HWND> g_main_window{nullptr};
std::atomic<HHOOK> g_keyboard_hook{nullptr};
std::atomic<HANDLE> g_stop_event{nullptr};
std::atomic<HANDLE> g_worker_thread{nullptr};
std::atomic<DWORD> g_worker_thread_id{0};
std::atomic<ULONG_PTR> g_correction_count{0};

bool IsTotalCommanderWindow(HWND window) noexcept {
  if (window == nullptr || !IsWindow(window)) {
    return false;
  }

  DWORD process_id = 0;
  GetWindowThreadProcessId(window, &process_id);
  if (process_id != GetCurrentProcessId()) {
    return false;
  }

  wchar_t class_name[64]{};
  return GetClassNameW(window, class_name,
                       static_cast<int>(std::size(class_name))) > 0 &&
         lstrcmpW(class_name, L"TTOTAL_CMD") == 0;
}

bool IsEditablePathControl(HWND window, HWND main_window) noexcept {
  if (window == nullptr || !IsWindow(window) ||
      GetAncestor(window, GA_ROOT) != main_window) {
    return false;
  }

  wchar_t class_name[64]{};
  if (GetClassNameW(window, class_name, static_cast<int>(std::size(class_name))) <=
          0 ||
      lstrcmpW(class_name, L"Edit") != 0) {
    return false;
  }

  HWND parent = GetParent(window);
  class_name[0] = L'\0';
  return parent != nullptr &&
         GetClassNameW(parent, class_name,
                       static_cast<int>(std::size(class_name))) > 0 &&
         lstrcmpW(class_name, L"Window") == 0;
}

void CorrectPath(HWND edit_control, HWND main_window) noexcept {
  if (!IsEditablePathControl(edit_control, main_window)) {
    return;
  }

  const int text_length = GetWindowTextLengthW(edit_control);
  if (text_length < 2 || text_length > 32767) {
    return;
  }

  try {
    std::vector<wchar_t> buffer(static_cast<std::size_t>(text_length) + 1, L'\0');
    const int copied = GetWindowTextW(edit_control, buffer.data(),
                                      static_cast<int>(buffer.size()));
    if (copied != text_length) {
      return;
    }

    std::wstring path(buffer.data(), static_cast<std::size_t>(copied));
    if (!tc_unc_guard::NormalizePath(path)) {
      return;
    }

    DWORD selection_start = 0;
    DWORD selection_end = 0;
    SendMessageW(edit_control, EM_GETSEL,
                 reinterpret_cast<WPARAM>(&selection_start),
                 reinterpret_cast<LPARAM>(&selection_end));

    if (SetWindowTextW(edit_control, path.c_str()) != FALSE) {
      SendMessageW(edit_control, EM_SETSEL, selection_start, selection_end);
      const ULONG_PTR count =
          g_correction_count.fetch_add(1, std::memory_order_relaxed) + 1;
      SetPropW(main_window, L"TCUNCGuard.Corrections",
               reinterpret_cast<HANDLE>(count));
    }
  } catch (...) {
    // No exception may cross the hook boundary into Total Commander.
  }
}

LRESULT CALLBACK LowLevelKeyboardHook(int code, WPARAM message, LPARAM data) {
  if (code == HC_ACTION && data != 0 &&
      (message == WM_KEYDOWN || message == WM_SYSKEYDOWN)) {
    const auto& keyboard = *reinterpret_cast<const KBDLLHOOKSTRUCT*>(data);
    if (keyboard.vkCode == VK_RETURN) {
      HWND main_window = g_main_window.load(std::memory_order_acquire);
      HWND foreground = GetForegroundWindow();
      if (main_window != nullptr && foreground == main_window) {
        DWORD process_id = 0;
        const DWORD ui_thread =
            GetWindowThreadProcessId(main_window, &process_id);
        GUITHREADINFO info{sizeof(info)};
        if (ui_thread != 0 && process_id == GetCurrentProcessId() &&
            GetGUIThreadInfo(ui_thread, &info) != FALSE) {
          if (IsEditablePathControl(info.hwndFocus, main_window)) {
            const DWORD worker_thread_id =
                g_worker_thread_id.load(std::memory_order_acquire);
            if (worker_thread_id != 0 &&
                PostThreadMessageW(worker_thread_id, kProcessPathEnter,
                                   reinterpret_cast<WPARAM>(info.hwndFocus),
                                   0) != FALSE) {
              return 1;
            }
          }
        }
      }
    }
  }

  return CallNextHookEx(g_keyboard_hook.load(std::memory_order_relaxed), code,
                        message, data);
}

void RemoveWindowProperties(HWND main_window) noexcept {
  if (main_window != nullptr && IsWindow(main_window)) {
    RemovePropW(main_window, L"TCUNCGuard.Active");
    RemovePropW(main_window, L"TCUNCGuard.Corrections");
  }
}

DWORD WINAPI WorkerThread(void* self_reference_parameter) {
  HMODULE self_reference = reinterpret_cast<HMODULE>(self_reference_parameter);
  HWND main_window = g_main_window.load(std::memory_order_acquire);

  MSG message{};
  PeekMessageW(&message, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
  g_worker_thread_id.store(GetCurrentThreadId(), std::memory_order_release);

  HHOOK hook = SetWindowsHookExW(WH_KEYBOARD_LL, LowLevelKeyboardHook, g_module, 0);
  if (hook != nullptr) {
    g_keyboard_hook.store(hook, std::memory_order_release);
    SetPropW(main_window, L"TCUNCGuard.Active", reinterpret_cast<HANDLE>(1));
  }

  HANDLE stop_event = g_stop_event.load(std::memory_order_acquire);
  bool running = hook != nullptr && stop_event != nullptr;
  while (running) {
    const DWORD wait_result =
        MsgWaitForMultipleObjects(1, &stop_event, FALSE, INFINITE, QS_ALLINPUT);
    if (wait_result == WAIT_OBJECT_0) {
      break;
    }
    if (wait_result != WAIT_OBJECT_0 + 1) {
      break;
    }

    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE) != FALSE) {
      if (message.message == WM_QUIT) {
        running = false;
        break;
      }
      if (message.message == kProcessPathEnter) {
        HWND edit_control = reinterpret_cast<HWND>(message.wParam);
        CorrectPath(edit_control, main_window);
        if (IsWindow(edit_control)) {
          PostMessageW(edit_control, WM_KEYDOWN, VK_RETURN, 0x001C0001);
        }
        continue;
      }
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
  }

  hook = g_keyboard_hook.exchange(nullptr, std::memory_order_acq_rel);
  if (hook != nullptr) {
    UnhookWindowsHookEx(hook);
  }
  RemoveWindowProperties(main_window);
  g_worker_thread_id.store(0, std::memory_order_release);

  if (self_reference != nullptr) {
    FreeLibraryAndExitThread(self_reference, 0);
  }
  return 0;
}

int __stdcall StopGuard(void*) {
  HANDLE stop_event = g_stop_event.load(std::memory_order_acquire);
  if (stop_event != nullptr) {
    SetEvent(stop_event);
  }

  HANDLE worker = g_worker_thread.load(std::memory_order_acquire);
  if (worker != nullptr && GetCurrentThreadId() != GetThreadId(worker)) {
    if (WaitForSingleObject(worker, kWorkerStopTimeoutMs) == WAIT_OBJECT_0) {
      worker = g_worker_thread.exchange(nullptr, std::memory_order_acq_rel);
      if (worker != nullptr) {
        CloseHandle(worker);
      }
      stop_event = g_stop_event.exchange(nullptr, std::memory_order_acq_rel);
      if (stop_event != nullptr) {
        CloseHandle(stop_event);
      }
      g_main_window.store(nullptr, std::memory_order_release);
    }
  }
  return kAutorunResultOk;
}

bool RegisterStopFunction(void* adapter_address) noexcept {
  if (adapter_address == nullptr) {
    return false;
  }
  AutorunFunctionInfo function_info{
      sizeof(function_info), 0, L"TCUNCGuardStop",
      reinterpret_cast<void*>(&StopGuard)};
  auto adapter = reinterpret_cast<AutorunAdapter>(adapter_address);
  return adapter(kAutorunAddFunction, &function_info) == kAutorunResultOk;
}

bool StartWorker(HWND main_window) noexcept {
  if (g_worker_thread.load(std::memory_order_acquire) != nullptr) {
    return true;
  }

  HANDLE stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (stop_event == nullptr) {
    return false;
  }

  wchar_t module_path[32768]{};
  const DWORD path_length = GetModuleFileNameW(
      g_module, module_path, static_cast<DWORD>(std::size(module_path)));
  if (path_length == 0 || path_length >= std::size(module_path)) {
    CloseHandle(stop_event);
    return false;
  }

  HMODULE self_reference = LoadLibraryW(module_path);
  if (self_reference == nullptr) {
    CloseHandle(stop_event);
    return false;
  }

  g_main_window.store(main_window, std::memory_order_release);
  g_stop_event.store(stop_event, std::memory_order_release);

  HANDLE worker = CreateThread(nullptr, 0, WorkerThread, self_reference, 0, nullptr);
  if (worker == nullptr) {
    g_stop_event.store(nullptr, std::memory_order_release);
    g_main_window.store(nullptr, std::memory_order_release);
    CloseHandle(stop_event);
    FreeLibrary(self_reference);
    return false;
  }

  g_worker_thread.store(worker, std::memory_order_release);
  return true;
}

}  // namespace

extern "C" __declspec(dllexport) void __stdcall Autorun_PluginInit(
    const AutorunInterface* info) {
  if (info == nullptr ||
      info->size < offsetof(AutorunInterface, adapter) + sizeof(info->adapter) ||
      !IsTotalCommanderWindow(info->main_window)) {
    return;
  }

  RegisterStopFunction(info->adapter);
  StartWorker(info->main_window);
}

extern "C" __declspec(dllexport) int __stdcall TCUNCGuardStop(void* parameter) {
  return StopGuard(parameter);
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
  if (reason == DLL_PROCESS_ATTACH) {
    g_module = instance;
    DisableThreadLibraryCalls(instance);
  }
  return TRUE;
}
