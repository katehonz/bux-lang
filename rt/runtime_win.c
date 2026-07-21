/* Bux Runtime — Windows / MinGW minimal build (session 71)
 *
 * No pthread, ucontext, BSD sockets, or OpenSSL. Enough for hello and
 * basic single-threaded programs. Advanced features return failure / no-op.
 *
 * Linked with -ffunction-sections -fdata-sections -Wl,--gc-sections so
 * monomorphized stdlib in main.c that is never called is discarded.
 *
 * Unix full runtime remains rt/runtime.c (POSIX + OpenSSL).
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <errno.h>

#if defined(_WIN32) || defined(_WIN64)
#  include <windows.h>
#  include <direct.h>
#  include <io.h>
#  define BUX_IS_WIN 1
#  define bux_mkdir_one(p) _mkdir(p)
#else
#  include <unistd.h>
#  include <sys/stat.h>
#  define BUX_IS_WIN 0
#  define bux_mkdir_one(p) mkdir((p), 0755)
#endif

/* ── CLI args ─────────────────────────────────────────────────────────── */
int g_argc = 0;
char** g_argv = NULL;

int bux_argc(void) { return g_argc; }
char* bux_argv(int index) {
    if (index < 0 || index >= g_argc) return "";
    return g_argv[index];
}

/* ── Memory ───────────────────────────────────────────────────────────── */
void* bux_alloc(size_t size) {
    void* ptr = calloc(1, size);
    if (ptr == NULL && size > 0) {
        fprintf(stderr, "bux runtime: out of memory (alloc %zu)\n", size);
        abort();
    }
    return ptr;
}
void* bux_realloc(void* ptr, size_t size) {
    void* p = realloc(ptr, size);
    if (p == NULL && size > 0) {
        fprintf(stderr, "bux runtime: out of memory (realloc %zu)\n", size);
        abort();
    }
    return p;
}
void bux_free(void* ptr) { free(ptr); }

/* ── Basic I/O / panic ────────────────────────────────────────────────── */
void bux_print(const char* s) { if (s) fputs(s, stdout); fflush(stdout); }
void bux_println(const char* s) { if (s) puts(s); else puts(""); fflush(stdout); }
void bux_print_int(int64_t n) { printf("%lld", (long long)n); }
void bux_print_float(double f) { printf("%g", f); }
void bux_print_bool(bool b) { fputs(b ? "true" : "false", stdout); }
void bux_print_char(char c) { fputc(c, stdout); }
void bux_panic(const char* msg) {
    fprintf(stderr, "PANIC: %s\n", msg ? msg : "");
    abort();
}
void bux_exit(int code) { exit(code); }
void bux_assert(int cond, const char* file, int line, const char* expr) {
    if (!cond) {
        fprintf(stderr, "ASSERT FAILED: %s at %s:%d\n",
                expr ? expr : "?", file ? file : "?", line);
        exit(1);
    }
}

/* ── Checked arithmetic (same semantics as full runtime) ──────────────── */
int64_t bux_div_i64(int64_t a, int64_t b) {
    if (b == 0) bux_panic("division by zero");
    return a / b;
}
int64_t bux_mod_i64(int64_t a, int64_t b) {
    if (b == 0) bux_panic("modulo by zero");
    return a % b;
}
int64_t bux_add_i64_checked(int64_t a, int64_t b) { return a + b; }
int64_t bux_sub_i64_checked(int64_t a, int64_t b) { return a - b; }
int64_t bux_mul_i64_checked(int64_t a, int64_t b) { return a * b; }
int64_t bux_neg_i64_checked(int64_t a) { return -a; }

