function run(conn: number) {
  return conn + 1;
}

class Store {
  conn: number;
  constructor(path: number) {
    this.conn = path * 2;
  }

  query() {
    return run(this.conn);
  }
}
