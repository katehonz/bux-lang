/* Bux Runtime - Minimal C runtime for Bux programs */
/* This is linked with every Bux program compiled via the C backend */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

/* Command-line argument storage */
int g_argc = 0;
char** g_argv = NULL;

int bux_argc(void) { return g_argc; }
char* bux_argv(int index) {
    if (index < 0 || index >= g_argc) return "";
    return g_argv[index];
}

/* Memory allocation */
void* bux_alloc(size_t size) {
    void* ptr = malloc(size);
    if (ptr == NULL) {
        fprintf(stderr, "bux runtime: out of memory (alloc %zu bytes)\n", size);
        abort();
    }
    return ptr;
}

void* bux_realloc(void* ptr, size_t size) {
    void* new_ptr = realloc(ptr, size);
    if (new_ptr == NULL && size > 0) {
        fprintf(stderr, "bux runtime: out of memory (realloc %zu bytes)\n", size);
        abort();
    }
    return new_ptr;
}

void bux_free(void* ptr) {
    free(ptr);
}

/* I/O */
void bux_print(const char* s) {
    if (s != NULL) {
        fputs(s, stdout);
    }
}

void bux_println(const char* s) {
    if (s != NULL) {
        puts(s);
    } else {
        puts("");
    }
}

void bux_print_int(int64_t n) {
    printf("%lld", (long long)n);
}

void bux_print_float(double f) {
    printf("%g", f);
}

void bux_print_bool(bool b) {
    printf("%s", b ? "true" : "false");
}

void bux_print_char(char c) {
    putchar(c);
}

/* Panic */
void bux_panic(const char* msg) {
    fprintf(stderr, "bux panic: %s\n", msg ? msg : "unknown error");
    abort();
}

/* Division by zero check */
int64_t bux_div_i64(int64_t a, int64_t b) {
    if (b == 0) {
        bux_panic("division by zero");
    }
    return a / b;
}

int64_t bux_mod_i64(int64_t a, int64_t b) {
    if (b == 0) {
        bux_panic("modulo by zero");
    }
    return a % b;
}

/* String operations */
typedef struct {
    const char* data;
    size_t len;
} BuxString;

BuxString bux_string_from_cstr(const char* s) {
    BuxString result;
    result.data = s;
    result.len = s ? strlen(s) : 0;
    return result;
}

BuxString bux_string_concat(BuxString a, BuxString b) {
    BuxString result;
    result.len = a.len + b.len;
    char* buf = (char*)bux_alloc(result.len + 1);
    if (a.data && a.len > 0) memcpy(buf, a.data, a.len);
    if (b.data && b.len > 0) memcpy(buf + a.len, b.data, b.len);
    buf[result.len] = '\0';
    result.data = buf;
    return result;
}

/* Slice operations */
typedef struct {
    void* data;
    size_t len;
    size_t cap;
} BuxSlice;

BuxSlice bux_slice_new(size_t elem_size, size_t len) {
    BuxSlice result;
    result.len = len;
    result.cap = len;
    result.data = bux_alloc(elem_size * len);
    return result;
}

void bux_bounds_check(size_t index, size_t len) {
    if (index >= len) {
        fprintf(stderr, "bux panic: index out of bounds (index %zu, len %zu)\n", index, len);
        abort();
    }
}

/* String wrappers with Bux-compatible signatures */
unsigned int bux_strlen(const char* s) {
    return (unsigned int)strlen(s);
}

int bux_strcmp(const char* a, const char* b) {
    if (a == b) return 0;
    if (!a) return -1;
    if (!b) return 1;
    return strcmp(a, b);
}

int bux_strncmp(const char* a, const char* b, unsigned int n) {
    if (a == b) return 0;
    if (!a) return -1;
    if (!b) return 1;
    return strncmp(a, b, (size_t)n);
}

char* bux_strcpy(char* dest, const char* src) {
    if (!dest || !src) return dest;
    return strcpy(dest, src);
}

char* bux_strcat(char* dest, const char* src) {
    return strcat(dest, src);
}

