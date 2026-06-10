# Bux Green Threads / Task Scheduler — Design Document

> **Date:** 2026-06-10
> **Status:** Design Approved
> **Scope:** MVP preemptive M:N green thread scheduler with work-stealing

---

## 1. Overview

Bux will gain Go-style green threads (M:N scheduling) without garbage collection. A fixed pool of OS worker threads runs a larger number of lightweight "green" tasks, preemptively scheduled via `SIGVTALRM` and context switching via `ucontext`.

### Goals
- Enable concurrent programming in Bux with Go-like ergonomics
- Zero GC pauses (Bux is manually managed)
- Work-stealing for balanced CPU utilization across cores
- Minimal language changes (pure stdlib + C runtime addition)

### Non-Goals (for MVP)
- Cross-platform support beyond Linux/macOS (ucontext is POSIX)
- Dynamic stack growth (fixed-size stacks)
- I/O polling integration (epoll/kqueue) — channels + sleep only
- Task cancellation / timeouts

---

## 2. Architecture

```
┌─────────────────────────────────────────┐
│         Bux Source Code (.bux)          │
│  func Main() { Task::Spawn(Worker); }   │
└─────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────┐
│     Bux Stdlib — `lib/Task.bux`         │
│  extern func bux_task_spawn(...);       │
│  func Task::Spawn(f) { ... }            │
└─────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────┐
│     Generated C Code (from buxc)        │
│  bux_task_spawn(worker_func, arg);      │
└─────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────┐
│     C Runtime — `rt/green_threads.c`    │
│  • Scheduler (M:N, work-stealing)       │
│  • ucontext context switch              │
│  • SIGVTALRM preemption                 │
│  • Per-OS-thread run queues             │
└─────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────┐
│     OS Threads (pthread)                │
│  Worker 0 │ Worker 1 │ Worker 2 │ ...   │
│  ┌─────┐  │  ┌─────┐  │  ┌─────┐       │
│  │TaskA│  │  │TaskB│  │  │TaskC│       │
│  │TaskD│  │  │     │  │  │TaskE│       │
│  └─────┘  │  └─────┘  │  └─────┘       │
└─────────────────────────────────────────┘
```

### Components

1. **Bux API Layer** (`lib/Task.bux`) — thin wrappers around C extern functions
2. **C Scheduler Runtime** (`rt/green_threads.c`) — the scheduler, context switcher, and signal handler
3. **OS Worker Threads** — pthreads, each executing green threads from its local queue

### Data Flow
- `Task::Spawn(func, arg)` → `bux_task_spawn(func, arg)` → creates Task + ucontext → added to run queue
- `SIGVTALRM` fires → current task pauses → scheduler picks next task → `swapcontext`
- `Channel_Recv` on empty channel → task marked BLOCKED → yields → scheduler runs another task

---

## 3. Data Structures

### Task

```c
typedef enum {
    TASK_READY,
    TASK_RUNNING,
    TASK_BLOCKED,
    TASK_FINISHED,
} TaskState;

typedef struct Task {
    ucontext_t ctx;           /* ucontext for context switch */
    void *stack;              /* malloc'd stack */
    size_t stack_size;        /* e.g., 256KB */
    
    void (*func)(void*);      /* Entry function */
    void *arg;                /* Argument */
    
    TaskState state;
    int id;                   /* Unique task ID */
    struct Task *next;        /* Linked list for queues */
    
    /* Blocking state */
    void *waiting_on;         /* Channel handle, if blocked on recv */
    int64_t wake_at;          /* Timestamp (ms) for sleep wake-up */
} Task;
```

### Per-Worker Scheduler

```c
typedef struct Scheduler {
    Task *run_queue_head;     /* Ready tasks (LIFO: push/pop head) */
    Task *run_queue_tail;
    int queue_count;
    
    Task *current;            /* Currently running task */
    pthread_t os_thread;      /* OS thread handle */
    int worker_id;            /* 0 .. N-1 */
    
    struct Scheduler **all_schedulers; /* For work-stealing */
    int num_workers;
} Scheduler;
```

