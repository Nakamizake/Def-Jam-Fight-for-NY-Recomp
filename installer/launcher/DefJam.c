/* Def Jam: Fight for NY - Windows launcher (DefJam.exe).
 *
 * Starts the recompiled game from the install folder. When the game has not been built yet
 * (no module or no extracted disc), it asks for the player's disc image and runs
 * setup\build-game.ps1 first; nothing game-derived ships with the package.
 *
 *   DefJam.exe            play (building first if needed)
 *   DefJam.exe --rebuild  build again: from a newly chosen disc image, or, if the picker is
 *                         cancelled, from the game already extracted
 *   DefJam.exe --optimize build again optimised for this PC: the game plays itself for a
 *                         few minutes to measure where its time goes (PGO); ~20 minutes
 *   DefJam.exe --ps2-extras
 *                         let the player pick what to take from their PlayStation 2 disc image
 *                         (HD textures, music, ...), build each pick as a mod
 *                         (modding\ps2_extras.py) and switch it on
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
#include <string.h>
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
 * An empty disc_image rebuilds from the game already extracted; optimize adds -Optimize.
 * -ExecutionPolicy Bypass applies to that one PowerShell process and changes nothing
 * system-wide. */
static BOOL build_game(const wchar_t *disc_image, BOOL optimize)
{
    wchar_t script[MAX_PATH], command_line[CMDLINE_MAX];
    const wchar_t *mode = optimize ? L" -Optimize" : L"";
    int code;

    root_path(script, MAX_PATH, L"setup\\build-game.ps1");
    if (disc_image[0] != L'\0')
        _snwprintf(command_line, CMDLINE_MAX,
                   L"powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%ls\" -Iso \"%ls\"%ls",
                   script, disc_image, mode);
    else
        _snwprintf(command_line, CMDLINE_MAX,
                   L"powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%ls\"%ls", script,
                   mode);
    command_line[CMDLINE_MAX - 1] = L'\0';

    code = run(command_line, CREATE_NEW_CONSOLE, NULL);
    if (code == -1) {
        show_error(L"Could not start PowerShell to build the game.");
        return FALSE;
    }
    return code == 0 && game_is_built();
}

static BOOL pick_ps2_image(wchar_t *out, DWORD size)
{
    OPENFILENAMEW dialog;
    ZeroMemory(&dialog, sizeof dialog);
    out[0] = L'\0';
    dialog.lStructSize = sizeof dialog;
    dialog.lpstrFilter = L"PlayStation 2 disc image (*.iso)\0*.iso\0All files (*.*)\0*.*\0";
    dialog.lpstrFile = out;
    dialog.nMaxFile = size;
    dialog.lpstrTitle = L"Choose your Def Jam: Fight for NY disc image (PlayStation 2)";
    dialog.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
    return GetOpenFileNameW(&dialog);
}

/* What modding\ps2_extras.py can take from the PS2 disc, each built as a mod of its own. */
static const struct ps2_extra {
    const wchar_t *option; /* ps2_extras.py switch */
    const wchar_t *mod;    /* the mod folder it builds, userdata\Load\Mods\<mod> */
    const wchar_t *label;  /* its checkbox */
} PS2_EXTRAS[] = {
    {L"--textures", L"PS2Textures",
     L"HD textures: most of the game's textures at twice the resolution (about 250 MB, a "
     L"minute or two)"},
    {L"--music", L"PS2Music",
     L"Music: the soundtrack in the PS2's higher quality, plus the 12 songs the GameCube "
     L"release left out (about 670 MB, under a minute)"},
};
#define PS2_EXTRA_COUNT (sizeof PS2_EXTRAS / sizeof PS2_EXTRAS[0])
#define ID_FIRST_EXTRA 100

/* Appends a control to an in-memory dialog template: its class as an atom (0x0080 button,
 * 0x0082 static), its text, and no creation data. */
static WORD *add_dialog_item(WORD *at, DWORD style, short x, short y, short cx, short cy, WORD id,
                             WORD atom, const wchar_t *text)
{
    DLGITEMTEMPLATE *item;
    at = (WORD *)(((ULONG_PTR)at + 3) & ~(ULONG_PTR)3); /* items are DWORD-aligned */
    item = (DLGITEMTEMPLATE *)at;
    item->style = style | WS_CHILD | WS_VISIBLE;
    item->dwExtendedStyle = 0;
    item->x = x;
    item->y = y;
    item->cx = cx;
    item->cy = cy;
    item->id = id;
    at = (WORD *)(item + 1);
    *at++ = 0xFFFF;
    *at++ = atom;
    wcscpy((wchar_t *)at, text);
    at += wcslen(text) + 1;
    *at++ = 0;
    return at;
}

