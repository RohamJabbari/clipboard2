/** Per-key token buckets, in memory. With max 3 instances the effective limit is at most 3× the configured rate. */
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