char* bux_strncpy(char* dest, const char* src, unsigned int n) {
    return strncpy(dest, src, (size_t)n);
}

/* String find: returns pointer to first occurrence of needle in haystack, or NULL */
const char* bux_strstr(const char* haystack, const char* needle) {
    if (!haystack || !needle) return NULL;
    return strstr(haystack, needle);
}

/* String contains: returns 1 if haystack contains needle, 0 otherwise */
int bux_str_contains(const char* haystack, const char* needle) {
    return bux_strstr(haystack, needle) != NULL;
}

/* String slice: extract substring from start, length len */
char* bux_str_slice(const char* s, unsigned int start, unsigned int len) {
    if (!s) return NULL;
    unsigned int s_len = (unsigned int)strlen(s);
    if (start >= s_len) {
        char* empty = (char*)bux_alloc(1);
        empty[0] = '\0';
        return empty;
    }
    unsigned int avail = s_len - start;
    if (len > avail) len = avail;
    char* result = (char*)bux_alloc(len + 1);
    memcpy(result, s + start, len);
    result[len] = '\0';
    return result;
}

/* String trim left: remove leading whitespace */
char* bux_str_trim_left(const char* s) {
    if (!s) return NULL;
    while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r') s++;
    unsigned int len = (unsigned int)strlen(s);
    char* result = (char*)bux_alloc(len + 1);
    memcpy(result, s, len + 1);
    return result;
}

/* String trim right: remove trailing whitespace */
char* bux_str_trim_right(const char* s) {
    if (!s) return NULL;
    unsigned int len = (unsigned int)strlen(s);
    while (len > 0 && (s[len-1] == ' ' || s[len-1] == '\t' || s[len-1] == '\n' || s[len-1] == '\r')) {
        len--;
    }
    char* result = (char*)bux_alloc(len + 1);
    memcpy(result, s, len);
    result[len] = '\0';
    return result;
}

/* String trim: remove both leading and trailing whitespace */
char* bux_str_trim(const char* s) {
    char* left = bux_str_trim_left(s);
    char* result = bux_str_trim_right(left);
    bux_free(left);
    return result;
}

/* Int to string conversion */
char* bux_int_to_str(int64_t n) {
    char* result = (char*)bux_alloc(32);
    snprintf(result, 32, "%lld", (long long)n);
    return result;
}

/* String to int conversion */
int64_t bux_str_to_int(const char* s) {
    if (!s) return 0;
    return (int64_t)atoll(s);
}

/* String builder */
typedef struct {
    char* buf;
    unsigned int len;
    unsigned int cap;
} BuxStringBuilder;

BuxStringBuilder* bux_sb_new(unsigned int initial_cap) {
    BuxStringBuilder* sb = (BuxStringBuilder*)bux_alloc(sizeof(BuxStringBuilder));
    sb->cap = initial_cap > 0 ? initial_cap : 64;
    sb->buf = (char*)bux_alloc(sb->cap);
    sb->buf[0] = '\0';
    sb->len = 0;
    return sb;
}

void bux_sb_append(BuxStringBuilder* sb, const char* s) {
    if (!sb || !s) return;
    unsigned int s_len = (unsigned int)strlen(s);
    unsigned int new_len = sb->len + s_len;
    if (new_len + 1 > sb->cap) {
        while (sb->cap < new_len + 1) sb->cap *= 2;
        sb->buf = (char*)bux_realloc(sb->buf, sb->cap);
    }
    memcpy(sb->buf + sb->len, s, s_len);
    sb->len = new_len;
    sb->buf[sb->len] = '\0';
}

void bux_sb_append_int(BuxStringBuilder* sb, int64_t n) {
    char tmp[32];
    snprintf(tmp, sizeof(tmp), "%lld", (long long)n);
    bux_sb_append(sb, tmp);
}

void bux_sb_append_float(BuxStringBuilder* sb, double f) {
    char tmp[32];
    snprintf(tmp, sizeof(tmp), "%g", f);
    bux_sb_append(sb, tmp);
}

