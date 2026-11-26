function double(n: number): number {
  const out = n * 2;
  return out;
}

let seed = 1;
if (Math.random() > 0.5) {
  seed = 3;
}
const alias = seed;
const r = double(alias);
console.log(r);
