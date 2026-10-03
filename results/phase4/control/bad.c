#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <limits.h>
int main(int argc, char **argv) {
	char *leak = malloc(77); leak[0] = 1;            /* LeakSanitizer */
	int x = INT_MAX; x += argc;                      /* UBSan: signed overflow */
	char *p = malloc(8); p[8] = 1;                   /* ASan: heap-buffer-overflow */
	printf("%d %p\n", x, (void *)p);
	return 0;
}
