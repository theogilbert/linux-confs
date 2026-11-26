def inner(value):
    print(value)
    return value


def outer():
    amount = 3
    print(amount)
    inner(amount)
    return amount
