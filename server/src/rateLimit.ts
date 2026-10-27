/** At most `max` tasks at once (scrypt, which would otherwise fill the libuv pool), `queue` more waiting, the rest refused. */
export class Semaphore {
  private active = 0;
  private readonly waiting: (() => void)[] = [];

  constructor(
    private readonly max: number,
    private readonly queue: number,
  ) {}

  /** Runs `fn` when a slot is free; null when the queue is full as well. */
  run<T>(fn: () => Promise<T>): Promise<T> | null {
    if (this.active < this.max) {
      this.active++;
      return this.finish(fn);
    }
    if (this.waiting.length >= this.queue) return null;
    return new Promise<void>((resolve) => this.waiting.push(resolve)).then(() => this.finish(fn));
  }

  private async finish<T>(fn: () => Promise<T>): Promise<T> {
    try {
      return await fn();
    } finally {
      // Hand the slot straight to the next waiter, or give it back.
      const next = this.waiting.shift();
      if (next) next();
      else this.active--;
    }
  }
}

/** Per-key token buckets, in memory. With max 3 instances the effective limit is at most 3× the configured rate. Auth limits live in Postgres instead (app.ts). */
export class RateLimiter {
  private readonly buckets = new Map<string, { tokens: number; at: number }>();

  constructor(private readonly perMinute: number) {}

  /** Returns 0 when allowed, otherwise the seconds to wait. */
  take(key: string, now = Date.now()): number {
    const rate = this.perMinute / 60_000;
    const bucket = this.buckets.get(key) ?? { tokens: this.perMinute, at: now };
    bucket.tokens = Math.min(this.perMinute, bucket.tokens + (now - bucket.at) * rate);
    bucket.at = now;
    if (bucket.tokens < 1) {
      this.buckets.set(key, bucket);
      return Math.ceil((1 - bucket.tokens) / rate / 1000);
    }
    bucket.tokens -= 1;
    this.buckets.set(key, bucket);
    if (this.buckets.size > 10_000) this.sweep(now);
    return 0;
  }

  private sweep(now: number) {
    for (const [key, bucket] of this.buckets) {
      if (now - bucket.at > 120_000) this.buckets.delete(key);
    }
  }
}
