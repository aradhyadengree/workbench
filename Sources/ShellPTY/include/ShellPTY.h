#ifndef SHELLPTY_H
#define SHELLPTY_H

#include <sys/types.h>

pid_t start_shell(const char *folder, int *master);
pid_t start_chat(const char *folder, int *master, int claude);
void resize_pty(int master, int rows, int cols);

#endif