/* ── Strings ──────────────────────────────────────────────────────────── */
unsigned int bux_strlen(const char* s) { return s ? (unsigned int)strlen(s) : 0; }
int bux_strlen_c(const char* s) { return s ? (int)strlen(s) : 0; }
int bux_strcmp(const char* a, const char* b) {
    if (!a) a = ""; if (!b) b = "";
    return strcmp(a, b);
}
int bux_strncmp(const char* a, const char* b, unsigned int n) {
    if (!a) a = ""; if (!b) b = "";
    return strncmp(a, b, (size_t)n);
}
char* bux_strcpy(char* dest, const char* src) {
    if (!dest) return NULL;
    if (!src) { dest[0] = 0; return dest; }
    return strcpy(dest, src);
}
char* bux_strcat(char* dest, const char* src) {
    if (!dest) return NULL;
    if (!src) return dest;
    return strcat(dest, src);
}
char* bux_strncpy(char* dest, const char* src, unsigned int n) {
    if (!dest) return NULL;
    if (!src) { if (n) dest[0] = 0; return dest; }
    return strncpy(dest, src, (size_t)n);
}
double bux_str_to_float(const char* s) { return s ? atof(s) : 0.0; }
int64_t bux_str_to_int(const char* s) { return s ? (int64_t)atoll(s) : 0; }
const char* bux_strstr(const char* haystack, const char* needle) {
    if (!haystack || !needle) return NULL;
    return strstr(haystack, needle);
}
unsigned int bux_str_offset(const char* pos, const char* base) {
    if (!pos || !base) return 0;
    return (unsigned int)(pos - base);
}
int bux_str_contains(const char* haystack, const char* needle) {
    if (!haystack || !needle) return 0;
    return strstr(haystack, needle) != NULL;
}
int bux_str_is_null(const char* s) { return s == NULL; }

char* bux_str_slice(const char* s, unsigned int start, unsigned int len) {
    if (!s) s = "";
    unsigned int sl = (unsigned int)strlen(s);
    if (start > sl) start = sl;
    if (start + len > sl) len = sl - start;
    char* out = (char*)bux_alloc(len + 1);
    memcpy(out, s + start, len);
    out[len] = 0;
    return out;
}
static int is_ws(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}
char* bux_str_trim_left(const char* s) {
    if (!s) s = "";
    while (*s && is_ws(*s)) s++;
    unsigned int n = (unsigned int)strlen(s);
    char* out = (char*)bux_alloc(n + 1);
    memcpy(out, s, n + 1);
    return out;
}
char* bux_str_trim_right(const char* s) {
    if (!s) s = "";
    unsigned int n = (unsigned int)strlen(s);
    while (n > 0 && is_ws(s[n - 1])) n--;
    char* out = (char*)bux_alloc(n + 1);
    memcpy(out, s, n);
    out[n] = 0;
    return out;
}
char* bux_str_trim(const char* s) {
    char* a = bux_str_trim_left(s);
    char* b = bux_str_trim_right(a);
    bux_free(a);
    return b;
}
char* bux_int_to_str(int64_t n) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%lld", (long long)n);
    unsigned int len = (unsigned int)strlen(buf);
    char* out = (char*)bux_alloc(len + 1);
    memcpy(out, buf, len + 1);
    return out;
}
char* bux_float_to_string(double f) {
    char buf[64];
    snprintf(buf, sizeof(buf), "%g", f);
    unsigned int len = (unsigned int)strlen(buf);
    char* out = (char*)bux_alloc(len + 1);
    memcpy(out, buf, len + 1);
    return out;
}
unsigned int bux_str_split_count(const char* s, const char* delim) {
    if (!s || !delim || !delim[0]) return 0;
    unsigned int count = 1;
    const char* p = s;
    size_t dlen = strlen(delim);
    while ((p = strstr(p, delim)) != NULL) {
        count++;
        p += dlen;
    }
    return count;
}
char* bux_str_split_part(const char* s, const char* delim, unsigned int index) {
    if (!s || !delim) return (char*)bux_alloc(1);
    size_t dlen = strlen(delim);
    const char* start = s;
    unsigned int i = 0;
    while (i < index) {
        const char* p = strstr(start, delim);
        if (!p) return (char*)bux_alloc(1);
        start = p + dlen;
        i++;
    }
    const char* end = strstr(start, delim);
    size_t len = end ? (size_t)(end - start) : strlen(start);
    char* out = (char*)bux_alloc(len + 1);
    memcpy(out, start, len);
    out[len] = 0;
    return out;
}
char* bux_str_join2(const char* a, const char* b, const char* sep) {
    if (!a) a = ""; if (!b) b = ""; if (!sep) sep = "";
    size_t la = strlen(a), lb = strlen(b), ls = strlen(sep);
    char* out = (char*)bux_alloc(la + ls + lb + 1);
    memcpy(out, a, la);
    memcpy(out + la, sep, ls);
    memcpy(out + la + ls, b, lb + 1);
    return out;
}
char* bux_str_format(const char* fmt, const char* a0, const char* a1, const char* a2, const char* a3) {
    /* Minimal: return copy of fmt (full formatter is Unix runtime only) */
    (void)a0; (void)a1; (void)a2; (void)a3;
    if (!fmt) fmt = "";
    size_t n = strlen(fmt);
    char* out = (char*)bux_alloc(n + 1);
    memcpy(out, fmt, n + 1);
    return out;
}
char* bux_escape_c_string(const char* s, int len) {
    if (!s || len <= 0) {
        char* e = (char*)bux_alloc(1);
        e[0] = 0;
        return e;
    }
    char* buf = (char*)bux_alloc((size_t)len * 2 + 1);
    int j = 0;
    for (int i = 0; i < len; i++) {
        char c = s[i];
        switch (c) {
            case '\n': buf[j++] = '\\'; buf[j++] = 'n'; break;
            case '\r': buf[j++] = '\\'; buf[j++] = 'r'; break;
            case '\t': buf[j++] = '\\'; buf[j++] = 't'; break;
            case '\\': buf[j++] = '\\'; buf[j++] = '\\'; break;
            case '"':  buf[j++] = '\\'; buf[j++] = '"'; break;
            default:   buf[j++] = c; break;
        }
    }
    buf[j] = 0;
    return buf;
}

