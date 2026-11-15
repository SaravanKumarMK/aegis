import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const notifyUnauthorized = vi.fn();
vi.mock('@/lib/api', () => ({
  apiBaseUrl: () => 'https://api.test',
  getAuthToken: () => 'token-123',
  notifyUnauthorized: () => notifyUnauthorized(),
}));

import {
  POLL_MAX_MS,
  POLL_MIN_MS,
  nextPollDelay,
  openPoll,
  parseIncidentPage,
  parseWarRoomPage,
} from '@/lib/war-room/poll';

const page = (events: { id: number; type: string; data: unknown }[], hasMore = false) => ({
  events,
  last_event_id: events.at(-1)?.id ?? 0,
  has_more: hasMore,
});

const respond = (body: unknown, init: ResponseInit = { status: 200 }) =>
  Promise.resolve(new Response(JSON.stringify(body), init));

describe('poll cadence', () => {
  it('returns to the floor on activity and backs off to a ceiling while idle', () => {
    expect(nextPollDelay(20_000, true)).toBe(POLL_MIN_MS);
    let delay = POLL_MIN_MS;
    for (let i = 0; i < 20; i += 1) delay = nextPollDelay(delay, false);
    expect(delay).toBe(POLL_MAX_MS);
  });
});

describe('page parsing', () => {
  it('turns incident events into ordered frames and tracks the high-water id', () => {
    const parsed = parseIncidentPage(
      page([
        { id: 4, type: 'state', data: { to: 'INVESTIGATING' } },
        { id: 5, type: 'evidence', data: { id: 'ev_1' } },
      ]),
    );
    expect(parsed.frames.map((f) => [f.id, f.event])).toEqual([
      ['4', 'state'],
      ['5', 'evidence'],
    ]);
    expect(parsed.last).toBe(5);
    expect(JSON.parse(parsed.frames[0]?.data ?? 'null')).toEqual({ to: 'INVESTIGATING' });
  });

  it('presents war-room rows as horizon frames in the stream shape', () => {
    const parsed = parseWarRoomPage({ events: [{ seq: 9, event: { kind: 'step' } }] });
    expect(parsed.frames[0]).toMatchObject({ id: '9', event: 'horizon' });
    expect(JSON.parse(parsed.frames[0]?.data ?? 'null')).toEqual({ seq: 9, event: { kind: 'step' } });
    expect(parsed.last).toBe(9);
  });
});

describe('openPoll', () => {
  let fetchMock: ReturnType<typeof vi.fn>;
  const visibility = { value: 'visible' as DocumentVisibilityState };

  beforeEach(() => {
    vi.useFakeTimers();
    notifyUnauthorized.mockClear();
    fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      get: () => visibility.value,
    });
    visibility.value = 'visible';
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it('sends the bearer header and resumes after the last delivered id', async () => {
    fetchMock
      .mockImplementationOnce(() => respond(page([{ id: 3, type: 'state', data: {} }])))
      .mockImplementation(() => respond(page([])));
    const frames: string[] = [];
    const stop = openPoll({
      path: (after) => `/v1/incidents/inc_1/events?after=${after}`,
      parse: parseIncidentPage,
      onFrame: (f) => frames.push(f.id ?? ''),
      onStatus: () => {},
    });

    await vi.advanceTimersByTimeAsync(0);
    expect(frames).toEqual(['3']);
    await vi.advanceTimersByTimeAsync(POLL_MIN_MS + 1);

    const [firstUrl, firstInit] = fetchMock.mock.calls[0] ?? [];
    expect(firstUrl).toBe('https://api.test/v1/incidents/inc_1/events?after=0');
    expect((firstInit.headers as Headers).get('Authorization')).toBe('Bearer token-123');
    const [secondUrl, secondInit] = fetchMock.mock.calls[1] ?? [];
    expect(secondUrl).toBe('https://api.test/v1/incidents/inc_1/events?after=3');
    expect((secondInit.headers as Headers).get('Last-Event-ID')).toBe('3');
    stop();
  });

  it('slows down while nothing changes so an idle page does not wake the backend', async () => {
    fetchMock.mockImplementation(() => respond(page([])));
    const stop = openPoll({
      path: () => '/x',
      parse: parseIncidentPage,
      onFrame: () => {},
      onStatus: () => {},
    });
    await vi.advanceTimersByTimeAsync(0);
    await vi.advanceTimersByTimeAsync(60_000);
    // Fixed 2 s polling would have made ~30 requests in a minute.
    expect(fetchMock.mock.calls.length).toBeLessThan(12);
    stop();
  });

  it('ends the session on 401 and never polls again', async () => {
    fetchMock.mockImplementation(() => respond({}, { status: 401 }));
    const statuses: string[] = [];
    openPoll({
      path: () => '/x',
      parse: parseIncidentPage,
      onFrame: () => {},
      onStatus: (s) => statuses.push(s),
    });
    await vi.advanceTimersByTimeAsync(120_000);
    expect(notifyUnauthorized).toHaveBeenCalledTimes(1);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(statuses.at(-1)).toBe('offline');
  });

  it('honours Retry-After while the database resumes', async () => {
    fetchMock
      .mockImplementationOnce(() =>
        respond({ error: { code: 'DATABASE_RESUMING' } }, { status: 503, headers: { 'Retry-After': '20' } }),
      )
      .mockImplementation(() => respond(page([])));
    const stop = openPoll({
      path: () => '/x',
      parse: parseIncidentPage,
      onFrame: () => {},
      onStatus: () => {},
    });
    await vi.advanceTimersByTimeAsync(0);
    await vi.advanceTimersByTimeAsync(19_000);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(2_000);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    stop();
  });

  it('makes no request while the tab is hidden and resumes when it is shown', async () => {
    visibility.value = 'hidden';
    fetchMock.mockImplementation(() => respond(page([])));
    const stop = openPoll({
      path: () => '/x',
      parse: parseIncidentPage,
      onFrame: () => {},
      onStatus: () => {},
    });
    await vi.advanceTimersByTimeAsync(120_000);
    expect(fetchMock).not.toHaveBeenCalled();

    visibility.value = 'visible';
    document.dispatchEvent(new Event('visibilitychange'));
    await vi.advanceTimersByTimeAsync(0);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    stop();
  });
});
