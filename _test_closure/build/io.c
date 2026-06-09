/* Bux Standard Library - I/O functions */

#include <stdio.h>
#include <stdint.h>
#include <string.h>

/* PrintLine - print string with newline */
void PrintLine(const char* s) {
    if (s != NULL) {
        puts(s);
    } else {
        puts("");
    }
}

/* Print - print string without newline */
void Print(const char* s) {
    if (s != NULL) {
        printf("%s", s);
    }
}

/* PrintInt - print integer */
void PrintInt(int n) {
    printf("%d", n);
}

/* PrintInt64 - print 64-bit integer */
void PrintInt64(int64_t n) {
    printf("%lld", (long long)n);
}

/* PrintFloat - print float */
void PrintFloat(double f) {
    printf("%g", f);
}

/* PrintBool - print boolean */
void PrintBool(int b) {
    printf("%s", b ? "true" : "false");
}

/* ReadLine - read line from stdin (simplified) */
const char* ReadLine(void) {
    static char buffer[1024];
    if (fgets(buffer, sizeof(buffer), stdin) != NULL) {
        size_t len = strlen(buffer);
        if (len > 0 && buffer[len-1] == '\n') {
            buffer[len-1] = '\0';
        }
        return buffer;
    }
    return "";
}
