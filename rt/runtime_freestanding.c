/* Bux Runtime — freestanding / bare-metal research spike (post-v1.0)
 *
 * Goal: link with `-ffreestanding -nostdlib` without pulling in a hosted libc.
 * This is **not** a full embedded platform kit (no Cortex-M startup, no
 * linker scripts, no UART drivers). It is a portable base for:
 *   - compile smoke under -ffreestanding
 *   - no-libc static link experiments (custom `_start`)
 *   - future board BSPs that replace the weak I/O hooks
 *
 * Select: BUX_RUNTIME=freestanding  (bootstrap + selfhost)
 *
 * Memory: fixed bump allocator over a static arena (default 256 KiB).
 * Override at compile time: -DBUX_FS_HEAP_BYTES=N
 *
 * I/O: weak stubs — default print is a no-op; panic spins. Host may override:
 *   void bux_fs_write(const char* s, unsigned n);
 *   void bux_fs_halt(int code);
 */

#if defined(__STDC_HOSTED__) && __STDC_HOSTED__ == 1 && !defined(BUX_FS_FORCE)
/* When accidentally compiled as hosted without -ffreestanding, still avoid
 * libc — we implement everything we need. */
#endif

/* ── Fixed-width types without stdint.h ────────────────────────────────── */
typedef signed char        bux_i8;
typedef unsigned char      bux_u8;
typedef short              bux_i16;
typedef unsigned short     bux_u16;
typedef int                bux_i32;
typedef unsigned int       bux_u32;
#if defined(__LP64__) || defined(_WIN64) || defined(__x86_64__) || defined(__aarch64__)
typedef long               bux_i64;
typedef unsigned long      bux_u64;
typedef unsigned long      bux_size;
#else
typedef long long          bux_i64;
typedef unsigned long long bux_u64;
typedef unsigned int       bux_size;
#endif
typedef bux_u8             bux_bool;
#ifndef NULL
#  define NULL ((void*)0)
#endif
#ifndef true
#  define true 1
#  define false 0
#endif

/* ── Heap ─────────────────────────────────────────────────────────────── */
#ifndef BUX_FS_HEAP_BYTES
#  define BUX_FS_HEAP_BYTES (256u * 1024u)
#endif

static unsigned char bux_fs_heap[BUX_FS_HEAP_BYTES];
static bux_size bux_fs_heap_off = 0;

/* Weak hooks — board / host may override */
__attribute__((weak)) void bux_fs_write(const char* s, unsigned n) {
    (void)s; (void)n;
}
__attribute__((weak)) void bux_fs_halt(int code) {
    (void)code;
    for (;;) { /* spin */ }
}

/* ── CLI args (empty under freestanding) ──────────────────────────────── */
int g_argc = 0;
char** g_argv = NULL;

int bux_argc(void) { return g_argc; }
char* bux_argv(int index) {
    (void)index;
    return (char*)"";
}

/* ── Memory ───────────────────────────────────────────────────────────── */
static void bux_fs_zero(void* p, bux_size n) {
    unsigned char* b = (unsigned char*)p;
    bux_size i;
    for (i = 0; i < n; i++) b[i] = 0;
}

void* bux_alloc(bux_size size) {
    /* 8-byte align */
    bux_size off = (bux_fs_heap_off + 7u) & ~(bux_size)7u;
    if (size == 0) size = 1;
    if (off + size > (bux_size)BUX_FS_HEAP_BYTES) {
        bux_fs_write("OOM\n", 4);
        bux_fs_halt(1);
        return NULL;
    }
    void* p = &bux_fs_heap[off];
    bux_fs_heap_off = off + size;
    bux_fs_zero(p, size);
    return p;
}

void* bux_realloc(void* ptr, bux_size size) {
    /* Bump allocator cannot free — allocate fresh + copy if needed */
    void* n = bux_alloc(size);
    if (ptr != NULL && n != NULL && size > 0) {
        unsigned char* d = (unsigned char*)n;
        unsigned char* s = (unsigned char*)ptr;
        bux_size i;
        /* unknown old size — best effort copy of `size` bytes */
        for (i = 0; i < size; i++) d[i] = s[i];
    }
    return n;
}

void bux_free(void* ptr) { (void)ptr; /* bump: no-op */ }

