#include "process_manager.h"

process_struct*     running_children;
process_struct*     exited_children;
sigjmp_buf          saved_jump_buf;
int                 pm_can_jump = 0;
int                 terminated = 0;
int                 signaled   = 0;     // indicates that SIGCHLD was signaled
int                 dbg = 0;

int pm_check_pid_status(pid_t pid)
{
  if (pid < 1) return -1; // Illegal
  int err = kill(pid, 0);
  // switch (err) {
  //   case 0:
  //     if (notify) handle_ok(transId);
  //     break;
  //   case EINVAL:
  //     if (notify) handle_error_str(transId, false, "Invalid signal: %d", signal);
  //     break;
  //   case ESRCH:
  //     if (notify) handle_error_str(transId, true, "esrch");
  //     break;
  //   case EPERM:
  //     if (notify) handle_error_str(transId, true, "eperm");
  //     break;
  //   default:
  //     if (notify) handle_error_str(transId, true, strerror(err));
  //     break;
  // }
  return err;
}

int pm_add_env(process_t **ptr, char* value)
{
  process_t *p = *ptr;
  // Expand space, if necessary
  if (p->env_c == p->env_capacity) {
    if (p->env_capacity == 0) p->env_capacity = 1;
    p->env = (char**)realloc(p->env, (p->env_capacity *= 2) * sizeof(char*));
  }
  p->env[p->env_c++] = strdup(value);
  return 0;
}

int pm_new_process(process_t **ptr)
{
  process_t *p = (process_t *) calloc(1, sizeof(process_t));
  if (!p) {
    perror("Could not allocate enough memory to make a new process.\n");
    return -1;
  }
  
  p->env_c = 0;
  p->env_capacity = 0;
  p->env = NULL;
  p->cd = NULL;
  p->nice = 0;
  
  p->command = NULL;
  p->before = NULL;
  p->after = NULL;
  
  *ptr = p;
  return 0;
}

/**
* Check if the process is valid
**/
int pm_process_valid(process_t **ptr)
{
  process_t* p = *ptr;
  if (p->command == NULL) return -1;
  return 0;
}

int pm_free_process(process_t *p)
{
  if (p->command) free(p->command);
  if (p->before) free(p->before);
  if (p->after) free(p->after);
  if (p->cd) free(p->cd);
  
  int i = 0;
  for (i = 0; i < p->env_c; i++) free(p->env[i]);
  if (p->env) free(p->env);
  
  free(p);
  return 0;
}

/*--- Run process ---*/
void pm_gotsignal(int signal)
{ 
  switch(signal) {
    case SIGHUP:
      break;
    case SIGTERM:
    case SIGINT:
    default:
    break;
  }
}

void pm_gotsigchild(int signal, siginfo_t* si, void* context)
{
  // If someone used kill() to send SIGCHLD ignore the event
  if (signal != SIGCHLD) return;
  
  // process_child_signal(si->si_pid);
}
/**
* Setup signal handlers for the process
**/
void pm_setup_signal_handlers()
{
  struct sigaction sact, sterm;
  sterm.sa_handler = pm_gotsignal;
  sigemptyset(&sterm.sa_mask);
  sigaddset(&sterm.sa_mask, SIGCHLD);
  sterm.sa_flags = 0;
  sigaction(SIGINT,  &sterm, NULL);
  sigaction(SIGTERM, &sterm, NULL);
  sigaction(SIGHUP,  &sterm, NULL);
  sigaction(SIGPIPE, &sterm, NULL);
  
  sact.sa_handler = NULL;
  sact.sa_sigaction = pm_gotsigchild;
  sigemptyset(&sact.sa_mask);
  sact.sa_flags = SA_SIGINFO | SA_RESTART | SA_NOCLDSTOP | SA_NODEFER;
  sigaction(SIGCHLD, &sact, NULL);
}

int pm_setup(int read_handle, int write_handle)
{
#ifdef _WIN32
  /* Attention Windows programmers: you need to explicitly set
   * mode of stdin/stdout to binary or else the port program won't work
   */
  setmode(read_handle, O_BINARY);
  setmode(write_handle, O_BINARY);
#endif
  return 0;
}

int expand_command(const char* command, int* argc, char ***argv, int *using_a_script)
{
  char **command_argv = *argv;
  int command_argc = *argc;
  int running_script = *using_a_script;
  const char *full_filepath;
  
  if (!strncmp(command, "#!", 2)) {
    // We are running a shell script command
    char *filename = NULL;
    int size, fd;
    // Note for the future cleanup, that we'll be running a script to cleanup
    running_script = 1;
    snprintf(filename, 40, "/tmp/babysitter.XXXXXXXXX");
    // Make a tempfile in the filename format
    if ((fd = mkstemp(filename)) == -1) {
      fprintf(stderr, "Could not open tempfile: %s\n", filename);
      return -1;
    }
    size = strlen(command);
    // Print the command into the file
    if (write(fd, command, size) == -1) {
      fprintf(stderr, "Could not write command to tempfile: %s\n", filename);
      return -1;
    }

    // Confirm that the command is written
    if (fsync(fd) == -1) {
      fprintf(stderr, "fsync failed for tempfile: %s\n", filename);
      return -1;
    }

    // Close the file descriptor
    close(fd);

    // Modify the command to match call the filename
    // should we chown?
    /*
		if (chown(filename, m_user, m_group) != 0) {
#ifdef DEBUG
     fprintf(stderr, "Could not change owner of '%s' to %d\n", m_script_file.c_str(), m_user);
#endif
		}
		*/

    // Make it executable
    if (chmod(filename, 040700) != 0) {
      fprintf(stderr, "Could not change permissions to '%s' %o\n", filename, 040700);
    }

    // Run in a new process
    command_argv[0] = filename;
    command_argv[1] = NULL;
    command_argc = 1;
  } else {
    int prefix;
    char *cp, *cmdname, *expanded_command;


    // get bare command for path lookup
    for (cp = (char *) command; !isspace(*cp); cp++) ;
    prefix = cp - command;
    cmdname = calloc(prefix, sizeof(char));
    strncpy(cmdname, command, prefix);

    // expand command name to full path
    full_filepath = find_binary(cmdname);

    // build invocable command with args
    expanded_command = calloc(strlen(full_filepath) + strlen(command + prefix) + 1, sizeof(char));
    strcat(expanded_command, full_filepath); 
    strcat(expanded_command, command + prefix);

    command_argv = (char **) malloc(4 * sizeof(char *));
    command_argv[0] = strdup(getenv("SHELL"));
    command_argv[1] = "-c";
    command_argv[2] = expanded_command;
    command_argc = 3;
    
    printf("expanded_command: >>%s<<\n", expanded_command);
  }
  *argc = command_argc;
  *argv = command_argv;
  *using_a_script = running_script;
  
  return 0;
}