static INT_PTR CALLBACK ps2_extras_proc(HWND dialog, UINT message, WPARAM wparam, LPARAM lparam)
{
    static BOOL *chosen;
    switch (message) {
    case WM_INITDIALOG:
        chosen = (BOOL *)lparam;
        for (size_t i = 0; i < PS2_EXTRA_COUNT; ++i)
            CheckDlgButton(dialog, ID_FIRST_EXTRA + (int)i, BST_CHECKED);
        return TRUE;
    case WM_COMMAND:
        if (LOWORD(wparam) == IDOK) {
            BOOL any = FALSE;
            for (size_t i = 0; i < PS2_EXTRA_COUNT; ++i) {
                chosen[i] = IsDlgButtonChecked(dialog, ID_FIRST_EXTRA + (int)i) == BST_CHECKED;
                any |= chosen[i];
            }
            if (!any) {
                MessageBoxW(dialog, L"Tick at least one of the extras.", APP_TITLE,
                            MB_OK | MB_ICONINFORMATION);
                return TRUE;
            }
            EndDialog(dialog, IDOK);
            return TRUE;
        }
        if (LOWORD(wparam) == IDCANCEL) {
            EndDialog(dialog, IDCANCEL);
            return TRUE;
        }
        break;
    }
    return FALSE;
}

/* Asks which extras to build, all ticked to begin with. FALSE if the player cancels. */
static BOOL choose_ps2_extras(BOOL chosen[PS2_EXTRA_COUNT])
{
    static DWORD template_buffer[1024]; /* the template must be DWORD-aligned */
    const short width = 280, top = 76, row = 30;
    const short height = top + row * (short)PS2_EXTRA_COUNT + 26;
    DLGTEMPLATE *dialog = (DLGTEMPLATE *)template_buffer;
    WORD *at;

    ZeroMemory(template_buffer, sizeof template_buffer);
    dialog->style = DS_MODALFRAME | DS_CENTER | DS_SETFONT | WS_POPUP | WS_CAPTION | WS_SYSMENU;
    dialog->cx = width;
    dialog->cy = height;
    at = (WORD *)(dialog + 1);
    *at++ = 0; /* no menu */
    *at++ = 0; /* the standard dialog class */
    wcscpy((wchar_t *)at, APP_TITLE L" - PS2 extras");
    at += wcslen((wchar_t *)at) + 1;
    *at++ = 9; /* font size, then name */
    wcscpy((wchar_t *)at, L"Segoe UI");
    at += wcslen((wchar_t *)at) + 1;

    at = add_dialog_item(at, SS_LEFT, 8, 8, width - 16, top - 14, (WORD)-1, 0x0082,
                         L"Take more from the PlayStation 2 version of the game, out of your "
                         L"own disc image of it (.iso). Each pick becomes a mod of its own, "
                         L"switched on when it is built; Esc > MODS switches it off again.\n\n"
                         L"The disc image is only read. A message appears when it is done.");
    for (size_t i = 0; i < PS2_EXTRA_COUNT; ++i)
        at = add_dialog_item(at, BS_AUTOCHECKBOX | BS_MULTILINE | BS_TOP | WS_TABSTOP, 8,
                             (short)(top + row * (short)i), width - 16, row - 4,
                             (WORD)(ID_FIRST_EXTRA + i), 0x0080, PS2_EXTRAS[i].label);
    at = add_dialog_item(at, BS_DEFPUSHBUTTON | WS_TABSTOP, width - 172, height - 22, 104, 15,
                         IDOK, 0x0080, L"Choose the PS2 disc image...");
    at = add_dialog_item(at, BS_PUSHBUTTON | WS_TABSTOP, width - 62, height - 22, 54, 15,
                         IDCANCEL, 0x0080, L"Cancel");
    dialog->cdit = (WORD)(PS2_EXTRA_COUNT + 3);

    return DialogBoxIndirectParamW(GetModuleHandleW(NULL), dialog, NULL, ps2_extras_proc,
                                   (LPARAM)chosen) == IDOK;
}

#define ID_PROGRESS_STEP 200
#define ID_PROGRESS_LINE 201
#define PROGRESS_TIMER 1

/* A tool running behind the progress window: the process, the job holding it and every process
 * it starts (ps2_extras.py converts with a pool of workers), and the log it writes. */