/* ── String builder ───────────────────────────────────────────────────── */
typedef struct {
    char* data;
    unsigned int len;
    unsigned int cap;
} BuxStringBuilder;

BuxStringBuilder* bux_sb_new(unsigned int initial_cap) {
    if (initial_cap < 16) initial_cap = 16;
    BuxStringBuilder* sb = (BuxStringBuilder*)bux_alloc(sizeof(BuxStringBuilder));
    sb->data = (char*)bux_alloc(initial_cap);
    sb->data[0] = 0;
    sb->len = 0;
    sb->cap = initial_cap;
    return sb;
}
static void sb_ensure(BuxStringBuilder* sb, unsigned int need) {
    if (sb->len + need + 1 <= sb->cap) return;
    unsigned int ncap = sb->cap * 2;
    while (ncap < sb->len + need + 1) ncap *= 2;
    sb->data = (char*)bux_realloc(sb->data, ncap);
    sb->cap = ncap;
}
void bux_sb_append(BuxStringBuilder* sb, const char* s) {
    if (!sb || !s) return;
    unsigned int n = (unsigned int)strlen(s);
    sb_ensure(sb, n);
    memcpy(sb->data + sb->len, s, n + 1);
    sb->len += n;
}
void bux_sb_append_int(BuxStringBuilder* sb, int64_t n) {
    char* t = bux_int_to_str(n);
    bux_sb_append(sb, t);
    bux_free(t);
}
void bux_sb_append_float(BuxStringBuilder* sb, double f) {
    char* t = bux_float_to_string(f);
    bux_sb_append(sb, t);
    bux_free(t);
}
void bux_sb_append_char(BuxStringBuilder* sb, char c) {
    if (!sb) return;
    sb_ensure(sb, 1);
    sb->data[sb->len++] = c;
    sb->data[sb->len] = 0;
}
const char* bux_sb_build(BuxStringBuilder* sb) { return sb ? sb->data : ""; }
void bux_sb_free(BuxStringBuilder* sb) {
    if (!sb) return;
    bux_free(sb->data);
    bux_free(sb);
}