/* ── Basic I/O / panic ────────────────────────────────────────────────── */
void bux_print(const char* s) {
    if (!s) return;
    unsigned n = 0;
    while (s[n]) n++;
    bux_fs_write(s, n);
}
void bux_println(const char* s) {
    bux_print(s ? s : "");
    bux_fs_write("\n", 1);
}
void bux_print_int(bux_i64 n) {
    char buf[32];
    int i = 0;
    int neg = 0;
    if (n < 0) { neg = 1; n = -n; }
    if (n == 0) { buf[i++] = '0'; }
    else {
        while (n > 0 && i < 30) {
            buf[i++] = (char)('0' + (n % 10));
            n /= 10;
        }
    }
    if (neg) buf[i++] = '-';
    /* reverse */
    int a = 0, b = i - 1;
    while (a < b) {
        char t = buf[a]; buf[a] = buf[b]; buf[b] = t;
        a++; b--;
    }
    bux_fs_write(buf, (unsigned)i);
}
void bux_print_float(double f) {
    /* minimal: cast to int for freestanding */
    bux_print_int((bux_i64)f);
}
void bux_print_bool(bux_bool b) { bux_print(b ? "true" : "false"); }
void bux_print_char(char c) { bux_fs_write(&c, 1); }
void bux_panic(const char* msg) {
    bux_fs_write("PANIC: ", 7);
    if (msg) {
        unsigned n = 0;
        while (msg[n]) n++;
        bux_fs_write(msg, n);
    }
    bux_fs_write("\n", 1);
    bux_fs_halt(1);
}
void bux_exit(int code) { bux_fs_halt(code); }
void bux_assert(int cond, const char* file, int line, const char* expr) {
    (void)file; (void)line; (void)expr;
    if (!cond) bux_panic("assert failed");
}

/* ── Checked arithmetic ───────────────────────────────────────────────── */
bux_i64 bux_div_i64(bux_i64 a, bux_i64 b) {
    if (b == 0) bux_panic("division by zero");
    return a / b;
}
bux_i64 bux_mod_i64(bux_i64 a, bux_i64 b) {
    if (b == 0) bux_panic("modulo by zero");
    return a % b;
}
bux_i64 bux_add_i64_checked(bux_i64 a, bux_i64 b) { return a + b; }
bux_i64 bux_sub_i64_checked(bux_i64 a, bux_i64 b) { return a - b; }
bux_i64 bux_mul_i64_checked(bux_i64 a, bux_i64 b) { return a * b; }
bux_i64 bux_neg_i64_checked(bux_i64 a) { return -a; }

/* ── Strings (no libc) ────────────────────────────────────────────────── */
unsigned int bux_strlen(const char* s) {
    unsigned int n = 0;
    if (!s) return 0;
    while (s[n]) n++;
    return n;
}
int bux_strlen_c(const char* s) { return (int)bux_strlen(s); }
int bux_strcmp(const char* a, const char* b) {
    if (!a) a = "";
    if (!b) b = "";
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}
int bux_strncmp(const char* a, const char* b, unsigned int n) {
    if (!a) a = "";
    if (!b) b = "";
    unsigned int i;
    for (i = 0; i < n; i++) {
        if (a[i] != b[i] || a[i] == 0) return (unsigned char)a[i] - (unsigned char)b[i];
    }
    return 0;
}
char* bux_strcpy(char* dest, const char* src) {
    if (!dest) return NULL;
    if (!src) { dest[0] = 0; return dest; }
    char* d = dest;
    while ((*d++ = *src++)) {}
    return dest;
}
char* bux_strcat(char* dest, const char* src) {
    if (!dest) return NULL;
    if (!src) return dest;
    char* d = dest;
    while (*d) d++;
    while ((*d++ = *src++)) {}
    return dest;
}
char* bux_strncpy(char* dest, const char* src, unsigned int n) {
    if (!dest) return NULL;
    unsigned int i = 0;
    if (src) {
        for (; i < n && src[i]; i++) dest[i] = src[i];
    }
    for (; i < n; i++) dest[i] = 0;
    return dest;
}
double bux_str_to_float(const char* s) {
    (void)s;
    return 0.0;
}
bux_i64 bux_str_to_int(const char* s) {
    if (!s) return 0;
    bux_i64 v = 0;
    int neg = 0;
    if (*s == '-') { neg = 1; s++; }
    while (*s >= '0' && *s <= '9') {
        v = v * 10 + (*s - '0');
        s++;
    }
    return neg ? -v : v;
}
const char* bux_strstr(const char* haystack, const char* needle) {
    if (!haystack || !needle) return NULL;
    if (!*needle) return haystack;
    for (const char* h = haystack; *h; h++) {
        const char* a = h;
        const char* b = needle;
        while (*a && *b && *a == *b) { a++; b++; }
        if (!*b) return h;
    }
    return NULL;
}
unsigned int bux_str_offset(const char* pos, const char* base) {
    if (!pos || !base) return 0;
    return (unsigned int)(pos - base);
}
int bux_str_contains(const char* haystack, const char* needle) {
    return bux_strstr(haystack, needle) != NULL;
}
int bux_str_is_null(const char* s) { return s == NULL; }

