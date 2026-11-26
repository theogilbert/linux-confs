import pandas as pd


def load(path, mapping, extra):
    df = pd.read_csv(path)
    df = df.dropna()
    df = df.rename(columns=mapping)
    df["total"] = df.a + df.b
    if extra:
        df = pd.concat([df, extra])
    items = []
    items.append(len(df))
    items.extend(extra)
    print(df, items)
    count = 0
    count += 1
    print(count)
