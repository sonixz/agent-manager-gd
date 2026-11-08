// Windows pseudo-console (ConPTY) for VtTerminal: CreatePseudoConsole + a reader thread. Included by vt_terminal.cpp.
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>

#include <atomic>
#include <mutex>
#include <string>
#include <thread>

struct WinPty {
	HPCON pc = nullptr;
	HANDLE in_write = INVALID_HANDLE_VALUE;   // our end: keys to the program
	HANDLE out_read = INVALID_HANDLE_VALUE;   // our end: program output
	PROCESS_INFORMATION pi = {};
	std::thread reader;
	std::mutex lock;
	std::string pending;
	std::atomic<bool> eof{false};
};

static std::wstring wide(const godot::String &s) {
	godot::Char16String u = s.utf16();
	return std::wstring((const wchar_t *)u.get_data(), u.length());
}

// Windows command-line quoting (CommandLineToArgvW rules).
static std::wstring quote_arg(const std::wstring &a) {
	if (!a.empty() && a.find_first_of(L" \t\"") == std::wstring::npos) return a;
	std::wstring out = L"\"";
	size_t bs = 0;
	for (wchar_t c : a) {
		if (c == L'\\') { bs++; continue; }
		if (c == L'"') { out.append(bs * 2 + 1, L'\\'); out += c; bs = 0; continue; }
		out.append(bs, L'\\'); bs = 0; out += c;
	}
	out.append(bs * 2, L'\\');
	return out + L"\"";
}

static void *win_start(const godot::String &program, const godot::PackedStringArray &args, const godot::String &cwd,
		const godot::PackedStringArray &env, int cols, int rows) {
	WinPty *w = new WinPty();
	HANDLE in_read = INVALID_HANDLE_VALUE, out_write = INVALID_HANDLE_VALUE;
	if (!CreatePipe(&in_read, &w->in_write, nullptr, 0) || !CreatePipe(&w->out_read, &out_write, nullptr, 0)) {
		delete w;
		return nullptr;
	}
	COORD size = {(SHORT)cols, (SHORT)rows};
	if (FAILED(CreatePseudoConsole(size, in_read, out_write, 0, &w->pc))) {
		CloseHandle(in_read); CloseHandle(out_write); CloseHandle(w->in_write); CloseHandle(w->out_read);
		delete w;
		return nullptr;
	}
	CloseHandle(in_read);    // the pseudo-console keeps its own copies
	CloseHandle(out_write);

	STARTUPINFOEXW si = {};
	si.StartupInfo.cb = sizeof(si);
	// Without this, a parent whose own standard handles are redirected (pipes) passes them to the child, which then
	// writes there instead of the pseudo-console.
	si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
	si.StartupInfo.hStdInput = nullptr;
	si.StartupInfo.hStdOutput = nullptr;
	si.StartupInfo.hStdError = nullptr;
	SIZE_T attr_size = 0;
	InitializeProcThreadAttributeList(nullptr, 1, 0, &attr_size);
	si.lpAttributeList = (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(GetProcessHeap(), 0, attr_size);
	InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attr_size);
	UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, w->pc, sizeof(HPCON), nullptr, nullptr);

	std::wstring cmd = quote_arg(wide(program));
	for (const godot::String &a : args) cmd += L" " + quote_arg(wide(a));
	// environment: the parent's, plus the given NAME=value entries
	std::wstring block;
	LPWCH parent = GetEnvironmentStringsW();
	for (LPWCH p = parent; *p; p += wcslen(p) + 1) block += std::wstring(p) + L'\0';
	FreeEnvironmentStringsW(parent);
	for (const godot::String &e : env) block += wide(e) + L'\0';
	block += L'\0';
	std::wstring wcwd = wide(cwd);
	BOOL ok = CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE, EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
			block.data(), wcwd.empty() ? nullptr : wcwd.c_str(), &si.StartupInfo, &w->pi);
	DeleteProcThreadAttributeList(si.lpAttributeList);
	HeapFree(GetProcessHeap(), 0, si.lpAttributeList);
	if (!ok) {
		ClosePseudoConsole(w->pc); CloseHandle(w->in_write); CloseHandle(w->out_read);
		delete w;
		return nullptr;
	}
	w->reader = std::thread([w]() {
		char buf[65536];
		DWORD n = 0;
		while (ReadFile(w->out_read, buf, sizeof(buf), &n, nullptr) && n > 0) {
			std::lock_guard<std::mutex> g(w->lock);
			w->pending.append(buf, n);
		}
		w->eof = true;
	});
	return w;
}

static unsigned long win_pid(void *h) { return ((WinPty *)h)->pi.dwProcessId; }

static void win_drain(void *h, std::string &out, bool &ended, int &code) {
	WinPty *w = (WinPty *)h;
	{
		std::lock_guard<std::mutex> g(w->lock);
		out.swap(w->pending);
	}
	DWORD ec = STILL_ACTIVE;
	if (WaitForSingleObject(w->pi.hProcess, 0) == WAIT_OBJECT_0 && GetExitCodeProcess(w->pi.hProcess, &ec)) {
		// the program ended: give the reader a moment for the last bytes
		std::lock_guard<std::mutex> g(w->lock);
		if (w->pending.empty()) {
			ended = true;
			code = (int)ec;
		}
	}
}

static void win_write(void *h, const uint8_t *data, size_t len) {
	DWORD n = 0;
	WriteFile(((WinPty *)h)->in_write, data, (DWORD)len, &n, nullptr);
}

static void win_resize(void *h, int cols, int rows) {
	ResizePseudoConsole(((WinPty *)h)->pc, COORD{(SHORT)cols, (SHORT)rows});
}

static void win_close(void *h) {
	WinPty *w = (WinPty *)h;
	if (w->pi.hProcess) {
		if (WaitForSingleObject(w->pi.hProcess, 0) != WAIT_OBJECT_0) TerminateProcess(w->pi.hProcess, 1);
	}
	ClosePseudoConsole(w->pc);  // ends the reader's ReadFile
	CloseHandle(w->in_write);
	if (w->reader.joinable()) w->reader.join();
	CloseHandle(w->out_read);
	if (w->pi.hProcess) CloseHandle(w->pi.hProcess);
	if (w->pi.hThread) CloseHandle(w->pi.hThread);
	delete w;
}
