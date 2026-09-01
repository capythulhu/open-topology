const FRAME_BYTES = 640 * 480 * 2;

export type DepthStream = { stop: () => void };

export async function bridgeReady(): Promise<boolean> {
  try {
    const response = await fetch('/kinect/status');
    return response.ok && (await response.json()).built === true;
  } catch {
    return false;
  }
}

export function streamDepth(
  onFrame: (frame: Uint8Array<ArrayBuffer>) => void,
  onEnd: (reason: string) => void,
): DepthStream {
  const abort = new AbortController();

  void (async () => {
    try {
      const response = await fetch('/kinect/stream', { signal: abort.signal });
      if (!response.ok || !response.body) {
        onEnd(await response.text());
        return;
      }

      const reader = response.body.getReader();
      const frame = new Uint8Array(new ArrayBuffer(FRAME_BYTES));
      let filled = 0;

      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        let offset = 0;
        while (offset < value.length) {
          const take = Math.min(FRAME_BYTES - filled, value.length - offset);
          frame.set(value.subarray(offset, offset + take), filled);
          filled += take;
          offset += take;
          if (filled === FRAME_BYTES) {
            onFrame(frame);
            filled = 0;
          }
        }
      }
      onEnd('the kinect stream ended');
    } catch (error) {
      if (!abort.signal.aborted) onEnd(String(error));
    }
  })();

  return { stop: () => abort.abort() };
}
