import { resolve } from 'node:path';
import { defineConfig } from 'vite';
import slang from 'vite-slang';
import { kinectBridge } from './bridge/plugin';

export default defineConfig({
  plugins: [slang(), kinectBridge()],
  build: {
    rollupOptions: {
      input: {
        main: resolve(__dirname, 'index.html'),
        projector: resolve(__dirname, 'projector.html'),
      },
    },
  },
});