void bux_sb_append_char(BuxStringBuilder* sb, char c) {
    if (!sb) return;
    if (sb->len + 2 > sb->cap) {
        sb->cap *= 2;
        sb->buf = (char*)bux_realloc(sb->buf, sb->cap);
    }
    sb->buf[sb->len++] = c;
    sb->buf[sb->len] = '\0';
}

const char* bux_sb_build(BuxStringBuilder* sb) {
    if (!sb) return "";
    return sb->buf;
}

void bux_sb_free(BuxStringBuilder* sb) {
    if (!sb) return;
    bux_free(sb->buf);
    bux_free(sb);
}

/* String split: count parts separated by delimiter */
unsigned int bux_str_split_count(const char* s, const char* delim) {
    if (!s || !delim || !*delim) return 1;
    unsigned int count = 1;
    size_t delim_len = strlen(delim);
    const char* p = s;
    while ((p = strstr(p, delim)) != NULL) {
        count++;
        p += delim_len;
    }
    return count;
}

/* String split: get the n-th part (0-indexed) */
char* bux_str_split_part(const char* s, const char* delim, unsigned int index) {
    if (!s || !delim || !*delim) {
        if (index == 0) {
            unsigned int len = s ? (unsigned int)strlen(s) : 0;
            char* result = (char*)bux_alloc(len + 1);
            if (s) memcpy(result, s, len);
            result[len] = '\0';
            return result;
        }
        char* empty = (char*)bux_alloc(1);
        empty[0] = '\0';
        return empty;
    }
    size_t delim_len = strlen(delim);
    const char* start = s;
    const char* end;
    unsigned int current = 0;
    while (current < index) {
        end = strstr(start, delim);
        if (!end) {
            char* empty = (char*)bux_alloc(1);
            empty[0] = '\0';
            return empty;
        }
        start = end + delim_len;
        current++;
    }
    end = strstr(start, delim);
    size_t part_len;
    if (end) {
        part_len = (size_t)(end - start);
    } else {
        part_len = strlen(start);
    }
    char* result = (char*)bux_alloc(part_len + 1);
    memcpy(result, start, part_len);
    result[part_len] = '\0';
    return result;
}

/* String join: join two strings with separator */
char* bux_str_join2(const char* a, const char* b, const char* sep) {
    if (!a && !b) {
        char* empty = (char*)bux_alloc(1);
        empty[0] = '\0';
        return empty;
    }
    unsigned int len_a = a ? (unsigned int)strlen(a) : 0;
    unsigned int len_b = b ? (unsigned int)strlen(b) : 0;
    unsigned int len_sep = sep ? (unsigned int)strlen(sep) : 0;
    unsigned int total = len_a + len_sep + len_b;
    char* result = (char*)bux_alloc(total + 1);
    if (a) memcpy(result, a, len_a);
    if (sep && len_a > 0 && len_b > 0) memcpy(result + len_a, sep, len_sep);
    if (b) memcpy(result + len_a + (len_a > 0 && len_b > 0 ? len_sep : 0), b, len_b);
    result[total] = '\0';
    return result;
}

/* Simple string format: replace {0}, {1}, ... with string arguments.
   Returns formatted string. Supports up to 8 arguments. */
char* bux_str_format(const char* pattern,
    const char* a0, const char* a1, const char* a2, const char* a3,
    const char* a4, const char* a5, const char* a6, const char* a7) {
    if (!pattern) {
        char* empty = (char*)bux_alloc(1);
        empty[0] = '\0';
        return empty;
    }
    const char* args[8] = { a0, a1, a2, a3, a4, a5, a6, a7 };
    
    /* Calculate result size */
    size_t total = 0;
    const char* p = pattern;
    while (*p) {
        if (*p == '{' && p[1] >= '0' && p[1] <= '7' && p[2] == '}') {
            int idx = p[1] - '0';
            if (args[idx]) total += strlen(args[idx]);
            p += 3;
        } else {
            total++;
            p++;
        }
    }
    
    char* result = (char*)bux_alloc(total + 1);
    char* w = result;
    p = pattern;
    while (*p) {
        if (*p == '{' && p[1] >= '0' && p[1] <= '7' && p[2] == '}') {
            int idx = p[1] - '0';
            if (args[idx]) {
                size_t len = strlen(args[idx]);
                memcpy(w, args[idx], len);
                w += len;
            }
            p += 3;
        } else {
            *w++ = *p++;
        }
    }
    *w = '\0';
    return result;
}

