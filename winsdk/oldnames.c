
#if defined _M_IX86
    #define C_PREFIX "_"
#elif defined _M_X64 || defined _M_ARM || defined _M_ARM64
    #define C_PREFIX ""
#else
    #error Unsupported architecture
#endif

#define DECLARE_ALTERNATE_NAME(name, alternate_name)  \
    __pragma(comment(linker, "/alternatename:" C_PREFIX #name "=" C_PREFIX #alternate_name))
#define DECLARE_ALTERNATE__(name) DECLARE_ALTERNATE_NAME(name, _##name)

DECLARE_ALTERNATE_NAME(time,      _time32);
DECLARE_ALTERNATE_NAME(ftime,     _ftime32);
DECLARE_ALTERNATE_NAME(utime,     _utime32);
DECLARE_ALTERNATE_NAME(stat,      _stat32);
DECLARE_ALTERNATE_NAME(fstat,     _fstat32);
DECLARE_ALTERNATE_NAME(strcmpi,   _stricmp);
DECLARE_ALTERNATE_NAME(localtime, _localtime32);

DECLARE_ALTERNATE__(fcloseall );
DECLARE_ALTERNATE__(tzset     );
DECLARE_ALTERNATE__(execvpe   );
DECLARE_ALTERNATE__(execvp    );
DECLARE_ALTERNATE__(execve    );
DECLARE_ALTERNATE__(execv     );
DECLARE_ALTERNATE__(execlpe   );
DECLARE_ALTERNATE__(execlp    );
DECLARE_ALTERNATE__(execle    );
DECLARE_ALTERNATE__(execl     );
DECLARE_ALTERNATE__(control87);
DECLARE_ALTERNATE__(sys_errlist);
DECLARE_ALTERNATE__(filelength);
DECLARE_ALTERNATE__(control87 );
DECLARE_ALTERNATE__(_wcsicoll );
DECLARE_ALTERNATE__(_wcsupr   );
DECLARE_ALTERNATE__(_wcslwr   );
DECLARE_ALTERNATE__(_wcsset   );
DECLARE_ALTERNATE__(_wcsrev   );
DECLARE_ALTERNATE__(_wcsnset  );
DECLARE_ALTERNATE__(_wcsnicmp );
DECLARE_ALTERNATE__(_wcsicmp  );
DECLARE_ALTERNATE__(_wcsdup   );
DECLARE_ALTERNATE__(_dup      );
DECLARE_ALTERNATE__(_tzset    );
DECLARE_ALTERNATE__(_tzname   );
DECLARE_ALTERNATE__(_timezone );
DECLARE_ALTERNATE__(_strupr   );
DECLARE_ALTERNATE__(_strset   );
DECLARE_ALTERNATE__(_strrev   );
DECLARE_ALTERNATE__(_strnset  );
DECLARE_ALTERNATE__(_strnicmp );
DECLARE_ALTERNATE__(_strlwr   );
DECLARE_ALTERNATE__(_strdup   );
DECLARE_ALTERNATE__(_stricmp  );
DECLARE_ALTERNATE__(_tempnam  );
DECLARE_ALTERNATE__(_rmtmp    );
DECLARE_ALTERNATE__(_putw     );
DECLARE_ALTERNATE__(_getw     );
DECLARE_ALTERNATE__(_fputchar );
DECLARE_ALTERNATE__(_flushall );
DECLARE_ALTERNATE__(_fileno   );
DECLARE_ALTERNATE__(_fgetchar );
DECLARE_ALTERNATE__(_fdopen   );
DECLARE_ALTERNATE__(_ultoa    );
DECLARE_ALTERNATE__(_swab     );
DECLARE_ALTERNATE__(_putenv   );
DECLARE_ALTERNATE__(_onexit   );
DECLARE_ALTERNATE__(_ltoa     );
DECLARE_ALTERNATE__(_itoa     );
DECLARE_ALTERNATE__(_yn       );
DECLARE_ALTERNATE__(_y1       );
DECLARE_ALTERNATE__(_y0       );
DECLARE_ALTERNATE__(_jn       );
DECLARE_ALTERNATE__(_j1       );
DECLARE_ALTERNATE__(_j0       );
DECLARE_ALTERNATE__(_cabs     );
DECLARE_ALTERNATE__(_HUGE     );
DECLARE_ALTERNATE__(_gcvt     );
DECLARE_ALTERNATE__(_fcvt     );
DECLARE_ALTERNATE__(_ecvt     );
DECLARE_ALTERNATE__(_lsearch  );
DECLARE_ALTERNATE__(_lfind    );
DECLARE_ALTERNATE__(_spawnvpe );
DECLARE_ALTERNATE__(_spawnvp  );
DECLARE_ALTERNATE__(_spawnve  );
DECLARE_ALTERNATE__(_spawnv   );
DECLARE_ALTERNATE__(_spawnlpe );
DECLARE_ALTERNATE__(_spawnlp  );
DECLARE_ALTERNATE__(_spawnle  );
DECLARE_ALTERNATE__(_spawnl   );
DECLARE_ALTERNATE__(_getpid   );
DECLARE_ALTERNATE__(_cwait    );
DECLARE_ALTERNATE__(_memicmp  );
DECLARE_ALTERNATE__(_memccpy  );
DECLARE_ALTERNATE__(_write    );
DECLARE_ALTERNATE__(_unlink   );
DECLARE_ALTERNATE__(_umask    );
DECLARE_ALTERNATE__(_tell     );
DECLARE_ALTERNATE__(_sys_nerr );
DECLARE_ALTERNATE__(_sopen    );
DECLARE_ALTERNATE__(_setmode  );
DECLARE_ALTERNATE__(_read     );
DECLARE_ALTERNATE__(_open     );
DECLARE_ALTERNATE__(_mktemp   );
DECLARE_ALTERNATE__(_lseek    );
DECLARE_ALTERNATE__(_locking  );
DECLARE_ALTERNATE__(_isatty   );
DECLARE_ALTERNATE__(_eof      );
DECLARE_ALTERNATE__(_dup2     );
DECLARE_ALTERNATE__(_creat    );
DECLARE_ALTERNATE__(_close    );
DECLARE_ALTERNATE__(_chsize   );
DECLARE_ALTERNATE__(_chmod    );
DECLARE_ALTERNATE__(_access   );
DECLARE_ALTERNATE__(_rmdir    );
DECLARE_ALTERNATE__(_mkdir    );
DECLARE_ALTERNATE__(_getcwd   );
DECLARE_ALTERNATE__(_chdir    );
DECLARE_ALTERNATE__(_ungetch  );
DECLARE_ALTERNATE__(_putch    );
DECLARE_ALTERNATE__(_kbhit    );
DECLARE_ALTERNATE__(_getche   );
DECLARE_ALTERNATE__(_fpreset  );
DECLARE_ALTERNATE__(_getch    );
DECLARE_ALTERNATE__(_environ  );
DECLARE_ALTERNATE__(_daylight );
DECLARE_ALTERNATE__(_cscanf   );
DECLARE_ALTERNATE__(_cputs    );
DECLARE_ALTERNATE__(_cprintf  );
DECLARE_ALTERNATE__(_cgets    );

// access this symbol to drag in the generated linker directives
int __ref_oldnames;

#if defined _M_X64
int _isnan(double);
int _isnanf(float f) { return _isnan(f); }
#endif