pid_t pm_execute(int should_wait, const char* command, const char *cd, int nice, const char** env)
{
  // Setup execution
  char **command_argv = {0};
  int command_argc = 0;
  int running_script = 0;
  
  if (expand_command(command, &command_argc, &command_argv, &running_script)) ;
  
  command_argv[command_argc] = 0;
  
  // Now actually RUN it!
  pid_t pid;
  if (should_wait)
    pid = vfork();
  else
    pid = fork();
    
  switch (pid) {
  case -1: 
    return -1;
  case 0: {
    pm_setup_signal_handlers();
    if (cd != NULL && cd[0] != '\0')
      chdir(cd);
    
    if (execve((const char*)command_argv[0], (char* const*)command_argv, (char* const*) env) < 0) {
      printf("execve failed because: %s\n", strerror(errno));
      return -1;
    }
    exit(-1);
  }
  default:
    // In parent process
    if (nice != INT_MAX && setpriority(PRIO_PROCESS, pid, nice) < 0) 
      ;
    return pid;
  }
}

typedef enum HookT {BEFORE_HOOK, AFTER_HOOK} hook_t;
int run_hook(hook_t t, process_t *process)
{
  if (t == BEFORE_HOOK) {
    printf("running before hook\n");
    pm_execute(1, (const char*)process->before, (const char*)process->cd, (int)process->nice, (const char**)process->env);
  } else if (t == AFTER_HOOK) {
    pm_execute(1, (const char*)process->after, (const char*)process->cd, (int)process->nice, (const char**)process->env);
  }
  return 0;
}

pid_t pm_run_process(process_t *process)
{
  // Safe-ify the env
  process->env[process->env_c] = NULL;
  
  if (process->before) run_hook(BEFORE_HOOK, process);
  pid_t pid = pm_execute(0, (const char*)process->command, process->cd, (int)process->nice, (const char**)process->env);
  if (process->after) run_hook(AFTER_HOOK, process);
  return pid;
}

int pm_check_children(int isTerminated)
{
  return 0;
}

int pm_next_loop()
{
  sigsetjmp(saved_jump_buf, 1); pm_can_jump = 0;

  while (!terminated && (HASH_COUNT(exited_children) > 0 || signaled)) pm_check_children(terminated);
  pm_check_pending_processes(); // Check for pending signals arrived while we were in the signal handler

  pm_can_jump = 1;
  if (terminated) return -1;
  else return 0;
}

void pm_set_can_jump() {pm_can_jump = 1;}
void pm_set_can_not_jump() {pm_can_jump = 0;}

int setup_pm_pending_alarm()
{
  struct itimerval tval;
  struct timeval interval = {0, 20000};
  
  tval.it_interval = interval;
  tval.it_value = interval;
  setitimer(ITIMER_REAL, &tval, NULL);
  
  struct sigaction spending;
  spending.sa_handler = pm_gotsignal;
  sigemptyset(&spending.sa_mask);
  spending.sa_flags = 0;
  sigaction(SIGALRM, &spending, NULL);
  
  return 0;
}


int pm_check_pending_processes()
{
  int sig = 0;
  sigset_t sigset;
  setup_pm_pending_alarm();
  if ((sigemptyset(&sigset) == -1)
      || (sigaddset(&sigset, SIGALRM) == -1)
      || (sigaddset(&sigset, SIGINT) == -1)
      || (sigaddset(&sigset, SIGTERM) == -1)
      || (sigprocmask( SIG_BLOCK, &sigset, NULL) == -1)
     )
    perror("Failed to block signals before sigwait\n");
  
  if (sigpending(&sigset) == 0) {
    while (errno == EINTR)
      if (sigwait(&sigset, &sig) == -1) {
        perror("sigwait");
        return -1;
      }
    pm_gotsignal(sig);
  }
  return 0;
}


// Privates
int pm_malloc_and_set_attribute(char **ptr, char *value)
{
  char *obj = (char *) calloc (sizeof(char), strlen(value) + 1);
  
  if (!obj) {
    perror("pm_malloc_and_set_attribute");
    return -1;
  }
  strncpy(obj, value, strlen(value));
  obj[strlen(value)] = (char)'\0';
  *ptr = obj;
  return 0;
}