/* File I/O — read entire file into string */
char* bux_read_file(const char* path) {
    if (!path) return NULL;
    FILE* f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    char* buf = (char*)bux_alloc((size_t)size + 1);
    size_t read = fread(buf, 1, (size_t)size, f);
    fclose(f);
    buf[read] = '\0';
    return buf;
}

/* File I/O — write string to file */
int bux_write_file(const char* path, const char* content) {
    if (!path || !content) return 0;
    FILE* f = fopen(path, "wb");
    if (!f) return 0;
    size_t len = strlen(content);
    size_t written = fwrite(content, 1, len, f);
    fclose(f);
    return written == len ? 1 : 0;
}

/* File I/O — check if file exists */
int bux_file_exists(const char* path) {
    if (!path) return 0;
    FILE* f = fopen(path, "rb");
    if (f) {
        fclose(f);
        return 1;
    }
    return 0;
}

/* Path operations */
char* bux_path_join(const char* a, const char* b) {
    if (!a && !b) {
        char* empty = (char*)bux_alloc(1);
        empty[0] = '\0';
        return empty;
    }
    if (!a) {
        unsigned int len = (unsigned int)strlen(b);
        char* result = (char*)bux_alloc(len + 1);
        memcpy(result, b, len + 1);
        return result;
    }
    if (!b) {
        unsigned int len = (unsigned int)strlen(a);
        char* result = (char*)bux_alloc(len + 1);
        memcpy(result, a, len + 1);
        return result;
    }
    unsigned int len_a = (unsigned int)strlen(a);
    unsigned int len_b = (unsigned int)strlen(b);
    int need_sep = (len_a > 0 && a[len_a-1] != '/') ? 1 : 0;
    unsigned int total = len_a + (need_sep ? 1 : 0) + len_b;
    char* result = (char*)bux_alloc(total + 1);
    memcpy(result, a, len_a);
    if (need_sep) result[len_a] = '/';
    memcpy(result + len_a + (need_sep ? 1 : 0), b, len_b);
    result[total] = '\0';
    return result;
}

char* bux_path_parent(const char* path) {
    if (!path) {
        char* empty = (char*)bux_alloc(1);
        empty[0] = '\0';
        return empty;
    }
    int len = (int)strlen(path);
    while (len > 0 && path[len-1] == '/') len--;
    while (len > 0 && path[len-1] != '/') len--;
    while (len > 0 && path[len-1] == '/') len--;
    if (len == 0) {
        char* dot = (char*)bux_alloc(2);
        dot[0] = '.';
        dot[1] = '\0';
        return dot;
    }
    char* result = (char*)bux_alloc((unsigned int)len + 1);
    memcpy(result, path, (unsigned int)len);
    result[len] = '\0';
    return result;
}

char* bux_path_ext(const char* path) {
    if (!path) {
        char* empty = (char*)bux_alloc(1);
        empty[0] = '\0';
        return empty;
    }
    const char* dot = strrchr(path, '.');
    if (!dot) {
        char* empty = (char*)bux_alloc(1);
        empty[0] = '\0';
        return empty;
    }
    const char* slash = strrchr(path, '/');
    if (slash && slash > dot) {
        char* empty = (char*)bux_alloc(1);
        empty[0] = '\0';
        return empty;
    }
    unsigned int len = (unsigned int)strlen(dot);
    char* result = (char*)bux_alloc(len + 1);
    memcpy(result, dot, len + 1);
    return result;
}

/* Math functions — wrap C math.h */
#include <math.h>

