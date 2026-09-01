import { defineConfig } from 'vite';
import slang from 'vite-slang';
import { kinectBridge } from './bridge/plugin';

export default defineConfig({
  plugins: [slang(), kinectBridge()],
});