/* ── Files / paths ────────────────────────────────────────────────────── */
char* bux_read_file(const char* path) {
    if (!path) return NULL;
    FILE* f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0) { fclose(f); return NULL; }
    char* buf = (char*)bux_alloc((size_t)sz + 1);
    size_t n = fread(buf, 1, (size_t)sz, f);
    buf[n] = 0;
    fclose(f);
    return buf;
}
int bux_write_file(const char* path, const char* content) {
    if (!path) return 0;
    FILE* f = fopen(path, "wb");
    if (!f) return 0;
    if (content) fputs(content, f);
    fclose(f);
    return 1;
}
int bux_file_exists(const char* path) {
    if (!path) return 0;
    FILE* f = fopen(path, "rb");
    if (!f) return 0;
    fclose(f);
    return 1;
}
char* bux_path_join(const char* a, const char* b) {
    if (!a && !b) { char* e = (char*)bux_alloc(1); e[0]=0; return e; }
    if (!a) {
        size_t n = strlen(b);
        char* r = (char*)bux_alloc(n + 1);
        memcpy(r, b, n + 1);
        return r;
    }
    if (!b) {
        size_t n = strlen(a);
        char* r = (char*)bux_alloc(n + 1);
        memcpy(r, a, n + 1);
        return r;
    }
    size_t la = strlen(a), lb = strlen(b);
    int need = (la > 0 && a[la-1] != '/' && a[la-1] != '\\') ? 1 : 0;
    char* r = (char*)bux_alloc(la + need + lb + 1);
    memcpy(r, a, la);
    if (need) r[la] = '/';
    memcpy(r + la + need, b, lb + 1);
    return r;
}
char* bux_path_parent(const char* path) {
    if (!path) { char* e = (char*)bux_alloc(1); e[0]=0; return e; }
    int len = (int)strlen(path);
    while (len > 0 && (path[len-1] == '/' || path[len-1] == '\\')) len--;
    while (len > 0 && path[len-1] != '/' && path[len-1] != '\\') len--;
    while (len > 0 && (path[len-1] == '/' || path[len-1] == '\\')) len--;
    if (len == 0) {
        char* d = (char*)bux_alloc(2);
        d[0] = '.'; d[1] = 0;
        return d;
    }
    char* r = (char*)bux_alloc((size_t)len + 1);
    memcpy(r, path, (size_t)len);
    r[len] = 0;
    return r;
}
char* bux_path_ext(const char* path) {
    if (!path) { char* e = (char*)bux_alloc(1); e[0]=0; return e; }
    const char* dot = strrchr(path, '.');
    if (!dot) { char* e = (char*)bux_alloc(1); e[0]=0; return e; }
    const char* slash = strrchr(path, '/');
    const char* bslash = strrchr(path, '\\');
    if (slash && slash > dot) { char* e = (char*)bux_alloc(1); e[0]=0; return e; }
    if (bslash && bslash > dot) { char* e = (char*)bux_alloc(1); e[0]=0; return e; }
    size_t n = strlen(dot);
    char* r = (char*)bux_alloc(n + 1);
    memcpy(r, dot, n + 1);
    return r;
}
int bux_mkdir_if_needed(const char* path) {
    if (!path) return -1;
    return bux_mkdir_one(path);
}
int bux_dir_exists(const char* path) {
    if (!path) return 0;
#if BUX_IS_WIN
    DWORD attr = GetFileAttributesA(path);
    return (attr != INVALID_FILE_ATTRIBUTES) && (attr & FILE_ATTRIBUTE_DIRECTORY);
#else
    struct stat st;
    return (stat(path, &st) == 0 && S_ISDIR(st.st_mode));
#endif
}
char** bux_list_dir(const char* dir, const char* ext, int* out_count) {
    (void)dir; (void)ext;
    if (out_count) *out_count = 0;
    return NULL; /* stub: recursive listing not ported */
}

/* ── Math / hash ──────────────────────────────────────────────────────── */
double bux_sqrt(double x) { return sqrt(x); }
double bux_pow(double x, double y) { return pow(x, y); }
int64_t bux_abs_i64(int64_t x) { return x < 0 ? -x : x; }
double bux_abs_f64(double x) { return x < 0 ? -x : x; }
int64_t bux_min_i64(int64_t a, int64_t b) { return a < b ? a : b; }
int64_t bux_max_i64(int64_t a, int64_t b) { return a > b ? a : b; }
double bux_min_f64(double a, double b) { return a < b ? a : b; }
double bux_max_f64(double a, double b) { return a > b ? a : b; }
unsigned int bux_hash_bytes(const void* ptr, size_t size) {
    if (!ptr) return 0;
    unsigned int hash = 5381;
    const unsigned char* b = (const unsigned char*)ptr;
    for (size_t i = 0; i < size; i++) hash = ((hash << 5) + hash) + b[i];
    return hash;
}
int bux_mem_eq(const void* a, const void* b, size_t size) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    return memcmp(a, b, size) == 0;
}
unsigned int bux_hash_string(const char* s) {
    return bux_hash_bytes(s, s ? strlen(s) : 0);
}

/* ── OS env / cwd ─────────────────────────────────────────────────────── */
const char* bux_getenv(const char* name) {
    if (!name) return "";
    const char* v = getenv(name);
    return v ? v : "";
}
const char* bux_cc_ld_stable(void) { return ""; }
int bux_setenv(const char* name, const char* value) {
    if (!name || !value) return -1;
#if BUX_IS_WIN
    return _putenv_s(name, value) == 0 ? 0 : -1;
#else
    return setenv(name, value, 1);
#endif
}
const char* bux_getcwd(void) {
    static char buf[4096];
#if BUX_IS_WIN
    if (_getcwd(buf, (int)sizeof(buf))) return buf;
#else
    if (getcwd(buf, sizeof(buf))) return buf;
#endif
    return "";
}
int bux_chdir(const char* path) {
    if (!path) return -1;
#if BUX_IS_WIN
    return _chdir(path);
#else
    return chdir(path);
#endif
}

