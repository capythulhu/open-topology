import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import type { Plugin } from 'vite';

const FILE = resolve(__dirname, 'local.json');

export function localSettings(): Plugin {
  return {
    name: 'local-settings',
    configureServer(server) {
      server.middlewares.use('/settings', (req, res) => {
        if (req.method === 'GET') {
          res.setHeader('content-type', 'application/json');
          try {
            res.end(readFileSync(FILE, 'utf8'));
          } catch {
            res.end('{}');
          }
          return;
        }
        if (req.method === 'PUT') {
          const chunks: Buffer[] = [];
          req.on('data', (chunk: Buffer) => chunks.push(chunk));
          req.on('end', () => {
            mkdirSync(dirname(FILE), { recursive: true });
            writeFileSync(FILE, Buffer.concat(chunks));
            res.statusCode = 204;
            res.end();
          });
          return;
        }
        res.statusCode = 405;
        res.end();
      });
    },
  };
}
