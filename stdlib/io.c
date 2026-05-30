/* Bux Standard Library - I/O functions */

#include <stdio.h>
#include <stdint.h>
#include <string.h>

/* PrintLine - print string with newline */
void Std_Io_PrintLine(const char* s) {
    if (s != NULL) {
        puts(s);
    } else {
        puts("");
    }
}

/* Print - print string without newline */
void Std_Io_Print(const char* s) {
    if (s != NULL) {
        printf("%s", s);
    }
}

/* PrintInt - print integer */
void Std_Io_PrintInt(int64_t n) {
    printf("%lld", (long long)n);
}

/* PrintFloat - print float */
void Std_Io_PrintFloat(double f) {
    printf("%g", f);
}

/* PrintBool - print boolean */
void Std_Io_PrintBool(int b) {
    printf("%s", b ? "true" : "false");
}

/* ReadLine - read line from stdin (simplified) */
const char* Std_Io_ReadLine(void) {
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
