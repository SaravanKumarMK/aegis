import { apiBaseUrl, getAuthToken, notifyUnauthorized } from '@/lib/api';
import { backoffMs, type SseFrame, type StreamStatus } from './sse';

/**
 * Replayable polling: the transport for deployments whose gateway buffers
 * responses (an API Gateway HTTP API cannot stream) and whose compute exists
 * only while a request is in flight.
 *
 * It keeps the stream client's contract - authenticated with the `Authorization`
 * header, resumed from a monotonic event id so nothing is missed or repeated,
 * frames delivered in order - and adds what a poller owes the bill: it slows
 * down while nothing changes, stops while the tab is hidden, and honours the
 * server's `Retry-After` when the database is waking, so an idle page cannot keep
 * a scale-to-zero backend awake.
 */

export const POLL_MIN_MS = 2_000;
export const POLL_MAX_MS = 30_000;
const RETRY_AFTER_CAP_MS = 60_000;

/** Whether this build was configured for polling instead of a streaming connection. */
export const pollingEnabled = (): boolean => process.env.NEXT_PUBLIC_EVENT_TRANSPORT === 'poll';

/** Next delay: back to the floor on activity, otherwise grow 1.5x to the ceiling. */
export function nextPollDelay(current: number, gotEvents: boolean): number {
  if (gotEvents) return POLL_MIN_MS;
  return Math.min(POLL_MAX_MS, Math.round(current * 1.5));
}

export interface PollPage {
  frames: SseFrame[];
  /** Highest event id in the page; the next request resumes after it. */
  last: number;
  /** More events are waiting, so poll again immediately. */
  hasMore: boolean;
}

export interface PollOptions {
  path: (after: number) => string;
  parse: (body: unknown) => PollPage;
  onFrame: (frame: SseFrame) => void;
  onStatus: (status: StreamStatus, detail?: string) => void;
  after?: number;
}

/** Incident events: `{events:[{id,type,data}], last_event_id, has_more}`. */
export function parseIncidentPage(body: unknown): PollPage {
  const page = body as {
    events?: { id: number; type: string; data: unknown }[];
    last_event_id?: number;
    has_more?: boolean;
  };
  const events = page.events ?? [];
  return {
    frames: events.map((e) => ({ id: String(e.id), event: e.type, data: JSON.stringify(e.data) })),
    last: page.last_event_id ?? events.at(-1)?.id ?? 0,
    hasMore: Boolean(page.has_more),
  };
}

/** War-room horizon events: `{events:[{seq,event}]}`, delivered as `horizon` frames. */
export function parseWarRoomPage(body: unknown): PollPage {
  const events = (body as { events?: { seq: number; event: unknown }[] }).events ?? [];
  return {
    frames: events.map((e) => ({
      id: String(e.seq),
      event: 'horizon',
      data: JSON.stringify({ seq: e.seq, event: e.event }),
    })),
    last: events.at(-1)?.seq ?? 0,
    hasMore: events.length >= 500,
  };
}

const retryAfterMs = (response: Response): number | null => {
  const seconds = Number(response.headers.get('Retry-After'));
  return Number.isFinite(seconds) && seconds > 0
    ? Math.min(RETRY_AFTER_CAP_MS, seconds * 1_000)
    : null;
};

/** Start polling. Returns a function that stops it for good. */
export function openPoll(options: PollOptions): () => void {
  let after = options.after ?? 0;
  let delay = POLL_MIN_MS;
  let failures = 0;
  let closed = false;
  let suspended = false;
  let timer: ReturnType<typeof setTimeout> | null = null;
  let controller: AbortController | null = null;

  const hidden = () => typeof document !== 'undefined' && document.visibilityState === 'hidden';

  const schedule = (ms: number) => {
    if (closed) return;
    timer = setTimeout(() => void tick(), ms);
  };

  const tick = async () => {
    if (closed) return;
    if (hidden()) {
      // No request while nobody is looking; resume on the next visibility change.
      suspended = true;
      return;
    }
    controller = new AbortController();
    const headers = new Headers({ Accept: 'application/json' });
    const token = getAuthToken();
    if (token) headers.set('Authorization', `Bearer ${token}`);
    if (after > 0) headers.set('Last-Event-ID', String(after));
    try {
      const response = await fetch(`${apiBaseUrl()}${options.path(after)}`, {
        headers,
        signal: controller.signal,
        cache: 'no-store',
      });
      if (response.status === 401) {
        closed = true;
        notifyUnauthorized();
        options.onStatus('offline', 'Session expired - sign in again.');
        return;
      }
      if (!response.ok) {
        failures += 1;
        const waiting = response.status === 503 ? retryAfterMs(response) : null;
        options.onStatus('reconnecting', `Updates answered ${response.status}.`);
        schedule(waiting ?? backoffMs(failures - 1));
        return;
      }
      const page = options.parse(await response.json());
      failures = 0;
      options.onStatus('live');
      for (const frame of page.frames) options.onFrame(frame);
      if (page.last > after) after = page.last;
      delay = nextPollDelay(delay, page.frames.length > 0);
      schedule(page.hasMore ? 0 : delay);
    } catch (_err) {
      if (closed) return;
      failures += 1;
      options.onStatus('reconnecting', 'Aegis is unreachable.');
      schedule(backoffMs(failures - 1));
    }
  };

  const onVisibility = () => {
    if (closed || !suspended || hidden()) return;
    suspended = false;
    delay = POLL_MIN_MS;
    void tick();
  };
  if (typeof document !== 'undefined') document.addEventListener('visibilitychange', onVisibility);

  options.onStatus('connecting');
  void tick();

  return () => {
    closed = true;
    if (timer) clearTimeout(timer);
    controller?.abort();
    if (typeof document !== 'undefined')
      document.removeEventListener('visibilitychange', onVisibility);
  };
}
