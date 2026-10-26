// Kleiner Festfenster-Zähler mit fester Obergrenze für die Zahl der Schlüssel (Speicher wächst nie mit fremden Eingaben).
// Schlüssel sind nur normalisierte Netzadressen oder Token-IDs aus der Datenbank, nie ein Eingabetoken.

export class BoundedLimiter {
  private readonly map = new Map<string, { count: number; resetAt: number }>();

  constructor(
    private readonly max: number,
    private readonly windowMs: number,
    private readonly now: () => Date,
    private readonly maxKeys = 10_000,
  ) {}

  /** Nur lesen: ist der Schlüssel im laufenden Fenster schon über der Grenze? */
  blocked(key: string): boolean {
    const e = this.map.get(key);
    return e !== undefined && e.resetAt > this.now().getTime() && e.count >= this.max;
  }

  /** Zählt einen Treffer; `true`, solange die Grenze nicht überschritten ist. */
  hit(key: string): boolean {
    const t = this.now().getTime();
    let e = this.map.get(key);
    if (!e || e.resetAt <= t) {
      if (!e && this.map.size >= this.maxKeys) this.makeRoom(t);
      this.map.delete(key);
      e = { count: 0, resetAt: t + this.windowMs };
      this.map.set(key, e);
    }
    e.count += 1;
    return e.count <= this.max;
  }

  get size(): number {
    return this.map.size;
  }

  private makeRoom(t: number): void {
    for (const [k, v] of this.map) if (v.resetAt <= t) this.map.delete(k);
    // noch voll: ältesten Eintrag verdrängen (Einfügereihenfolge)
    while (this.map.size >= this.maxKeys) {
      const first = this.map.keys().next();
      if (first.done) break;
      this.map.delete(first.value);
    }
  }
}
