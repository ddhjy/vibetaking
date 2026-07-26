//
//  CalendarOffload.h
//
//  Native offload handler for `apple-calendar` — EventKit events & reminders.
//
//  Derived from OpenMinis (https://github.com/OpenMinis/OpenMinis).
//  Copyright (C) OpenMinis contributors. Licensed under GPL-3.0; see LICENSE.
//  Modifications for vibetaking: exported CLI-style entry point instead of
//  iSH kernel handler registration.
//

#ifndef CalendarOffload_h
#define CalendarOffload_h

#import <Foundation/Foundation.h>

/// CLI-style entry point. argv follows `apple-calendar <cmd> [options]`;
/// output (JSON envelope) is written to stdout_fd, help text to stderr_fd.
int apple_calendar_main(int argc, char **argv,
                        int stdin_fd, int stdout_fd, int stderr_fd);

/// Shared reminder subcommand handlers (used by apple-reminders offload).
int calendar_cmd_reminders(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet);
int calendar_cmd_remind(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet);
int calendar_cmd_update_reminder(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet);
int calendar_cmd_complete_reminder(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet);
int calendar_cmd_delete_reminder(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet);

#endif /* CalendarOffload_h */
