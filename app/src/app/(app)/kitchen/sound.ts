/**
 * The "new ticket" sound on the kitchen screen: two rising tones, played twice,
 * made in the browser (no audio file to download).
 *
 * Browsers only let a page make sound after someone taps it, so the sound is
 * switched on with a button, and `unlockSound()` must be called from that tap.
 * The choice is remembered on this device; after the page is reloaded the next
 * tap anywhere on the kitchen screen switches the sound back on.
 */

const KEY = "sna.kitchen.sound.v1";

/** Did someone choose "sound on" on this device? */
export function readSoundWanted(): boolean {
  try {
    return localStorage.getItem(KEY) === "on";
  } catch {
    return false;
  }
}

export function saveSoundWanted(on: boolean) {
  try {
    localStorage.setItem(KEY, on ? "on" : "off");
  } catch {
    /* private window or storage switched off: the choice lasts until the page closes */
  }
}

// One player for the whole app, so it stays switched on when the cook opens
// another screen and comes back.
let ctx: AudioContext | null = null;
const watchers = new Set<() => void>();

function audioContextClass(): typeof AudioContext | null {
  if (typeof window === "undefined") return null;
  const w = window as unknown as { AudioContext?: typeof AudioContext; webkitAudioContext?: typeof AudioContext };
  return w.AudioContext ?? w.webkitAudioContext ?? null;
}

/** Can this browser make the sound at all? */
export function soundSupported(): boolean {
  return audioContextClass() !== null;
}

/** True while the browser will really play the sound. */
export function soundReady(): boolean {
  return ctx !== null && ctx.state === "running";
}

/** Calls `fn` whenever the browser starts or stops allowing the sound. Returns the function that stops watching. */
export function watchSound(fn: () => void): () => void {
  watchers.add(fn);
  return () => {
    watchers.delete(fn);
  };
}

/**
 * Switches the sound on. Call this ONLY from a tap or key press — anywhere else
 * the browser refuses. Returns false when this browser cannot play sound.
 */
export function unlockSound(): boolean {
  try {
    if (!ctx) {
      const Ctor = audioContextClass();
      if (!Ctor) return false;
      const made = new Ctor();
      made.onstatechange = () => watchers.forEach((fn) => fn());
      ctx = made;
    }
    if (ctx.state !== "running") {
      ctx.resume().then(
        () => watchers.forEach((fn) => fn()),
        () => {},
      );
    }
    return true;
  } catch {
    return false;
  }
}

/** One tone with a soft start and end (no click), starting `at` seconds on the player's clock. */
function tone(c: AudioContext, hz: number, at: number, seconds: number) {
  const osc = c.createOscillator();
  const gain = c.createGain();
  // A square wave cuts through kitchen noise far better than a soft sine.
  osc.type = "square";
  osc.frequency.setValueAtTime(hz, at);
  gain.gain.setValueAtTime(0.0001, at);
  gain.gain.exponentialRampToValueAtTime(0.4, at + 0.015);
  gain.gain.setValueAtTime(0.4, at + seconds - 0.04);
  gain.gain.exponentialRampToValueAtTime(0.0001, at + seconds);
  osc.connect(gain);
  gain.connect(c.destination);
  osc.start(at);
  osc.stop(at + seconds + 0.02);
  osc.onended = () => {
    osc.disconnect();
    gain.disconnect();
  };
}

/**
 * Plays the new-ticket sound (under a second). Does nothing, and returns false,
 * when the sound has not been switched on with a tap on this page.
 */
export function playNewTicketSound(): boolean {
  const c = ctx;
  if (!c) return false;
  try {
    // A tablet that slept may have paused the player; this is allowed once it was unlocked by a tap.
    if (c.state !== "running") c.resume().catch(() => {});
    const t = c.currentTime + 0.03;
    tone(c, 988, t, 0.16);
    tone(c, 1319, t + 0.18, 0.2);
    tone(c, 988, t + 0.48, 0.16);
    tone(c, 1319, t + 0.66, 0.2);
    return true;
  } catch {
    return false;
  }
}