char* bux_str_slice(const char* s, unsigned int start, unsigned int len) {
    if (!s) s = "";
    unsigned int sl = bux_strlen(s);
    if (start > sl) start = sl;
    if (start + len > sl) len = sl - start;
    char* out = (char*)bux_alloc(len + 1);
    unsigned int i;
    for (i = 0; i < len; i++) out[i] = s[start + i];
    out[len] = 0;
    return out;
}
static int is_ws(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}
char* bux_str_trim_left(const char* s) {
    if (!s) s = "";
    while (*s && is_ws(*s)) s++;
    return bux_str_slice(s, 0, bux_strlen(s));
}
char* bux_str_trim_right(const char* s) {
    if (!s) s = "";
    unsigned int n = bux_strlen(s);
    while (n > 0 && is_ws(s[n - 1])) n--;
    return bux_str_slice(s, 0, n);
}
char* bux_str_trim(const char* s) {
    char* a = bux_str_trim_left(s);
    return bux_str_trim_right(a);
}
char* bux_int_to_str(bux_i64 n) {
    char buf[32];
    int i = 0;
    int neg = 0;
    if (n < 0) { neg = 1; n = -n; }
    if (n == 0) buf[i++] = '0';
    else while (n > 0 && i < 30) { buf[i++] = (char)('0' + (n % 10)); n /= 10; }
    if (neg) buf[i++] = '-';
    int a = 0, b = i - 1;
    while (a < b) { char t = buf[a]; buf[a] = buf[b]; buf[b] = t; a++; b--; }
    buf[i] = 0;
    return bux_str_slice(buf, 0, (unsigned)i);
}
char* bux_float_to_string(double f) { return bux_int_to_str((bux_i64)f); }

unsigned int bux_str_split_count(const char* s, const char* delim) {
    (void)s; (void)delim;
    return 0;
}
char* bux_str_split_part(const char* s, const char* delim, unsigned int index) {
    (void)s; (void)delim; (void)index;
    return (char*)"";
}
char* bux_str_join2(const char* a, const char* b, const char* sep) {
    unsigned int na = bux_strlen(a), nb = bux_strlen(b), ns = bux_strlen(sep);
    char* out = (char*)bux_alloc(na + ns + nb + 1);
    unsigned int i = 0, j;
    for (j = 0; j < na; j++) out[i++] = a[j];
    for (j = 0; j < ns; j++) out[i++] = sep[j];
    for (j = 0; j < nb; j++) out[i++] = b[j];
    out[i] = 0;
    return out;
}
char* bux_str_format(const char* fmt, const char* a0, const char* a1, const char* a2, const char* a3) {
    (void)a1; (void)a2; (void)a3;
    /* minimal: return fmt or a0 */
    if (a0 && a0[0]) return bux_str_slice(a0, 0, bux_strlen(a0));
    if (fmt) return bux_str_slice(fmt, 0, bux_strlen(fmt));
    return (char*)"";
}
char* bux_escape_c_string(const char* s, int len) {
    (void)len;
    return s ? bux_str_slice(s, 0, bux_strlen(s)) : (char*)"";
}

/* StringBuilder stubs (shape-compatible enough for unused mono) */
typedef struct {
    char* data;
    unsigned int len;
    unsigned int cap;
} BuxStringBuilder;

void bux_sb_append(BuxStringBuilder* sb, const char* s) {
    (void)sb; (void)s;
}
void bux_sb_append_int(BuxStringBuilder* sb, bux_i64 n) { (void)sb; (void)n; }
void bux_sb_append_float(BuxStringBuilder* sb, double f) { (void)sb; (void)f; }
void bux_sb_append_char(BuxStringBuilder* sb, char c) { (void)sb; (void)c; }
const char* bux_sb_build(BuxStringBuilder* sb) { return sb && sb->data ? sb->data : ""; }
void bux_sb_free(BuxStringBuilder* sb) { (void)sb; }

/* ── FS / path / OS — unavailable ─────────────────────────────────────── */
char* bux_read_file(const char* path) { (void)path; return NULL; }
int bux_write_file(const char* path, const char* content) {
    (void)path; (void)content;
    return -1;
}
int bux_file_exists(const char* path) { (void)path; return 0; }
char* bux_path_join(const char* a, const char* b) {
    return bux_str_join2(a ? a : "", b ? b : "", "/");
}
char* bux_path_parent(const char* path) {
    (void)path;
    return (char*)".";
}
char* bux_path_ext(const char* path) {
    (void)path;
    return (char*)"";
}
int bux_mkdir_if_needed(const char* path) { (void)path; return -1; }
int bux_dir_exists(const char* path) { (void)path; return 0; }
char** bux_list_dir(const char* dir, const char* ext, int* out_count) {
    (void)dir; (void)ext;
    if (out_count) *out_count = 0;
    return NULL;
}

