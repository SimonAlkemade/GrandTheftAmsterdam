// Render viewer.html headlessly: node preview/shoot.mjs out/sample_canal.glb out/shots
// Needs `playwright` and a Chromium; serves the project folder on a local port.
import { chromium } from 'playwright';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const root = process.env.ROOT || path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const glb = process.argv[2] || 'out/sample_canal.glb';
const outDir = process.argv[3] || 'out/shots';
const views = (process.argv[4] || 'aerial,street,gable').split(',');
const types = { '.html': 'text/html', '.js': 'text/javascript', '.glb': 'model/gltf-binary' };

const server = http.createServer((req, res) => {
  const p = path.join(root, decodeURIComponent(new URL(req.url, 'http://x').pathname));
  if (!p.startsWith(root) || !fs.existsSync(p)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': types[path.extname(p)] || 'application/octet-stream' });
  fs.createReadStream(p).pipe(res);
}).listen(0);
const port = server.address().port;

const browser = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
const page = await browser.newPage({ viewport: { width: 1400, height: 800 } });
page.on('console', m => m.type() === 'error' && console.error('[page]', m.text()));
fs.mkdirSync(path.join(root, outDir), { recursive: true });
for (const view of views) {
  await page.goto(`http://localhost:${port}/preview/viewer.html?glb=/${glb}&view=${view}`);
  await page.waitForFunction(() => window.__ready, null, { timeout: 180000 });
  if (await page.evaluate(() => window.__ready) === 'error') throw new Error('load failed');
  const file = path.join(root, outDir, `${view}.png`);
  await page.screenshot({ path: file });
  console.log('wrote', file);
}
await browser.close();
server.close();