/* ── Time ─────────────────────────────────────────────────────────────── */
int64_t bux_time_ms(void) {
#if BUX_IS_WIN
    FILETIME ft;
    GetSystemTimeAsFileTime(&ft);
    ULARGE_INTEGER u;
    u.LowPart = ft.dwLowDateTime;
    u.HighPart = ft.dwHighDateTime;
    /* 100-ns intervals since 1601 → ms since Unix epoch */
    return (int64_t)((u.QuadPart / 10000ULL) - 11644473600000ULL);
#else
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) == 0)
        return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
    return (int64_t)time(NULL) * 1000;
#endif
}
int64_t bux_time_us(void) { return bux_time_ms() * 1000; }
void bux_sleep_ms(int64_t ms) {
    if (ms <= 0) return;
#if BUX_IS_WIN
    Sleep((DWORD)ms);
#else
    struct timespec ts;
    ts.tv_sec = (time_t)(ms / 1000);
    ts.tv_nsec = (long)((ms % 1000) * 1000000);
    nanosleep(&ts, NULL);
#endif
}

/* ── Process ──────────────────────────────────────────────────────────── */
int bux_system(const char* cmd) { return cmd ? system(cmd) : -1; }
int bux_run_nim(const char* nim_file, const char* out_bin) {
    char cmd[4096];
    snprintf(cmd, sizeof(cmd), "nim c -o:%s -d:release --gc:orc %s 2>&1",
             out_bin ? out_bin : "a.out", nim_file ? nim_file : "");
    return system(cmd);
}
int bux_process_run(const char* cmd) { return bux_system(cmd); }
char* bux_process_output(const char* cmd) {
    (void)cmd;
    return NULL; /* popen portability varies; stub on minimal runtime */
}

/* ── Tasks / channels / mutex / async — stubs ─────────────────────────── */
void bux_task_init(int num_workers) { (void)num_workers; }
void bux_task_shutdown(void) {}
void* bux_task_spawn(void* (*func)(void*), void* arg) {
    (void)func; (void)arg;
    return NULL;
}
void bux_task_join(void* handle) { (void)handle; }
void bux_task_sleep(int64_t ms) { bux_sleep_ms(ms); }
void bux_task_yield(void) {}
int bux_task_current_id(void) { return 0; }

void* bux_channel_new(int64_t capacity, int64_t elem_size) {
    (void)capacity; (void)elem_size;
    return NULL;
}
void bux_channel_send(void* handle, void* elem) { (void)handle; (void)elem; }
int bux_channel_recv(void* handle, void* out) { (void)handle; (void)out; return 0; }
void bux_channel_close(void* handle) { (void)handle; }
void bux_channel_free(void* handle) { (void)handle; }

void* bux_mutex_new(void) { return bux_alloc(1); }
void bux_mutex_lock(void* handle) { (void)handle; }
void bux_mutex_unlock(void* handle) { (void)handle; }
void bux_mutex_free(void* handle) { bux_free(handle); }
void* bux_rwlock_new(void) { return bux_alloc(1); }
void bux_rwlock_rdlock(void* handle) { (void)handle; }
void bux_rwlock_wrlock(void* handle) { (void)handle; }
void bux_rwlock_unlock(void* handle) { (void)handle; }
void bux_rwlock_free(void* handle) { bux_free(handle); }

void* bux_async_spawn(void (*func)(void)) { (void)func; return NULL; }
void bux_async_yield(void) {}
void bux_async_run(void) {}
void* bux_async_await(void* handle) { (void)handle; return NULL; }
void bux_async_sleep(int64_t ms) { bux_sleep_ms(ms); }
void bux_async_return(void* value, size_t size) { (void)value; (void)size; }
void* bux_async_result(void* handle) { (void)handle; return NULL; }

