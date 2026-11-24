#include "ShellPTY.h"
#include <util.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>

extern char **environ;

static pid_t spawn_shell(const char *folder, int *master, int chat) {
    size_t n = 0, kept = 0;
    while (environ[n]) n++;
    char **env = calloc(n + 15, sizeof(char *));
    if (!env) return -1;
    for (size_t i = 0; i < n; i++) {
        if (strncmp(environ[i], "TERM=", 5) &&
            strncmp(environ[i], "PS1=", 4) &&
            strncmp(environ[i], "PROMPT_EOL_MARK=", 16) &&
            strncmp(environ[i], "CLICOLOR=", 9) &&
            strncmp(environ[i], "COLORTERM=", 10) &&
            strncmp(environ[i], "LSCOLORS=", 9)) {
            env[kept++] = environ[i];
        }
    }
    env[kept++] = "TERM=xterm-256color";
    env[kept++] = "COLORTERM=truecolor";
    env[kept++] = "CLICOLOR=1";
    env[kept++] = "CLICOLOR_FORCE=1";
    env[kept++] = "LSCOLORS=GxFxCxDxBxegedabagaced";
    env[kept++] = "PS1=%F{38;5;39}%1~%f %F{38;5;82}❯%f ";
    env[kept++] = "PROMPT_EOL_MARK=";
    
    struct winsize size = {.ws_row = 32, .ws_col = 120};
    pid_t child = forkpty(master, NULL, NULL, &size);
    if (child == 0) {
        if (chdir(folder) < 0) _exit(126);
        char *argv[] = {"zsh", "-f", "+Z", "-o", "no_prompt_sp", "-i", NULL};
        char *login[] = {"zsh", "-il", NULL};
        char *claude[] = {"zsh", "-ilc", "export PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"; exec claude", NULL};
        execve("/bin/zsh", chat == 2 ? claude : chat == 1 ? login : argv, env);
        _exit(127);
    }
    if (child > 0) fcntl(*master, F_SETFD, FD_CLOEXEC);
    free(env);
    return child;
}

pid_t start_shell(const char *folder, int *master) { return spawn_shell(folder, master, 0); }
pid_t start_chat(const char *folder, int *master, int claude) { return spawn_shell(folder, master, claude ? 2 : 1); }

void resize_pty(int master, int rows, int cols) {
    if (master < 0) return;
    struct winsize size;
    size.ws_row = (unsigned short)(rows > 0 ? rows : 24);
    size.ws_col = (unsigned short)(cols > 0 ? cols : 80);
    size.ws_xpixel = 0;
    size.ws_ypixel = 0;
    ioctl(master, TIOCSWINSZ, &size);
}
