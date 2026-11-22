#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <userenv.h>
#include <sddl.h>
#include <objbase.h>
#include <filesystem>
#include <cstdio>
#include <string>
#include <vector>

#pragma comment(lib, "userenv.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "ole32.lib")

namespace fs = std::filesystem;

struct Failure { const char* step; DWORD code; };

static void require(bool ok, const char* step) {
    if (!ok) throw Failure{step, GetLastError()};
}

struct Handle {
    HANDLE value = nullptr;
    ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
    Handle() = default;
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
};

struct Profile {
    std::wstring name;
    PSID sid = nullptr;
    ~Profile() {
        if (sid) {
            if (FAILED(DeleteAppContainerProfile(name.c_str()))) std::fputs("sandbox profile cleanup failed\n", stderr);
            FreeSid(sid);
        }
    }
};

static fs::path modulePath() {
    std::vector<wchar_t> path(32768);
    DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    require(length > 0 && length < path.size(), "launcher path");
    return std::wstring(path.data(), length);
}

static fs::path makeProfile(Profile& profile) {
    GUID guid{};
    wchar_t id[40]{};
    require(SUCCEEDED(CoCreateGuid(&guid)) && StringFromGUID2(guid, id, 40), "unique id");
    profile.name = L"Yingzhou.Native." + std::wstring(id + 1, 36);
    HRESULT result = CreateAppContainerProfile(profile.name.c_str(), profile.name.c_str(), L"Yingzhou native host", nullptr, 0, &profile.sid);
    if (FAILED(result)) throw Failure{"create profile", static_cast<DWORD>(result)};
    LPWSTR sidText = nullptr;
    require(ConvertSidToStringSidW(profile.sid, &sidText), "package SID");
    LPWSTR folder = nullptr;
    result = GetAppContainerFolderPath(sidText, &folder);
    LocalFree(sidText);
    if (FAILED(result)) throw Failure{"profile path", static_cast<DWORD>(result)};
    fs::path root(folder);
    CoTaskMemFree(folder);
    return root;
}

static std::wstring environment(const fs::path& work) {
    std::wstring block;
    for (auto key : {L"APPDATA", L"LOCALAPPDATA", L"SystemRoot", L"TEMP", L"TMP", L"WINDIR"}) {
        std::wstring value;
        if (wcscmp(key, L"TEMP") == 0 || wcscmp(key, L"TMP") == 0) value = work.wstring();
        else if (auto original = _wgetenv(key)) value = original;
        if (value.empty()) continue;
        block.append(key).append(L"=").append(value).push_back(0);
    }
    block.push_back(0);
    return block;
}

static DWORD run(const Profile& profile, const fs::path& root, const fs::path& target) {
    alignas(void*) BYTE sid[SECURITY_MAX_SID_SIZE];
    DWORD sidLength = sizeof(sid);
    require(CreateWellKnownSid(WinCapabilityInternetClientSid, nullptr, sid, &sidLength), "internet capability");
    SID_AND_ATTRIBUTES capability{sid, SE_GROUP_ENABLED};
    SECURITY_CAPABILITIES capabilities{profile.sid, &capability, 1, 0};
    DWORD policy = PROCESS_CREATION_CHILD_PROCESS_RESTRICTED;
    Handle pipes[3];
    HANDLE inherited[3];
    DWORD streams[] = {STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE};
    for (int index = 0; index < 3; ++index) {
        require(DuplicateHandle(GetCurrentProcess(), GetStdHandle(streams[index]), GetCurrentProcess(), &pipes[index].value, 0, TRUE, DUPLICATE_SAME_ACCESS), "standard pipe");
        inherited[index] = pipes[index].value;
    }
    SIZE_T size = 0;
    InitializeProcThreadAttributeList(nullptr, 3, 0, &size);
    std::vector<BYTE> storage(size);
    auto attrs = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
    require(InitializeProcThreadAttributeList(attrs, 3, 0, &size), "attribute list");
    struct Attributes { LPPROC_THREAD_ATTRIBUTE_LIST list; ~Attributes() { DeleteProcThreadAttributeList(list); } } attributes{attrs};
    require(UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, &capabilities, sizeof(capabilities), nullptr, nullptr), "container token");
    require(UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_CHILD_PROCESS_POLICY, &policy, sizeof(policy), nullptr, nullptr), "child policy");
    require(UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited, sizeof(inherited), nullptr, nullptr), "pipe allowlist");
    Handle job;
    job.value = CreateJobObjectW(nullptr, nullptr);
    require(job.value != nullptr, "job");
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
    limits.BasicLimitInformation.ActiveProcessLimit = 1;
    require(SetInformationJobObject(job.value, JobObjectExtendedLimitInformation, &limits, sizeof(limits)), "job policy");
    STARTUPINFOEXW startup{};
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = inherited[0];
    startup.StartupInfo.hStdOutput = inherited[1];
    startup.StartupInfo.hStdError = inherited[2];
    wchar_t desktop[] = L"winsta0\\default";
    startup.StartupInfo.lpDesktop = desktop;
    startup.lpAttributeList = attrs;
    auto env = environment(root / L"work");
    auto command = L"\"" + target.wstring() + L"\"";
    PROCESS_INFORMATION child{};
    DWORD flags = EXTENDED_STARTUPINFO_PRESENT | DETACHED_PROCESS | CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT;
    require(CreateProcessW(target.c_str(), command.data(), nullptr, nullptr, TRUE, flags, env.data(), root.c_str(), &startup.StartupInfo, &child), "create isolated host");
    Handle process, thread;
    process.value = child.hProcess;
    thread.value = child.hThread;
    if (!AssignProcessToJobObject(job.value, process.value)) {
        DWORD error = GetLastError();
        TerminateProcess(process.value, 1);
        WaitForSingleObject(process.value, INFINITE);
        throw Failure{"assign job", error};
    }
    require(ResumeThread(thread.value) != static_cast<DWORD>(-1), "resume host");
    if (WaitForSingleObject(process.value, 38000) != WAIT_OBJECT_0) {
        TerminateJobObject(job.value, 124);
        WaitForSingleObject(process.value, INFINITE);
        return 124;
    }
    DWORD status = 1;
    require(GetExitCodeProcess(process.value, &status), "host status");
    return status;
}

int wmain(int argc, wchar_t**) {
    if (argc != 1) return 2;
    try {
        auto source = modulePath().parent_path() / L"ganfan-host.exe";
        Profile profile;
        auto root = makeProfile(profile);
        fs::create_directory(root / L"work");
        auto target = root / L"ganfan-host.exe";
        fs::copy_file(source, target);
        return run(profile, root, target);
    } catch (const Failure& error) {
        std::fprintf(stderr, "sandbox %s failed (%lu)\n", error.step, error.code);
    } catch (const std::exception&) {
        std::fputs("sandbox filesystem setup failed\n", stderr);
    }
    return 1;
}