/* ── Sockets — stubs ──────────────────────────────────────────────────── */
int bux_socket_create(void) { return -1; }
int bux_socket_reuse(int fd) { (void)fd; return -1; }
int bux_socket_bind(int fd, const char* addr, int port) {
    (void)fd; (void)addr; (void)port; return -1;
}
int bux_socket_listen(int fd, int backlog) { (void)fd; (void)backlog; return -1; }
int bux_socket_accept(int fd) { (void)fd; return -1; }
int bux_socket_connect(int fd, const char* addr, int port) {
    (void)fd; (void)addr; (void)port; return -1;
}
int bux_socket_send(int fd, const char* data, int len) {
    (void)fd; (void)data; (void)len; return -1;
}
/* BuxString used by full runtime; provide a simple struct-compatible layout */
typedef struct { char* data; int len; } BuxString;
BuxString bux_socket_recv(int fd, int max_len) {
    (void)fd; (void)max_len;
    BuxString s; s.data = NULL; s.len = 0; return s;
}
int bux_socket_close(int fd) { (void)fd; return -1; }
const char* bux_socket_error(void) { return "sockets not available on this platform"; }

/* ── Crypto — stubs (no OpenSSL) ──────────────────────────────────────── */
static void zero_out(unsigned char* out, int n) {
    if (out && n > 0) memset(out, 0, (size_t)n);
}
void bux_sha1(const char* data, int len, unsigned char* out) {
    (void)data; (void)len; zero_out(out, 20);
}
void bux_sha256(const char* data, int len, unsigned char* out) {
    (void)data; (void)len; zero_out(out, 32);
}
void bux_sha384(const char* data, int len, unsigned char* out) {
    (void)data; (void)len; zero_out(out, 48);
}
void bux_sha512(const char* data, int len, unsigned char* out) {
    (void)data; (void)len; zero_out(out, 64);
}
void bux_hmac_sha256(const char* key, int keylen, const char* msg, int msglen, unsigned char* out) {
    (void)key; (void)keylen; (void)msg; (void)msglen; zero_out(out, 32);
}
void bux_hmac_sha384(const char* key, int keylen, const char* msg, int msglen, unsigned char* out) {
    (void)key; (void)keylen; (void)msg; (void)msglen; zero_out(out, 48);
}
void bux_hmac_sha512(const char* key, int keylen, const char* msg, int msglen, unsigned char* out) {
    (void)key; (void)keylen; (void)msg; (void)msglen; zero_out(out, 64);
}
int bux_random_bytes(unsigned char* buf, int len) {
    if (!buf || len <= 0) return 0;
#if BUX_IS_WIN
    /* Best-effort: not cryptographically strong */
    for (int i = 0; i < len; i++) buf[i] = (unsigned char)(rand() & 0xFF);
    return 1;
#else
    for (int i = 0; i < len; i++) buf[i] = (unsigned char)(rand() & 0xFF);
    return 1;
#endif
}
char* bux_base64_encode(const unsigned char* in, int inlen) {
    (void)in; (void)inlen;
    char* o = (char*)bux_alloc(1); o[0] = 0; return o;
}
char* bux_base64_decode(const char* in, int inlen, int* outlen) {
    (void)in; (void)inlen;
    if (outlen) *outlen = 0;
    return (char*)bux_alloc(1);
}
char* bux_base64url_encode(const unsigned char* in, int inlen) {
    return bux_base64_encode(in, inlen);
}
char* bux_base64url_decode(const char* in, int inlen, int* outlen) {
    return bux_base64_decode(in, inlen, outlen);
}
char* bux_bytes_to_hex(const unsigned char* data, int len) {
    if (!data || len <= 0) { char* e = (char*)bux_alloc(1); e[0]=0; return e; }
    char* out = (char*)bux_alloc((size_t)len * 2 + 1);
    static const char* hex = "0123456789abcdef";
    for (int i = 0; i < len; i++) {
        out[i*2] = hex[(data[i] >> 4) & 0xF];
        out[i*2+1] = hex[data[i] & 0xF];
    }
    out[len*2] = 0;
    return out;
}
int bux_aes_256_cbc_encrypt(const unsigned char* key, const unsigned char* iv,
                            const char* in, int inlen, unsigned char* out, int* outlen) {
    (void)key; (void)iv; (void)in; (void)inlen; (void)out;
    if (outlen) *outlen = 0;
    return 0;
}
int bux_aes_256_cbc_decrypt(const unsigned char* key, const unsigned char* iv,
                            const char* in, int inlen, unsigned char* out, int* outlen) {
    (void)key; (void)iv; (void)in; (void)inlen; (void)out;
    if (outlen) *outlen = 0;
    return 0;
}
int bux_aes_256_gcm_encrypt(const unsigned char* key, const unsigned char* iv, int ivlen,
                            const char* in, int inlen, unsigned char* out, int* outlen,
                            unsigned char* tag) {
    (void)key; (void)iv; (void)ivlen; (void)in; (void)inlen; (void)out; (void)tag;
    if (outlen) *outlen = 0;
    return 0;
}
int bux_aes_256_gcm_decrypt(const unsigned char* key, const unsigned char* iv, int ivlen,
                            const char* in, int inlen, const unsigned char* tag,
                            unsigned char* out, int* outlen) {
    (void)key; (void)iv; (void)ivlen; (void)in; (void)inlen; (void)tag; (void)out;
    if (outlen) *outlen = 0;
    return 0;
}
char* bux_rsa_sign_sha256(const char* pem, int keylen, const char* data, int datalen, int* siglen) {
    (void)pem; (void)keylen; (void)data; (void)datalen;
    if (siglen) *siglen = 0; return NULL;
}
char* bux_rsa_sign_sha384(const char* pem, int keylen, const char* data, int datalen, int* siglen) {
    (void)pem; (void)keylen; (void)data; (void)datalen;
    if (siglen) *siglen = 0; return NULL;
}
char* bux_rsa_sign_sha512(const char* pem, int keylen, const char* data, int datalen, int* siglen) {
    (void)pem; (void)keylen; (void)data; (void)datalen;
    if (siglen) *siglen = 0; return NULL;
}
int bux_rsa_verify_sha256(const char* pem, int keylen, const char* data, int datalen,
                          const char* sig, int siglen) {
    (void)pem; (void)keylen; (void)data; (void)datalen; (void)sig; (void)siglen;
    return 0;
}
int bux_rsa_verify_sha384(const char* pem, int keylen, const char* data, int datalen,
                          const char* sig, int siglen) {
    (void)pem; (void)keylen; (void)data; (void)datalen; (void)sig; (void)siglen;
    return 0;
}
int bux_rsa_verify_sha512(const char* pem, int keylen, const char* data, int datalen,
                          const char* sig, int siglen) {
    (void)pem; (void)keylen; (void)data; (void)datalen; (void)sig; (void)siglen;
    return 0;
}
char* bux_ecdsa_sign_p256(const char* pem, int keylen, const char* data, int datalen, int* siglen) {
    (void)pem; (void)keylen; (void)data; (void)datalen;
    if (siglen) *siglen = 0; return NULL;
}
char* bux_ecdsa_sign_p384(const char* pem, int keylen, const char* data, int datalen, int* siglen) {
    (void)pem; (void)keylen; (void)data; (void)datalen;
    if (siglen) *siglen = 0; return NULL;
}
int bux_ecdsa_verify_p256(const char* pem, int keylen, const char* data, int datalen,
                          const char* sig, int siglen) {
    (void)pem; (void)keylen; (void)data; (void)datalen; (void)sig; (void)siglen;
    return 0;
}
int bux_ecdsa_verify_p384(const char* pem, int keylen, const char* data, int datalen,
                          const char* sig, int siglen) {
    (void)pem; (void)keylen; (void)data; (void)datalen; (void)sig; (void)siglen;
    return 0;
}
int bux_ed25519_keypair(unsigned char* pub, unsigned char* priv) {
    zero_out(pub, 32); zero_out(priv, 32); return 0;
}
int bux_ed25519_sign(const char* priv, const char* data, int datalen, unsigned char* sig) {
    (void)priv; (void)data; (void)datalen; zero_out(sig, 64); return 0;
}
int bux_ed25519_verify(const char* pub, const char* sig, const char* data, int datalen) {
    (void)pub; (void)sig; (void)data; (void)datalen; return 0;
}

/* Legacy string helpers used by some mono paths */
typedef struct { char* data; int len; } BuxStringLegacy;
BuxStringLegacy bux_string_from_cstr(const char* s) {
    BuxStringLegacy r;
    r.data = (char*)(s ? s : "");
    r.len = s ? (int)strlen(s) : 0;
    return r;
}
BuxStringLegacy bux_string_concat(BuxStringLegacy a, BuxStringLegacy b) {
    (void)a; (void)b;
    BuxStringLegacy r; r.data = ""; r.len = 0; return r;
}
