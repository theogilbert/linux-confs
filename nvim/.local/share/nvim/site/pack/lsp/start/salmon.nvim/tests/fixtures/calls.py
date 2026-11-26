def work(v):
    return v


work(1)


def near():
    work(2)


CAP = 10


def clip(v, cap=CAP):
    return cap


clip(1)
clip(1, cap=5)
