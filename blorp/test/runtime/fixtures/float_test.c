#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

#include "float_runtime.c"

int main(int argument_count, char **arguments) {
    assert(argument_count == 3);
    const double first = strtod(arguments[1], NULL);
    const double second = strtod(arguments[2], NULL);
    const double product = blorp_float_multiply(first, second);
    const double result = blorp_float_subtract(product, 1.0);
    printf("%a\n", result);
    return 0;
}