double bux_sqrt(double x) { return sqrt(x); }
double bux_pow(double x, double y) { return pow(x, y); }
int64_t bux_abs_i64(int64_t x) { return x < 0 ? -x : x; }
double bux_abs_f64(double x) { return x < 0 ? -x : x; }
int64_t bux_min_i64(int64_t a, int64_t b) { return a < b ? a : b; }
int64_t bux_max_i64(int64_t a, int64_t b) { return a > b ? a : b; }
double bux_min_f64(double a, double b) { return a < b ? a : b; }
double bux_max_f64(double a, double b) { return a > b ? a : b; }

/* Hash function (djb2) over raw bytes — for generic key types */
unsigned int bux_hash_bytes(const void* ptr, size_t size) {
    if (!ptr) return 0;
    unsigned int hash = 5381;
    const unsigned char* bytes = (const unsigned char*)ptr;
    for (size_t i = 0; i < size; i++) {
        hash = ((hash << 5) + hash) + bytes[i]; /* hash * 33 + byte */
    }
    return hash;
}

/* Byte equality check — for generic key comparison */
int bux_mem_eq(const void* a, const void* b, size_t size) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    return memcmp(a, b, size) == 0;
}

/* Hash function (djb2) for string keys */
unsigned int bux_hash_string(const char* s) {
    unsigned int hash = 5381;
    int c;
    while ((c = *s++)) {
        hash = ((hash << 5) + hash) + c; /* hash * 33 + c */
    }
    return hash;
}

/* ---------------------------------------------------------------------------
 * Directory listing and build tools (for self-hosting compiler)
 * --------------------------------------------------------------------------- */

#include <dirent.h>
#include <sys/stat.h>

/* bux_list_dir: returns array of file paths in dir matching ext suffix.
 * Result is malloc'd array of malloc'd strings. Caller must free.
 * Sets *out_count to number of files found. */
char** bux_list_dir(const char* dir, const char* ext, int* out_count) {
    DIR* d = opendir(dir);
    if (!d) { *out_count = 0; return NULL; }
    
    /* First pass: count matching files */
    int count = 0;
    size_t ext_len = strlen(ext);
    struct dirent* entry;
    while ((entry = readdir(d)) != NULL) {
        size_t name_len = strlen(entry->d_name);
        if (name_len > ext_len && strcmp(entry->d_name + name_len - ext_len, ext) == 0) {
            count++;
        }
    }
    
    /* Allocate result array */
    char** result = (char**)malloc(count * sizeof(char*));
    if (!result) { closedir(d); *out_count = 0; return NULL; }
    
    /* Second pass: collect paths */
    rewinddir(d);
    int idx = 0;
    size_t dir_len = strlen(dir);
    while ((entry = readdir(d)) != NULL && idx < count) {
        size_t name_len = strlen(entry->d_name);
        if (name_len > ext_len && strcmp(entry->d_name + name_len - ext_len, ext) == 0) {
            /* Build full path: dir/name */
            size_t path_len = dir_len + 1 + name_len + 1;
            char* path = (char*)malloc(path_len);
            if (path) {
                snprintf(path, path_len, "%s/%s", dir, entry->d_name);
                result[idx++] = path;
            }
        }
    }
    closedir(d);
    *out_count = idx;
    return result;
}

/* bux_mkdir_if_needed: create directory if it doesn't exist */
int bux_mkdir_if_needed(const char* path) {
    struct stat st;
    if (stat(path, &st) == 0 && S_ISDIR(st.st_mode)) return 0;
    return mkdir(path, 0755);
}

/* bux_run_cc: invoke C compiler to compile c_file into out_bin,
 * linking runtime.c and io.c. Returns exit code. */
int bux_run_cc(const char* c_file, const char* out_bin,
               const char* runtime_c, const char* io_c,
               const char* math_lib) {
    char cmd[4096];
    snprintf(cmd, sizeof(cmd),
        "cc %s %s %s -o %s %s 2>&1",
        c_file,
        runtime_c ? runtime_c : "",
        io_c ? io_c : "",
        out_bin,
        math_lib ? "-lm" : "");
    return system(cmd);
}

/* bux_dir_exists: check if directory exists */
int bux_dir_exists(const char* path) {
    struct stat st;
    return (stat(path, &st) == 0 && S_ISDIR(st.st_mode));
}