struct progress_task {
    HANDLE process;
    HANDLE job;
    const wchar_t *log_file;
    const wchar_t *step;
};

/* The last non-empty line of a UTF-8 log, for the progress window; empty if there is none. */
static void last_log_line(const wchar_t *log_file, wchar_t *out, int size)
{
    char tail[1024];
    DWORD got = 0;
    LARGE_INTEGER length;
    HANDLE file = CreateFileW(log_file, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    out[0] = L'\0';
    if (file == INVALID_HANDLE_VALUE)
        return;
    if (GetFileSizeEx(file, &length)) {
        LARGE_INTEGER start;
        start.QuadPart = length.QuadPart > (LONGLONG)sizeof tail - 1
                             ? length.QuadPart - ((LONGLONG)sizeof tail - 1)
                             : 0;
        if (SetFilePointerEx(file, start, NULL, FILE_BEGIN))
            ReadFile(file, tail, sizeof tail - 1, &got, NULL);
    }
    CloseHandle(file);
    while (got > 0 && (tail[got - 1] == '\n' || tail[got - 1] == '\r' || tail[got - 1] == ' '))
        --got;
    tail[got] = '\0';
    {
        const char *line = strrchr(tail, '\n');
        line = line != NULL ? line + 1 : tail;
        MultiByteToWideChar(CP_UTF8, 0, line, -1, out, size);
        out[size - 1] = L'\0';
    }
}

static INT_PTR CALLBACK progress_proc(HWND dialog, UINT message, WPARAM wparam, LPARAM lparam)
{
    static struct progress_task *task;
    switch (message) {
    case WM_INITDIALOG:
        task = (struct progress_task *)lparam;
        SetDlgItemTextW(dialog, ID_PROGRESS_STEP, task->step);
        SetTimer(dialog, PROGRESS_TIMER, 250, NULL);
        return TRUE;
    case WM_TIMER: {
        wchar_t line[256];
        if (WaitForSingleObject(task->process, 0) == WAIT_OBJECT_0) {
            KillTimer(dialog, PROGRESS_TIMER);
            EndDialog(dialog, IDOK);
            return TRUE;
        }
        last_log_line(task->log_file, line, 256);
        SetDlgItemTextW(dialog, ID_PROGRESS_LINE, line);
        return TRUE;
    }
    case WM_COMMAND:
        if (LOWORD(wparam) == IDCANCEL &&
            MessageBoxW(dialog, L"Stop building the PS2 extras?", APP_TITLE,
                        MB_YESNO | MB_ICONQUESTION) == IDYES) {
            KillTimer(dialog, PROGRESS_TIMER);
            TerminateJobObject(task->job, 1);
            WaitForSingleObject(task->process, 5000);
            EndDialog(dialog, IDCANCEL);
        }
        return TRUE;
    }
    return FALSE;
}

/* Runs a command line with no window while a progress window shows step and the last line of
 * log_file, and waits for it. Cancel ends it and everything it started. Returns its exit code,
 * -1 if it did not start, -2 if the player cancelled. */
static int run_with_progress(wchar_t *command_line, HANDLE log, const wchar_t *log_file,
                             const wchar_t *step)
{
    static DWORD template_buffer[512]; /* the template must be DWORD-aligned */
    const short width = 280, height = 74;
    DLGTEMPLATE *dialog = (DLGTEMPLATE *)template_buffer;
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    struct progress_task task;
    DWORD code = (DWORD)-1;
    INT_PTR result;
    WORD *at;

    /* The job ends the tool and its workers if the player cancels or this launcher is closed. */
    task.job = CreateJobObjectW(NULL, NULL);
    if (task.job == NULL)
        return -1;
    ZeroMemory(&limits, sizeof limits);
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    SetInformationJobObject(task.job, JobObjectExtendedLimitInformation, &limits, sizeof limits);

    ZeroMemory(&startup, sizeof startup);
    startup.cb = sizeof startup;
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    startup.hStdOutput = log;
    startup.hStdError = log;
    ZeroMemory(&process, sizeof process);
    if (!CreateProcessW(NULL, command_line, NULL, NULL, TRUE, CREATE_NO_WINDOW | CREATE_SUSPENDED,
                        NULL, g_root, &startup, &process)) {
        CloseHandle(task.job);
        return -1;
    }
    AssignProcessToJobObject(task.job, process.hProcess);
    ResumeThread(process.hThread);
    CloseHandle(process.hThread);
    task.process = process.hProcess;
    task.log_file = log_file;
    task.step = step;

    ZeroMemory(template_buffer, sizeof template_buffer);
    dialog->style = DS_MODALFRAME | DS_CENTER | DS_SETFONT | WS_POPUP | WS_CAPTION | WS_SYSMENU;
    dialog->cx = width;
    dialog->cy = height;
    at = (WORD *)(dialog + 1);
    *at++ = 0; /* no menu */
    *at++ = 0; /* the standard dialog class */
    wcscpy((wchar_t *)at, APP_TITLE L" - PS2 extras");
    at += wcslen((wchar_t *)at) + 1;
    *at++ = 9; /* font size, then name */
    wcscpy((wchar_t *)at, L"Segoe UI");
    at += wcslen((wchar_t *)at) + 1;
    at = add_dialog_item(at, SS_LEFT, 8, 8, width - 16, 18, ID_PROGRESS_STEP, 0x0082, L"");
    at = add_dialog_item(at, SS_LEFTNOWORDWRAP | SS_ENDELLIPSIS, 8, 30, width - 16, 10,
                         ID_PROGRESS_LINE, 0x0082, L"");
    at = add_dialog_item(at, BS_PUSHBUTTON | WS_TABSTOP, width - 62, height - 22, 54, 15,
                         IDCANCEL, 0x0080, L"Cancel");
    dialog->cdit = 3;

    result = DialogBoxIndirectParamW(GetModuleHandleW(NULL), dialog, NULL, progress_proc,
                                     (LPARAM)&task);
    if (result != IDCANCEL) {
        /* Also when the window could not be shown: then just wait. */
        WaitForSingleObject(task.process, INFINITE);
        GetExitCodeProcess(task.process, &code);
    }
    CloseHandle(task.process);
    CloseHandle(task.job);
    return result == IDCANCEL ? -2 : (int)code;
}

/* Runs modding\ps2_extras.py with the bundled Python, once per chosen extra so that each one
 * that builds is switched on even if another fails, behind a progress window. The output of
 * all of them goes to logs\ps2-extras.log; the mods are switched on in userdata\Config\Mods.ini
 * (where the MODS tab keeps its choices). Returns how many failed, or -1 if the player
 * cancelled. */
static int build_ps2_extras(const wchar_t *ps2_image, const BOOL chosen[PS2_EXTRA_COUNT])
{
    wchar_t python[MAX_PATH], tool[MAX_PATH], files[MAX_PATH], mods[MAX_PATH], logs[MAX_PATH],
        log_file[MAX_PATH], user[MAX_PATH], config[MAX_PATH], mods_ini[MAX_PATH],
        command_line[CMDLINE_MAX], step[512];
    SECURITY_ATTRIBUTES inheritable = {sizeof inheritable, NULL, TRUE};
    HANDLE log;
    int failed = 0, count = 0, done = 0;

    root_path(python, MAX_PATH, L"toolchain\\python\\bin\\python.exe");
    root_path(tool, MAX_PATH, L"modding\\ps2_extras.py");
    root_path(files, MAX_PATH, L"game\\files");
    root_path(mods, MAX_PATH, L"userdata\\Load\\Mods");
    root_path(logs, MAX_PATH, L"logs");
    root_path(log_file, MAX_PATH, L"logs\\ps2-extras.log");
    root_path(user, MAX_PATH, L"userdata");
    root_path(config, MAX_PATH, L"userdata\\Config");
    root_path(mods_ini, MAX_PATH, L"userdata\\Config\\Mods.ini");
    CreateDirectoryW(logs, NULL);
    CreateDirectoryW(user, NULL);
    CreateDirectoryW(config, NULL);

    /* The progress window reads this log while the tool writes it. */
    log = CreateFileW(log_file, GENERIC_WRITE, FILE_SHARE_READ, &inheritable, CREATE_ALWAYS,
                      FILE_ATTRIBUTE_NORMAL, NULL);
    if (log == INVALID_HANDLE_VALUE) {
        show_error(L"Could not write logs\\ps2-extras.log.");
        return (int)PS2_EXTRA_COUNT;
    }
    for (size_t i = 0; i < PS2_EXTRA_COUNT; ++i)
        count += chosen[i] ? 1 : 0;
    for (size_t i = 0; i < PS2_EXTRA_COUNT; ++i) {
        int code;
        if (!chosen[i])
            continue;
        /* -u: unbuffered, so its progress reaches the log (and the window) as it happens. */
        _snwprintf(command_line, CMDLINE_MAX,
                   L"\"%ls\" -u -I \"%ls\" --gc-files \"%ls\" --ps2 \"%ls\" --mods \"%ls\" %ls",
                   python, tool, files, ps2_image, mods, PS2_EXTRAS[i].option);
        command_line[CMDLINE_MAX - 1] = L'\0';
        _snwprintf(step, 512,
                   L"Building extra %d of %d: %ls\nThis takes a few minutes. Keep the game closed "
                   L"until it is done.",
                   ++done, count, PS2_EXTRAS[i].mod);
        step[511] = L'\0';
        code = run_with_progress(command_line, log, log_file, step);
        if (code == -2) {
            failed = -1;
            break;
        }
        if (code == 0)
            WritePrivateProfileStringW(L"Mods", PS2_EXTRAS[i].mod, L"True", mods_ini);
        else
            ++failed;
    }
    CloseHandle(log);
    return failed;
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
    BOOL rebuild = FALSE, optimize = FALSE, ps2_extras = FALSE;
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
            else if (_wcsicmp(argv[i], L"--optimize") == 0)
                optimize = TRUE;
            /* --ps2-textures: what shortcuts from before the extras were called */
            else if (_wcsicmp(argv[i], L"--ps2-extras") == 0 ||
                     _wcsicmp(argv[i], L"--ps2-textures") == 0)
                ps2_extras = TRUE;
        LocalFree(argv);
    }

    if (ps2_extras) {
        BOOL chosen[PS2_EXTRA_COUNT];
        int failed;
        /* Two builds at once would write the same mod folders and log. Held until exit. */
        CreateMutexW(NULL, TRUE, L"Local\\DefJamFFNY-PS2Extras");
        if (GetLastError() == ERROR_ALREADY_EXISTS) {
            show_error(L"The PS2 extras are already being built; wait for the message saying "
                       L"they are done.");
            return 1;
        }
        if (!game_is_built()) {
            show_error(L"Build the game first: start it once from the Def Jam: Fight for NY "
                       L"shortcut, then add the PS2 extras.");
            return 1;
        }
        if (!choose_ps2_extras(chosen) || !pick_ps2_image(disc_image, MAX_PATH))
            return 1;
        failed = build_ps2_extras(disc_image, chosen);
        if (failed < 0) {
            MessageBoxW(NULL, L"Stopped. The extras that were finished before are on.",
                        APP_TITLE, MB_OK | MB_ICONINFORMATION);
            return 1;
        }
        if (failed > 0) {
            show_error(L"Not every extra could be built (the ones that were are on).\n\n"
                       L"Details are in logs\\ps2-extras.log.");
            return 1;
        }
        MessageBoxW(NULL, L"Done: the PS2 extras are on. Start the game as usual.", APP_TITLE,
                    MB_OK | MB_ICONINFORMATION);
        return 0;
    }

    if (optimize) {
        if (!game_is_built()) {
            show_error(L"Build the game first: start it once from the Def Jam: Fight for NY "
                       L"shortcut, then optimize it.");
            return 1;
        }
        if (MessageBoxW(NULL,
                        L"Optimize the game for this PC?\n\n"
                        L"This takes about 20 minutes. The game is compiled again, and in the "
                        L"middle of it a game window opens and plays fights on its own to "
                        L"measure where its time goes. Keyboard and controllers are ignored "
                        L"in that window; closing it cancels the optimization.\n\n"
                        L"Your saves and settings are not touched, and if anything fails the "
                        L"game stays as it is now. The PC will be busy while it runs.",
                        APP_TITLE, MB_OKCANCEL | MB_ICONINFORMATION) != IDOK)
            return 1;
        disc_image[0] = L'\0';
        if (!build_game(disc_image, TRUE)) {
            show_error(L"The optimization did not finish; the game is unchanged.\n\n"
                       L"Details are in logs\\build-game.log.");
            return 1;
        }
        MessageBoxW(NULL, L"Done: the game is optimized for this PC. Start it as usual.",
                    APP_TITLE, MB_OK | MB_ICONINFORMATION);
        return 0;
    }

    if (rebuild) {
        /* Cancelling the picker rebuilds from the extracted game, when there is one. */
        if (!pick_disc_image(disc_image, MAX_PATH) && !exists(L"game\\sys\\main.dol"))
            return 1;
        if (!build_game(disc_image, FALSE))
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
        if (!build_game(disc_image, FALSE))
            return 1;
    }
    return play();
}
