// Mengenbegrenzung des Sync je Gerät und Person (zusätzlich zum Anfragelimit je IP): Token-Bucket im Arbeitsspeicher (ein Prozess).
// Ein Bucket füllt sich gleichmäßig auf und fasst höchstens `burst` Token; eine Anfrage kostet eine Einheit, jede Op eine weitere.
// Ist nicht genug übrig, wird die ganze Anfrage mit 429 und Retry-After abgewiesen (nichts wird halb verarbeitet).
// Die Tagesobergrenze je Gerät zählt dagegen applied_ops (überlebt einen Neustart, siehe routes/sync.ts).

export interface BucketSpec {
  /** Fassungsvermögen (mindestens so groß wie die größte einzelne Anfrage). */
  burst: number;
  /** Auffüllung je Minute. */
  perMinute: number;
}

interface Bucket {
  tokens: number;
  at: number;
}

export class TokenBuckets {
  private readonly buckets = new Map<string, Bucket>();

  constructor(
    private readonly spec: BucketSpec,
    private readonly now: () => number,
  ) {}

  private level(key: string): Bucket {
    const t = this.now();
    const b = this.buckets.get(key) ?? { tokens: this.spec.burst, at: t };
    const elapsed = Math.max(0, t - b.at);
    b.tokens = Math.min(this.spec.burst, b.tokens + (elapsed / 60_000) * this.spec.perMinute);
    b.at = t;
    this.buckets.set(key, b);
    return b;
  }

  /** Wartezeit in Sekunden, bis `cost` Token verfügbar sind (0: jetzt; Infinity: nie, weil größer als das Fassungsvermögen). */
  wait(key: string, cost: number): number {
    if (cost > this.spec.burst) return Number.POSITIVE_INFINITY;
    const b = this.level(key);
    if (b.tokens >= cost) return 0;
    return Math.ceil(((cost - b.tokens) / this.spec.perMinute) * 60);
  }

  /** Entnimmt `cost` Token (nur nach wait() === 0 aufrufen). */
  take(key: string, cost: number): void {
    const b = this.level(key);
    b.tokens = Math.max(0, b.tokens - cost);
    if (this.buckets.size > 5000) this.prune();
  }

  /** Entfernt volle (also ungenutzte) Buckets. */
  private prune(): void {
    for (const [key, b] of this.buckets) {
      if (b.tokens + ((this.now() - b.at) / 60_000) * this.spec.perMinute >= this.spec.burst) this.buckets.delete(key);
    }
  }

  get size(): number {
    return this.buckets.size;
  }
}

export interface SyncLimitConfig {
  syncOpsBurst: number;
  syncOpsPerMinute: number;
  syncReqBurst: number;
  syncReqPerMinute: number;
  syncOpsPerDay: number;
}

/** Faktor der Personen-Grenze gegenüber der Geräte-Grenze (eine Person hat mehrere Geräte). */
export const PERSON_FACTOR = 3;

/** Alle Buckets des Sync: Anfragen und Ops, je Gerät und je Person. */
export class SyncLimiter {
  private readonly reqDevice: TokenBuckets;
  private readonly reqPerson: TokenBuckets;
  private readonly opsDevice: TokenBuckets;
  private readonly opsPerson: TokenBuckets;

  constructor(cfg: SyncLimitConfig, now: () => number = Date.now) {
    this.reqDevice = new TokenBuckets({ burst: cfg.syncReqBurst, perMinute: cfg.syncReqPerMinute }, now);
    this.reqPerson = new TokenBuckets({ burst: cfg.syncReqBurst * PERSON_FACTOR, perMinute: cfg.syncReqPerMinute * PERSON_FACTOR }, now);
    this.opsDevice = new TokenBuckets({ burst: cfg.syncOpsBurst, perMinute: cfg.syncOpsPerMinute }, now);
    this.opsPerson = new TokenBuckets({ burst: cfg.syncOpsBurst * PERSON_FACTOR, perMinute: cfg.syncOpsPerMinute * PERSON_FACTOR }, now);
  }

  /** Prüft und verbraucht eine Anfrage mit `ops` Ops. Liefert die Wartezeit in Sekunden, wenn abgewiesen (sonst null). */
  check(deviceId: string, userId: string, ops: number): number | null {
    const waits = [this.reqDevice.wait(deviceId, 1), this.reqPerson.wait(userId, 1)];
    if (ops > 0) waits.push(this.opsDevice.wait(deviceId, ops), this.opsPerson.wait(userId, ops));
    const worst = Math.max(...waits);
    if (worst > 0) return Number.isFinite(worst) ? worst : 60;
    this.reqDevice.take(deviceId, 1);
    this.reqPerson.take(userId, 1);
    if (ops > 0) {
      this.opsDevice.take(deviceId, ops);
      this.opsPerson.take(userId, ops);
    }
    return null;
  }
}
