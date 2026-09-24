// Opt-in, local diagnostics. No source text is recorded or transmitted.
const samples = new Map();
export function measure(name, run) {
  if (!globalThis.__mdrProfile) return run();
  const start = performance.now();
  try { return run(); }
  finally {
    let values = samples.get(name);
    if (!values) samples.set(name, values = []);
    values.push(performance.now() - start);
    if (values.length > 1000) values.shift();
  }
}
export function performanceSnapshot(reset = false) {
  const result = Object.fromEntries([...samples].map(([name, values]) => {
    const sorted = [...values].sort((a,b) => a-b);
    return [name, {count: values.length, total: values.reduce((a,b) => a+b, 0),
      median: sorted[Math.floor(sorted.length / 2)], p95: sorted[Math.floor(sorted.length * .95)], max: sorted.at(-1)}];
  }));
  if (reset) samples.clear();
  return result;
}
