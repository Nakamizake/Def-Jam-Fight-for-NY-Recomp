/* Def Jam: Fight for NY - Windows launcher (DefJam.exe).
 *
 * Starts the recompiled game from the install folder. When the game has not been built yet
 * (no module or no extracted disc), it asks for the player's disc image and runs
 * setup\build-game.ps1 first; nothing game-derived ships with the package.
 *
 *   DefJam.exe            play (building first if needed)
 *   DefJam.exe --rebuild  build again: from a newly chosen disc image, or, if the picker is
 *                         cancelled, from the game already extracted
 *
 * A GUI program, so no console window flashes up. The runtime's own console output goes to
 * logs\runtime.log, which is the first thing to look at when the game will not start.
 *
 * Built by scripts/package.ps1 with the bundled Clang:
 *   clang DefJam.c -o DefJam.exe -municode -mwindows -O2 -lcomdlg32
 */

#include <windows.h>
#include <commdlg.h>
#include <stdlib.h>
#include <wchar.h>

#define APP_TITLE L"Def Jam: Fight for NY"
#define GAME_ID L"GNWE69"
#define CMDLINE_MAX 4096

static wchar_t g_root[MAX_PATH];

static void show_error(const wchar_t *message)
{
    MessageBoxW(NULL, message, APP_TITLE, MB_OK | MB_ICONERROR);
}

/* <install folder>\relative */
static void root_path(wchar_t *out, size_t size, const wchar_t *relative)
{
    _snwprintf(out, size, L"%ls\\%ls", g_root, relative);
    out[size - 1] = L'\0';
}

static BOOL exists(const wchar_t *relative)
{
    wchar_t path[MAX_PATH];
    root_path(path, MAX_PATH, relative);
    return GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES;
}

static BOOL game_is_built(void)
{
    return exists(L"module\\g" GAME_ID L"_recomp.dll") && exists(L"game\\sys\\main.dol");
}

static BOOL pick_disc_image(wchar_t *out, DWORD size)
{
    OPENFILENAMEW dialog;
    ZeroMemory(&dialog, sizeof dialog);
    out[0] = L'\0';
    dialog.lStructSize = sizeof dialog;
    dialog.lpstrFilter = L"GameCube disc image (*.iso)\0*.iso\0All files (*.*)\0*.*\0";
    dialog.lpstrFile = out;
    dialog.nMaxFile = size;
    dialog.lpstrTitle = L"Choose your Def Jam: Fight for NY disc image (GameCube, USA)";
    dialog.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
    return GetOpenFileNameW(&dialog);
}

/* Runs a command line and waits for it. Returns its exit code, or -1 if it did not start.
 * output, when given, receives the child's stdout and stderr. */
static int run(wchar_t *command_line, DWORD flags, HANDLE output)
{
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    DWORD code = (DWORD)-1;

    ZeroMemory(&startup, sizeof startup);
    startup.cb = sizeof startup;
    if (output != NULL) {
        startup.dwFlags = STARTF_USESTDHANDLES;
        startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
        startup.hStdOutput = output;
        startup.hStdError = output;
    }
    ZeroMemory(&process, sizeof process);
    /* CreateProcessW may write to the command line, so it must be a writable buffer. */
    if (!CreateProcessW(NULL, command_line, NULL, NULL, output != NULL, flags, NULL, g_root,
                        &startup, &process))
        return -1;
    WaitForSingleObject(process.hProcess, INFINITE);
    GetExitCodeProcess(process.hProcess, &code);
    CloseHandle(process.hProcess);
    CloseHandle(process.hThread);
    return (int)code;
}

/* Runs setup\build-game.ps1 in its own console window, so the player can follow it.
 * An empty disc_image rebuilds from the game already extracted. -ExecutionPolicy Bypass
 * applies to that one PowerShell process and changes nothing system-wide. */
static BOOL build_game(const wchar_t *disc_image)
{
    wchar_t script[MAX_PATH], command_line[CMDLINE_MAX];
    int code;

    root_path(script, MAX_PATH, L"setup\\build-game.ps1");
    if (disc_image[0] != L'\0')
        _snwprintf(command_line, CMDLINE_MAX,
                   L"powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%ls\" -Iso \"%ls\"",
                   script, disc_image);
    else
        _snwprintf(command_line, CMDLINE_MAX,
                   L"powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%ls\"", script);
    command_line[CMDLINE_MAX - 1] = L'\0';

    code = run(command_line, CREATE_NEW_CONSOLE, NULL);
    if (code == -1) {
        show_error(L"Could not start PowerShell to build the game.");
        return FALSE;
    }
    return code == 0 && game_is_built();
}

