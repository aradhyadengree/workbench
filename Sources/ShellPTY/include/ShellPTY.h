#ifndef SHELLPTY_H
#define SHELLPTY_H

#include <sys/types.h>

/// zdotdir: directory holding the Terminal pane's .zshrc, or NULL for a bare `zsh -f`.
pid_t start_shell(const char *folder, int *master, const char *zdotdir);
pid_t start_chat(const char *folder, int *master, int claude);
void resize_pty(int master, int rows, int cols);

#endif