### Global State

```c
typedef struct TaskPool {
    Scheduler **schedulers;   /* One per worker thread */
    int num_workers;          /* Default = CPU core count */
    pthread_mutex_t spawn_lock;
    int next_task_id;
    int shutdown;             /* Set to 1 for graceful shutdown */
} TaskPool;
```

**Key Decisions:**
- Linked list queues — simple, coarse-grained lock for MVP (lock-free atomic ops later)
- Fixed 256KB stacks — sufficient for most code, guard page for overflow detection
- Task ID returned by `Task::Spawn`, consumed by `Task::Wait`

---

## 4. Bux API

```bux
module Std::Task {

extern func bux_task_init(num_workers: int) -> int;
extern func bux_task_spawn(func: *void, arg: *void) -> int;
extern func bux_task_wait(task_id: int);
extern func bux_task_sleep(ms: int64);
extern func bux_task_yield();
extern func bux_task_current_id() -> int;
extern func bux_task_shutdown();

struct TaskHandle {
    id: int;
}

func Task_Spawn(func: *void, arg: *void) -> TaskHandle {
    let id: int = bux_task_spawn(func, arg);
    return TaskHandle { id: id };
}

func Task_Wait(handle: TaskHandle) {
    bux_task_wait(handle.id);
}

func Task_Sleep(ms: int64) {
    bux_task_sleep(ms);
}

func Task_Yield() {
    bux_task_yield();
}

func Task_CurrentId() -> int {
    return bux_task_current_id();
}

func Task_Init(num_workers: int) -> int {
    return bux_task_init(num_workers);
}

func Task_Shutdown() {
    bux_task_shutdown();
}

}
```

### Usage Example

```bux
import Std::Task;
import Std::Channel;

func Worker(id: int) {
    PrintLine("Worker " + Int_ToString(id) + " starting");
    Task_Sleep(100);
    PrintLine("Worker " + Int_ToString(id) + " done");
}

func Main() -> int {
    Task_Init(4);
    
    let h1: TaskHandle = Task_Spawn(Worker as *void, 1 as *void);
    let h2: TaskHandle = Task_Spawn(Worker as *void, 2 as *void);
    
    Task_Wait(h1);
    Task_Wait(h2);
    
    Task_Shutdown();
    return 0;
}
```

**Notes:**
- `func` parameter is `*void` because the C runtime does not know Bux types
- Users cast their function to `*void` (like a C function pointer)
- `Task_Init` is optional — the first `Task_Spawn` auto-initializes with CPU core count workers

---

## 5. Scheduler Algorithm

### Preemption

- `SIGVTALRM` timer set to 10ms interval via `setitimer(ITIMER_VIRTUAL, ...)`
- Signal handler calls `schedule()` — saves current context, selects next task
- Fixed 10ms quantum for MVP (configurable later)

### Work-Stealing

Each OS thread (worker):
1. Checks its own `run_queue` (LIFO — push/pop from head for cache locality)
2. If empty: attempts to "steal" from a random other worker (FIFO from tail)
3. If all queues empty: sleeps on a condition variable
4. When a new task is spawned: signals the condition variable to wake a sleeper

### Task Selection (per worker)

```
schedule():
  1. If current task is RUNNING → mark as READY, push to queue
  2. Check sleep queue — any wake_time expired?
  3. Check blocked tasks — any channel now has data?
  4. Pop READY task from queue (round-robin within queue)
  5. Mark as RUNNING
  6. swapcontext() to new task
```

### Graceful Shutdown

- `Task_Shutdown()` sets `shutdown = 1`
- Workers exit their loop when no more tasks exist
- Main thread waits for all workers with `pthread_join`

---

## 6. Context Switching

