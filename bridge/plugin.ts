import { spawn, type ChildProcess } from 'node:child_process';
import { existsSync } from 'node:fs';
import type { Plugin } from 'vite';

const BINARY = 'bridge/depth';

let current: ChildProcess | null = null;

function stopCurrent(): Promise<void> {
  const child = current;
  current = null;
  if (!child || child.exitCode !== null) return Promise.resolve();
  return new Promise((resolve) => {
    child.once('exit', () => resolve());
    child.kill('SIGTERM');
  });
}

export function kinectBridge(): Plugin {
  return {
    name: 'kinect-bridge',
    configureServer(server) {
      server.middlewares.use('/kinect/status', (_request, response) => {
        response.setHeader('content-type', 'application/json');
        response.end(JSON.stringify({ built: existsSync(BINARY) }));
      });

      server.middlewares.use('/kinect/stream', async (request, response) => {
        if (!existsSync(BINARY)) {
          response.statusCode = 503;
          response.end('kinect bridge not built — run: npm run kinect:setup');
          return;
        }

        await stopCurrent();

        const child = spawn(BINARY, { stdio: ['ignore', 'pipe', 'pipe'] });
        current = child;

        let problem = '';
        let streaming = false;
        child.stderr.on('data', (chunk: Buffer) => { problem += chunk.toString(); });

        child.stdout.once('data', (chunk: Buffer) => {
          streaming = true;
          response.setHeader('content-type', 'application/octet-stream');
          response.setHeader('cache-control', 'no-store');
          response.write(chunk);
          child.stdout.pipe(response);
        });

        child.on('error', (error) => { problem += error.message; });
        child.on('exit', () => {
          if (streaming) {
            response.end();
          } else {
            response.statusCode = 503;
            response.end(problem.trim() || 'the kinect stopped before sending a frame');
          }
        });

        request.on('close', () => { if (current === child) void stopCurrent(); });
      });

      server.httpServer?.once('close', () => { void stopCurrent(); });
    },
  };
}
