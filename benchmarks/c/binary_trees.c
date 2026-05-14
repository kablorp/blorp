/* The Computer Language Benchmarks Game
   https://benchmarksgame-team.pages.debian.net/benchmarksgame/
   contributed by Kevin Carson */
#include <stdio.h>
#include <stdlib.h>

typedef struct node {
    struct node *left, *right;
    long long value;
} Node;

static Node *make_with_value(int depth, long long value) {
    Node *n = malloc(sizeof(Node));
    if (depth == 0) {
        n->left = n->right = NULL;
        n->value = value;
    } else {
        long long next = value * 2;
        n->left = make_with_value(depth - 1, next);
        n->right = make_with_value(depth - 1, next + 1);
        n->value = 0;
    }
    return n;
}

static Node *make(int depth) {
    return make_with_value(depth, 1);
}

static long long check(Node *n) {
    if (!n->left) return n->value;
    return 1 + check(n->left) + check(n->right);
}

static void free_tree(Node *n) {
    if (n->left) { free_tree(n->left); free_tree(n->right); }
    free(n);
}

int main(int argc, char **argv) {
    int min_depth = 4;
    int n = argc > 1 ? atoi(argv[1]) : 10;
    int max_depth = n;
    if (min_depth + 2 > max_depth) max_depth = min_depth + 2;
    int stretch_depth = max_depth + 1;

    Node *stretch = make(stretch_depth);
    printf("stretch tree of depth %d\t check: %lld\n", stretch_depth, check(stretch));
    free_tree(stretch);

    Node *long_lived = make(max_depth);

    for (int d = min_depth; d <= max_depth; d += 2) {
        int iterations = 1 << (max_depth - d + min_depth);
        long long total = 0;
        for (int i = 0; i < iterations; i++) {
            Node *t = make(d);
            total += check(t);
            free_tree(t);
        }
        printf("%d\t trees of depth %d\t check: %lld\n", iterations, d, total);
    }

    printf("long lived tree of depth %d\t check: %lld\n", max_depth, check(long_lived));
    free_tree(long_lived);
    return 0;
}
