//
//  RemindersOffload.h
//
//  Native offload handler for `apple-reminders` — EventKit reminders.
//
//  Derived from OpenMinis (https://github.com/OpenMinis/OpenMinis).
//  Copyright (C) OpenMinis contributors. Licensed under GPL-3.0; see LICENSE.
//  Modifications for vibetaking: exported CLI-style entry point instead of
//  iSH kernel handler registration.
//

#ifndef RemindersOffload_h
#define RemindersOffload_h

/// CLI-style entry point. argv follows `apple-reminders <cmd> [options]`;
/// output (JSON envelope) is written to stdout_fd, help text to stderr_fd.
int apple_reminders_main(int argc, char **argv,
                         int stdin_fd, int stdout_fd, int stderr_fd);

#endif /* RemindersOffload_h */