/* ── Math (integer only; float ops soft-stub) ─────────────────────────── */
double bux_sqrt(double x) { return x; }
double bux_pow(double x, double y) { (void)y; return x; }
bux_i64 bux_abs_i64(bux_i64 x) { return x < 0 ? -x : x; }
double bux_abs_f64(double x) { return x < 0 ? -x : x; }
bux_i64 bux_min_i64(bux_i64 a, bux_i64 b) { return a < b ? a : b; }
bux_i64 bux_max_i64(bux_i64 a, bux_i64 b) { return a > b ? a : b; }
double bux_min_f64(double a, double b) { return a < b ? a : b; }
double bux_max_f64(double a, double b) { return a > b ? a : b; }

unsigned int bux_hash_bytes(const void* ptr, bux_size size) {
    const unsigned char* p = (const unsigned char*)ptr;
    unsigned int h = 2166136261u;
    bux_size i;
    if (!p) return 0;
    for (i = 0; i < size; i++) {
        h ^= p[i];
        h *= 16777619u;
    }
    return h;
}
int bux_mem_eq(const void* a, const void* b, bux_size size) {
    const unsigned char* x = (const unsigned char*)a;
    const unsigned char* y = (const unsigned char*)b;
    bux_size i;
    if (!x || !y) return x == y;
    for (i = 0; i < size; i++) if (x[i] != y[i]) return 0;
    return 1;
}
unsigned int bux_hash_string(const char* s) {
    return bux_hash_bytes(s, bux_strlen(s));
}

const char* bux_getenv(const char* name) { (void)name; return ""; }
const char* bux_cc_ld_stable(void) { return ""; }
int bux_setenv(const char* name, const char* value) {
    (void)name; (void)value;
    return -1;
}
const char* bux_getcwd(void) { return "."; }
int bux_chdir(const char* path) { (void)path; return -1; }

void bux_install_stop_handlers(void) {}
int bux_should_stop(void) { return 0; }
void bux_set_stop_listen_fd(int fd) { (void)fd; }

bux_i64 bux_time_ms(void) { return 0; }
bux_i64 bux_time_us(void) { return 0; }

/* ── Task / net / crypto — hard stubs ─────────────────────────────────── */
int bux_task_spawn(void* fn, void* arg) { (void)fn; (void)arg; return -1; }
void bux_task_yield(void) {}
void bux_task_sleep_ms(int ms) { (void)ms; }

int bux_chan_new(int cap) { (void)cap; return -1; }
int bux_chan_send(int id, void* msg) { (void)id; (void)msg; return -1; }
void* bux_chan_recv(int id) { (void)id; return NULL; }
void bux_chan_close(int id) { (void)id; }

int bux_tcp_listen(int port) { (void)port; return -1; }
int bux_tcp_accept(int fd) { (void)fd; return -1; }
int bux_tcp_connect(const char* host, int port) {
    (void)host; (void)port;
    return -1;
}
int bux_tcp_send(int fd, const void* buf, int n) {
    (void)fd; (void)buf; (void)n;
    return -1;
}
int bux_tcp_recv(int fd, void* buf, int n) {
    (void)fd; (void)buf; (void)n;
    return -1;
}
void bux_tcp_close(int fd) { (void)fd; }

void* bux_tls_server_ctx(const char* cert, const char* key) {
    (void)cert; (void)key;
    return NULL;
}
void* bux_tls_server_ctx_ex(const char* cert, const char* key, const char* ca) {
    (void)cert; (void)key; (void)ca;
    return NULL;
}
int bux_tls_accept(void* ctx, int fd) { (void)ctx; (void)fd; return -1; }
int bux_tls_send(int h, const void* buf, int n) {
    (void)h; (void)buf; (void)n;
    return -1;
}
int bux_tls_recv(int h, void* buf, int n) {
    (void)h; (void)buf; (void)n;
    return -1;
}
void bux_tls_close(int h) { (void)h; }
const char* bux_tls_error(void) { return "tls unavailable (freestanding)"; }

/* ── Optional bare `_start` for -nostdlib link experiments ───────────── */
#ifdef BUX_FS_PROVIDE_START
extern int main(int argc, char** argv);
void _start(void) {
    g_argc = 0;
    g_argv = NULL;
    int code = main(0, NULL);
    bux_fs_halt(code);
}
#endif
