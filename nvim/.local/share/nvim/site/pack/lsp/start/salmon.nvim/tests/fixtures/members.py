import sqlite3


def run(conn):
    return conn.execute("select 1")


class Store:
    def __init__(self, path):
        self._conn = sqlite3.connect(path)

    def reset(self):
        self._conn = None

    def query(self):
        return run(self._conn)

    def raw(self):
        conn = self._conn
        return conn


store = Store("app.db")
store.query()
