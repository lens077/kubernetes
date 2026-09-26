#!/usr/bin/env node
// Uses an isolated browser and the existing admin Secret; never saves credentials.
// Set PLAYWRIGHT_MODULE to an installed @playwright/test module when run outside
// a Node workspace. --http-only reproduces the cookie + Origin regression.
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { chromium, request } = require(process.env.PLAYWRIGHT_MODULE || '@playwright/test');

const base = (process.env.GRAFANA_URL || 'https://grafana.apikv.com').replace(/\/$/, '');
assert.equal(new URL(base).protocol, 'https:', 'Public verification requires HTTPS');
const dashboard = JSON.parse(fs.readFileSync(path.join(__dirname, 'dashboards/ntfy-alerting-overview.json'), 'utf8'));
const expectedQueries = dashboard.panels.flatMap(p => p.targets || []).length;

async function main() {
  const secret = JSON.parse(execFileSync('kubectl', [
    '-n', 'observability', 'get', 'secret', 'grafana-admin', '-o', 'json',
  ], { encoding: 'utf8' })).data;
  const credentials = {
    user: Buffer.from(secret['admin-user'], 'base64').toString(),
    password: Buffer.from(secret['admin-password'], 'base64').toString(),
  };
  const http = await request.newContext();
  let browser;
  try {
    const login = await http.post(`${base}/login`, { data: credentials });
    assert.equal(login.status(), 200, 'Existing login failed; do not reset credentials');
    const sources = await (await http.get(`${base}/api/datasources`)).json();
    const datasource = sources.find(d => d.name === 'VictoriaMetrics');
    assert.ok(datasource, 'VictoriaMetrics datasource is missing');
    const now = Date.now();
    const data = {
      from: String(now - 60000), to: String(now),
      queries: [{ refId: 'A', datasource: { type: 'prometheus', uid: datasource.uid },
        expr: 'vector(1)', instant: true, range: false, intervalMs: 15000, maxDataPoints: 10 }],
    };
    for (const [origin, expected] of [[base, 200], ['https://not-grafana.invalid', 403]]) {
      const response = await http.post(`${base}/api/ds/query`, { headers: { Origin: origin }, data });
      console.log('origin_check', new URL(origin).hostname, 'HTTP', response.status());
      assert.equal(response.status(), expected, `Origin regression: ${new URL(origin).hostname}`);
      if (expected === 200) {
        const result = (await response.json()).results.A;
        assert.ok(!result.error && result.frames?.length, 'Minimal browser-origin query must return data');
      }
    }
    if (process.argv.includes('--http-only')) return;

    browser = await chromium.launch({ headless: true });
    // Keep the login state only in memory in this test-owned browser context.
    const context = await browser.newContext({ storageState: await http.storageState(), viewport: { width: 1920, height: 1080 } });
    const page = await context.newPage();
    const pending = [];
    const queries = [];
    const errors = [];
    const consoleErrors = [];
    page.on('pageerror', error => errors.push(`page: ${error.message}`));
    page.on('console', message => {
      if (message.type() === 'error') consoleErrors.push(message.text().slice(0, 500));
    });
    page.on('response', response => {
      const endpoint = new URL(response.url()).pathname;
      if (response.status() >= 400) errors.push(`HTTP ${response.status()} ${endpoint}`);
      if (endpoint !== '/api/ds/query') return;
      pending.push((async () => {
        const body = response.request().postDataJSON();
        const text = await response.text();
        let result;
        try { result = JSON.parse(text); }
        catch { errors.push(`Query returned non-JSON: HTTP ${response.status()}`); return; }
        for (const [ref, value] of Object.entries(result.results || {})) {
          if (value.error || value.status >= 400) errors.push(`Query ${ref}: ${value.error || value.status}`);
        }
        for (const query of body.queries || []) queries.push(query.expr || query.root_selector);
        console.log('browser_query', response.status(), 'targets', body.queries?.length || 0);
      })().catch(error => errors.push(`Response read: ${error.message}`)));
    });
    const url = new URL(`/d/${dashboard.uid}`, base);
    url.searchParams.set('var-datasource', datasource.uid);
    url.searchParams.set('from', 'now-24h');
    url.searchParams.set('to', 'now');
    await page.goto(url.href, { waitUntil: 'networkidle', timeout: 45000 });
    await page.getByText('触发实例（含提醒）', { exact: true }).first().waitFor();
    await page.getByText('Gatus 有数据端点', { exact: true }).first().scrollIntoViewIfNeeded();
    await page.waitForLoadState('networkidle');
    await Promise.all(pending);
    const output = fs.mkdtempSync(path.join(os.tmpdir(), 'ntfy-grafana-browser-'));
    await page.screenshot({ path: path.join(output, 'lower.png') });
    await page.getByText('触发实例（含提醒）', { exact: true }).first().scrollIntoViewIfNeeded();
    await page.screenshot({ path: path.join(output, 'dashboard.png') });
    console.log('screenshots', output);
    console.log('visible_text', (await page.locator('body').innerText()).slice(0, 11000));
    console.log('unique_query_count', new Set(queries).size, 'expected', expectedQueries);
    console.log('browser_errors', JSON.stringify(errors));
    console.log('console_errors', JSON.stringify(consoleErrors));
    assert.equal(errors.length, 0, 'Browser HTTP or query errors remain');
    assert.equal(consoleErrors.length, 0, 'Browser console errors remain');
    assert.ok(new Set(queries).size >= expectedQueries, 'Not every panel query was executed in the browser');
    console.log('Grafana browser acceptance PASSED');
  } finally {
    if (browser) await browser.close();
    await http.dispose();
  }
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
