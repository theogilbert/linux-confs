from helpers import scale


def compute(a, b):
    total = a + b
    return scale(total, 2)


def run(flag):
    base = 10
    if flag:
        base = 20
    offset = base
    result = compute(offset, b=5)
    print(result)
    for item in [result, base]:
        print(item)
    count = 0
    count += offset
    print(count)


run(True)
