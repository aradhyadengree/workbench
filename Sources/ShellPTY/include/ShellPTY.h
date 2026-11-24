#ifndef SHELLPTY_H
#define SHELLPTY_H

#include <sys/types.h>

/// zdotdir: Workbench's wrapper dotfiles (TerminalPaneRC), or NULL to read the user's directly.
pid_t start_shell(const char *folder, int *master, const char *zdotdir);
pid_t start_chat(const char *folder, int *master, int claude);
void resize_pty(int master, int rows, int cols);

#endif