```c
#include <ucontext.h>
#include <signal.h>

static void timer_handler(int sig) {
    (void)sig;
    schedule();
}

void scheduler_init(void) {
    struct sigaction sa;
    sa.sa_handler = timer_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    sigaction(SIGVTALRM, &sa, NULL);
    
    struct itimerval itv;
    itv.it_interval.tv_sec = 0;
    itv.it_interval.tv_usec = 10000;  /* 10ms */
    itv.it_value = itv.it_interval;
    setitimer(ITIMER_VIRTUAL, &itv, NULL);
}

void task_switch(Task *from, Task *to) {
    from->state = TASK_READY;
    to->state = TASK_RUNNING;
    current_task = to;
    swapcontext(&from->ctx, &to->ctx);
}
```

### Task Creation

```c
Task* task_create(void (*func)(void*), void *arg) {
    Task *t = calloc(1, sizeof(Task));
    t->stack = malloc(STACK_SIZE);
    t->stack_size = STACK_SIZE;
    t->func = func;
    t->arg = arg;
    t->state = TASK_READY;
    
    getcontext(&t->ctx);
    t->ctx.uc_stack.ss_sp = t->stack;
    t->ctx.uc_stack.ss_size = t->stack_size;
    t->ctx.uc_link = &scheduler_context;
    
    /* makecontext only accepts int arguments; use thread-local to pass pointers */
    bux_task_creating = t;
    makecontext(&t->ctx, task_entry_wrapper, 0);
    bux_task_creating = NULL;
    
    return t;
}
```

---

## 7. Stack Management

- **Size:** 256KB default, configurable via `Task_Init`
- **Allocation:** `malloc()` + guard page (`mprotect(..., PROT_NONE)`) for overflow detection
- **Entry wrapper:** `task_entry_wrapper` calls `func(arg)`, then marks task as FINISHED and returns to scheduler

```c
/* Thread-local pointer to the task being created (for makecontext wrapper) */
static __thread Task *bux_task_creating;

static void task_entry_wrapper(void) {
    Task *t = bux_task_creating;
    t->func(t->arg);
    t->state = TASK_FINISHED;
    schedule();  /* Never returns */
}
```

**Cleanup:** `Task_Wait()` frees the stack and Task struct when the task completes.

---

## 8. Integration with Bux Build System

The C runtime file `rt/green_threads.c` is compiled and linked alongside `rt/runtime.c` and `rt/io.c`:

```
bux build:
  1. Merge all .bux → single .bux
  2. Compile .bux → .c (buxc)
  3. Compile generated .c + rt/*.c → binary (gcc/clang)
```

No compiler changes are required. The scheduler is purely a runtime addition.

---

## 9. Error Handling & Edge Cases

| Scenario | Handling |
|----------|----------|
| `Task_Spawn` when scheduler not initialized | Auto-initialize with CPU core count |
| Stack overflow | Guard page triggers SIGSEGV (MVP: abort; future: recoverable) |
| `Task_Wait` on non-existent ID | No-op / warning (task already finished) |
| All workers blocked | Main thread busy-waits or sleeps (MVP: simple spin) |
| `Task_Shutdown` with running tasks | Wait for all tasks to finish, then join workers |

---

## 10. Testing Strategy

1. **Unit tests (C level):** Test queue operations, task creation, context switch in isolation
2. **Integration tests (Bux):**
   - Spawn 2 tasks, wait for both
   - Spawn N tasks, verify they all run
   - Channel send/recv between concurrent tasks
   - Sleep test — verify other tasks run while one sleeps
3. **Stress test:** Spawn 1000+ tasks, verify no crashes or memory leaks
4. **Selfhost loop:** Verify the scheduler does not break compiler determinism

---

## 11. Future Work (Post-MVP)

- **Cross-platform context switching:** Replace ucontext with `setjmp` + manual stack switch for Windows
- **Dynamic stack growth:** Detect near-overflow and realloc stack
- **I/O integration:** Hook `read`/`write` to yield on blocking I/O
- **Work-stealing lock-free queues:** Replace coarse locks with atomic operations
- **Task cancellation / timeouts:** `Task_Cancel(handle)`, `Task_Wait(handle, timeout_ms)`
- `go` keyword as syntactic sugar for `Task::Spawn`
