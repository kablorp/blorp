import sys

class Tree:
    __slots__ = ("value", "left", "right")

    def __init__(self, value=0, left=None, right=None):
        self.value = value
        self.left = left
        self.right = right

def make(depth, value=1):
    if depth == 0:
        return Tree(value)
    depth -= 1
    next_value = value * 2
    return Tree(0, make(depth, next_value), make(depth, next_value + 1))

def check(node):
    if node.left is None:
        return node.value
    return 1 + check(node.left) + check(node.right)

def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 15
    min_depth = 4
    max_depth = max(min_depth + 2, n)

    stretch_depth = max_depth + 1
    stretch_tree = make(stretch_depth)
    print("stretch tree of depth %d\t check: %d" % (stretch_depth, check(stretch_tree)))
    del stretch_tree

    long_lived_tree = make(max_depth)

    for depth in range(min_depth, max_depth + 1, 2):
        iterations = 1 << (max_depth - depth + min_depth)
        cs = 0
        for _ in range(iterations):
            cs += check(make(depth))
        print("%d\t trees of depth %d\t check: %d" % (iterations, depth, cs))

    print("long lived tree of depth %d\t check: %d" % (max_depth, check(long_lived_tree)))

if __name__ == "__main__":
    main()
