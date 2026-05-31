/* Bux Runtime - Minimal C runtime for Bux programs */
/* This is linked with every Bux program compiled via the C backend */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

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
    return strcmp(a, b);
}

int bux_strncmp(const char* a, const char* b, unsigned int n) {
    return strncmp(a, b, (size_t)n);
}

char* bux_strcpy(char* dest, const char* src) {
    return strcpy(dest, src);
}

char* bux_strcat(char* dest, const char* src) {
    return strcat(dest, src);
}

char* bux_strncpy(char* dest, const char* src, unsigned int n) {
    return strncpy(dest, src, (size_t)n);
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