/* Starts the runtime with its console hidden and its output in logs\runtime.log. */
static int play(void)
{
    wchar_t runner[MAX_PATH], game[MAX_PATH], module[MAX_PATH], user[MAX_PATH], logs[MAX_PATH],
        log_file[MAX_PATH], command_line[CMDLINE_MAX];
    SECURITY_ATTRIBUTES inheritable = {sizeof inheritable, NULL, TRUE};
    HANDLE log;
    int code;

    root_path(runner, MAX_PATH, L"bin\\moderngekko-run.exe");
    root_path(game, MAX_PATH, L"game");
    root_path(module, MAX_PATH, L"module\\g" GAME_ID L"_recomp.dll");
    root_path(user, MAX_PATH, L"userdata");
    root_path(logs, MAX_PATH, L"logs");
    root_path(log_file, MAX_PATH, L"logs\\runtime.log");
    CreateDirectoryW(user, NULL);
    CreateDirectoryW(logs, NULL);

    _snwprintf(command_line, CMDLINE_MAX,
               L"\"%ls\" --game \"%ls\" --module \"%ls\" --user-dir \"%ls\" --title \"%ls\"",
               runner, game, module, user, APP_TITLE);
    command_line[CMDLINE_MAX - 1] = L'\0';

    log = CreateFileW(log_file, GENERIC_WRITE, FILE_SHARE_READ, &inheritable, CREATE_ALWAYS,
                      FILE_ATTRIBUTE_NORMAL, NULL);
    code = run(command_line, CREATE_NO_WINDOW, log == INVALID_HANDLE_VALUE ? NULL : log);
    if (log != INVALID_HANDLE_VALUE)
        CloseHandle(log);

    if (code == -1) {
        show_error(L"Could not start bin\\moderngekko-run.exe. Reinstalling the game may fix it.");
        return 1;
    }
    if (code != 0) {
        wchar_t message[MAX_PATH + 128];
        _snwprintf(message, MAX_PATH + 128,
                   L"The game closed with an error (code %d).\n\nDetails are in:\n%ls", code,
                   log_file);
        message[MAX_PATH + 127] = L'\0';
        show_error(message);
    }
    return code;
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR arguments, int show)
{
    wchar_t disc_image[MAX_PATH];
    int argc;
    wchar_t **argv;
    BOOL rebuild = FALSE;
    (void)instance;
    (void)previous;
    (void)arguments;
    (void)show;

    /* The install folder is wherever this exe is; shortcuts may set another working folder. */
    if (!GetModuleFileNameW(NULL, g_root, MAX_PATH) || !wcsrchr(g_root, L'\\')) {
        show_error(L"Could not determine the game folder.");
        return 1;
    }
    *wcsrchr(g_root, L'\\') = L'\0';

    argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (argv != NULL) {
        for (int i = 1; i < argc; ++i)
            if (_wcsicmp(argv[i], L"--rebuild") == 0)
                rebuild = TRUE;
        LocalFree(argv);
    }

    if (rebuild) {
        /* Cancelling the picker rebuilds from the extracted game, when there is one. */
        if (!pick_disc_image(disc_image, MAX_PATH) && !exists(L"game\\sys\\main.dol"))
            return 1;
        if (!build_game(disc_image))
            return 1;
        MessageBoxW(NULL, L"The game was rebuilt.", APP_TITLE, MB_OK | MB_ICONINFORMATION);
        return 0;
    }

    if (!game_is_built()) {
        if (MessageBoxW(NULL,
                        L"The game has not been built yet.\n\n"
                        L"It is built once, on this PC, from your own disc image of Def Jam: "
                        L"Fight for NY (GameCube, USA). This takes several minutes.\n\n"
                        L"Choose the disc image now?",
                        APP_TITLE, MB_YESNO | MB_ICONQUESTION) != IDYES)
            return 1;
        if (!pick_disc_image(disc_image, MAX_PATH))
            return 1;
        if (!build_game(disc_image))
            return 1;
    }
    return play();
}
