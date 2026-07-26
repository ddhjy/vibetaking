//
//  ClipboardOffload.h
//
//  Native offload handler for `apple-clipboard` — read/write UIPasteboard.
//
//  Derived from OpenMinis (https://github.com/OpenMinis/OpenMinis).
//  Copyright (C) OpenMinis contributors. Licensed under GPL-3.0; see LICENSE.
//  Modifications for vibetaking: exported CLI-style entry point instead of
//  iSH kernel handler registration.
//

#ifndef ClipboardOffload_h
#define ClipboardOffload_h

/// CLI-style entry point. argv follows `apple-clipboard <cmd> [options]`;
/// output (JSON envelope) is written to stdout_fd, help text to stderr_fd.
int apple_clipboard_main(int argc, char **argv,
                         int stdin_fd, int stdout_fd, int stderr_fd);

#endif /* ClipboardOffload_h */
