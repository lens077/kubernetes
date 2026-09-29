#!/usr/bin/env node
// Real Grafana renderer/network acceptance. Login stays only in the test-owned browser.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { chromium, request } = require(process.env.PLAYWRIGHT_MODULE || '@playwright/test');
const base = 'https://grafana.apikv.com';
const hosts = JSON.parse(fs.readFileSync(path.join(__dirname, '../../hosts/observability/hosts.json'), 'utf8')).hosts.map(h => h.host).sort();
const doc = JSON.parse(fs.readFileSync(path.join(__dirname, 'dashboards/ops-portal.json'), 'utf8'));

(async () => {
  const s = JSON.parse(execFileSync('kubectl', ['-n','observability','get','secret','grafana-admin','-o','json'], {encoding:'utf8'})).data;
  const http = await request.newContext();
  let browser;
  try {
    assert.equal((await http.post(`${base}/login`, {data:{user:Buffer.from(s['admin-user'],'base64').toString(),password:Buffer.from(s['admin-password'],'base64').toString()}})).status(),200);
    browser = await chromium.launch({headless:true});
    const context = await browser.newContext({storageState:await http.storageState(),viewport:{width:1600,height:1100}});
    const page = await context.newPage();
    const pending=[], errors=[], expressions=new Set(), actual=new Set();
    page.on('pageerror', e=>errors.push(e.message));
    page.on('console', m=>{if(m.type()==='error')errors.push(m.text().slice(0,200));});
    page.on('response', r=>{
      const u=new URL(r.url());if(u.origin!==base)return;
      if(r.status()>=400)errors.push(`${r.status()} ${u.pathname}`);
      if(u.pathname!=='/api/ds/query')return;
      for(const q of r.request().postDataJSON().queries||[])if(q.expr)expressions.add(q.expr);
      pending.push(r.json().then(j=>{for(const v of Object.values(j.results||{})){
        if(v.error)errors.push(v.error);
        for(const f of v.frames||[]){
          for(const field of f.schema?.fields||[])if(field.labels?.host)actual.add(field.labels.host);
        }
      }}));
    });
    await page.goto(`${base}/d/ops-portal?from=now-30m&to=now`,{waitUntil:'networkidle',timeout:60000});
    for(const title of ['预期主机覆盖 · 缺一项也不算齐全','CPU 忙碌率趋势','内存使用率趋势','I/O 等待趋势','主机网络速率','覆盖范围与数据口径']){
      await page.getByText(title,{exact:true}).first().scrollIntoViewIfNeeded();
      const panel=doc.panels.find(p=>p.title===title);
      if(panel?.targets?.length) await assert.doesNotReject(async()=>{
        const end=Date.now()+20000;
        while(!panel.targets.every(q=>expressions.has(q.expr))){
          if(Date.now()>end)throw Error(`No renderer query for ${title}; observed ${[...expressions].join(' | ')}`);
          await page.waitForTimeout(200);
        }
      });
      await page.waitForLoadState('networkidle');
    }
    await Promise.all(pending);
    assert.deepEqual(errors,[]);
    assert.deepEqual([...actual].sort(),hosts);
    for(const p of doc.panels)for(const q of p.targets||[])assert.ok(expressions.has(q.expr),`Panel query not executed: ${p.id}`);
    const output=fs.mkdtempSync(path.join(os.tmpdir(),'host-portal-'));
    await page.getByText('预期主机覆盖 · 缺一项也不算齐全',{exact:true}).first().scrollIntoViewIfNeeded();
    await page.waitForTimeout(1200);
    assert.ok((await page.locator('body').innerText()).includes('四类指标齐全'),'Coverage table must actually render, not only execute a query');
    await page.screenshot({path:path.join(output,'coverage.png')});
    await page.getByText('CPU 忙碌率',{exact:true}).first().scrollIntoViewIfNeeded();
    await page.screenshot({path:path.join(output,'resources.png')});
    await page.setViewportSize({width:420,height:900});
    await page.getByText('预期主机覆盖 · 缺一项也不算齐全',{exact:true}).first().scrollIntoViewIfNeeded();
    await page.screenshot({path:path.join(output,'mobile.png')});
    console.log('PASS browser expressions',expressions.size,'hosts',hosts.join(','),'screenshots',output);
  } finally {if(browser)await browser.close();await http.dispose();}
})().catch(e=>{console.error(e.message);process.exitCode=1;});
