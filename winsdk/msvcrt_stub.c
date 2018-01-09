#include <windows.h>

#define _CRTALLOC(x) __declspec(allocate(x))

#define __UNKNOWN_APP    0 // abused for DLL
#define __CONSOLE_APP    1
#define __GUI_APP        2

#ifndef _APPTYPE
#define _APPTYPE __CONSOLE_APP
#endif

typedef void(*_PVFV)();

// C init
extern _PVFV __xi_a[];
extern _PVFV __xi_z[];
// C++ init
extern _PVFV __xc_a[];
extern _PVFV __xc_z[];
// C pre-terminators
extern _PVFV __xp_a[];
extern _PVFV __xp_z[];
// C terminators
extern _PVFV __xt_a[];
extern _PVFV __xt_z[];

extern int main (int, char **, char **);
extern void _setargv (void);
extern void term_atexit();

extern IMAGE_DOS_HEADER __ImageBase; // linker generated

extern int __ref_oldnames;

#pragma comment(lib, "kernel32.lib")
#pragma comment(lib, "oldnames.lib")

#if _APPTYPE == __UNKNOWN_APP
BOOL WINAPI
DllMainCRTStartup (HANDLE hDll, DWORD dwReason, LPVOID lpReserved)
{
    BOOL bRet;

    if (dwReason == DLL_PROCESS_ATTACH)
    {
        _initterm_e(__xi_a, __xi_z);
        _initterm(__xc_a, __xc_z);
    }

    bRet = DllMain (hDll, dwReason, lpReserved);

    if (dwReason == DLL_PROCESS_DETACH || dwReason == DLL_PROCESS_ATTACH && !bRet)
    {
        term_atexit();
        _initterm(__xp_a, __xp_z);
        _initterm(__xt_a, __xt_z);
    }
    return bRet;
}

#else // _APPTYPE != __UNKNOWN_APP

extern int    _argc;
extern char **_argv;

/* In MSVCRT.DLL, Microsoft's initialization hook is called __getmainargs(),
 * and it expects a further structure argument, (which we don't use, but pass
 * it as a dummy, with a declared size of zero in its first and only field).
 */
typedef struct _startupinfo { int mode; } _startupinfo;
extern void __getmainargs( int *argc, char ***argv, char ***penv, int glob, _startupinfo *info );

/* The function mainCRTStartup() is the entry point for all
 * console/desktop programs.
 */
#if _APPTYPE == __CONSOLE_APP
void mainCRTStartup(void)
#else
void WinMainCRTStartup(void)
#endif
{
    int nRet, xRet;
    __set_app_type(_APPTYPE);
    __ref_oldnames = 0; // drag in alternate definitions

    /* The MSVCRT.DLL start-up hook requires this invocation
     * protocol...
     */
    char **envp = NULL;
    _startupinfo start_info = { 0 };
    __getmainargs(&_argc, &_argv, &envp, 0, &start_info);

    _initterm(__xi_a, __xi_z);
    _initterm(__xc_a, __xc_z);

#if _APPTYPE == __CONSOLE_APP
    nRet = main(_argc, _argv, envp);
#else
    {
        STARTUPINFOA startupInfo;
        GetStartupInfoA(&startupInfo);
        int showWindowMode = startupInfo.dwFlags & STARTF_USESHOWWINDOW
                           ? startupInfo.wShowWindow : SW_SHOWDEFAULT;
        PCSTR lpszCommandLine = GetCommandLineA();
        nRet = WinMain((HINSTANCE)&__ImageBase, NULL, lpszCommandLine, showWindowMode);
    }
#endif

    term_atexit();
    _initterm(__xp_a, __xp_z);
    _initterm(__xt_a, __xt_z);

    if (nRet == 0)
        nRet = xRet;

    ExitProcess(nRet);
}
#endif // _APPTYPE != __UNKNOWN_APP
