#!/usr/bin/env node
// Real-browser read-only drilldown verification. Never modifies alert state.
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { chromium, request } = require(process.env.PLAYWRIGHT_MODULE || '@playwright/test');
const base = 'https://grafana.apikv.com';

async function main() {
  const data = JSON.parse(execFileSync('kubectl', ['-n','observability','get','secret','grafana-admin','-o','json'], {encoding:'utf8'})).data;
  const alerts = JSON.parse(execFileSync('kubectl', ['get','--raw','/api/v1/namespaces/observability/services/vmalert:8880/proxy/api/v1/alerts'], {encoding:'utf8'})).data.alerts;
  const source = alerts.find(a => a.name === 'CNPGNoBackupEver');
  assert.ok(source, 'No CNPGNoBackupEver instance for this live scenario; do not inject a production alert');
  const http = await request.newContext();
  const browser = await chromium.launch({headless:true});
  const out = fs.mkdtempSync(path.join(os.tmpdir(),'grafana-triage-review-'));
  console.log('screenshots',out);
  const failures = [];
  const requests = [];
  const work = [];
  try {
    const login = await http.post(base+'/login', {data:{user:Buffer.from(data['admin-user'],'base64').toString(), password:Buffer.from(data['admin-password'],'base64').toString()}});
    assert.equal(login.status(),200);
    const state = await http.storageState();
    const context = await browser.newContext({storageState:state,viewport:{width:1920,height:1080}});
    const page = await context.newPage();
    page.on('pageerror',e=>failures.push(e.message));
    page.on('console',m=>{if(m.type()==='error')failures.push(m.text().slice(0,400));});
    page.on('response',r=>{
      const endpoint=new URL(r.url()).pathname;
      if(r.status()>=400)failures.push(`HTTP ${r.status()} ${endpoint}`);
      if(endpoint==='/api/ds/query')work.push((async()=>{
        const body=r.request().postDataJSON(); requests.push(...body.queries);
        const response=await r.json();
        for(const result of Object.values(response.results||{}))if(result.error||result.status>=400)failures.push(result.error||String(result.status));
      })().catch(e=>failures.push(e.message)));
    });
    const settle=async()=>{await page.waitForLoadState('networkidle');await Promise.all(work);};
    await page.goto(base+'/d/ntfy-alerting-overview',{waitUntil:'networkidle'});
    const summary=page.getByRole('link',{name:source.annotations.summary,exact:true}).first();
    await summary.waitFor();
    assert.ok((await page.locator('body').innerText()).includes(source.annotations.description),'Actual annotation description absent');
    await page.screenshot({path:path.join(out,'desktop.png')});
    const href=await summary.getAttribute('href');
    assert.equal(new URL(href,base).searchParams.get('var-instance'),source.group_id+':'+source.id);
    await summary.click();
    await page.waitForURL('**/d/alert-instance-detail**');
    await page.getByText(source.expression,{exact:true}).first().waitFor({timeout:20000});
    await settle();
    assert.equal(new URL(page.url()).pathname.split('/')[2],'alert-instance-detail');
    assert.ok((await page.locator('body').innerText()).includes(source.expression),'Selected expression absent');
    const evidence=page.locator('a[href*="/d/infra-cnpg?var-cnpg_cluster="]').first();
    await evidence.waitFor();
    await page.getByRole('link',{name:source.annotations.summary,exact:true}).first().waitFor();
    await page.screenshot({path:path.join(out,'instance.png')});
    const evidenceUrl=new URL(await evidence.getAttribute('href'),base);
    assert.equal(evidenceUrl.searchParams.get('var-cnpg_cluster'),source.labels.cnpg_cluster);
    assert.equal(evidenceUrl.searchParams.get('var-pod'),source.labels.pod);
    await evidence.click();
    await page.waitForURL('**/d/infra-cnpg**');
    await page.getByText('无可用备份',{exact:true}).first().waitFor({timeout:20000});
    await settle();
    assert.ok(requests.some(q=>q.expr?.includes('cnpg_cluster=~"'+source.labels.cnpg_cluster+'"')),'CNPG filter did not reach query');
    assert.ok((await page.locator('body').innerText()).includes('无可用备份'));
    await page.screenshot({path:path.join(out,'cnpg.png')});
    console.log('verified summary -> exact instance -> CNPG object filter');
    await page.goBack({waitUntil:'networkidle'});
    const log=page.getByRole('link',{name:'查看对象日志',exact:true}).first();
    await log.waitFor();
    const logHref=await log.getAttribute('href');const panes=JSON.parse(new URL(logHref,base).searchParams.get('panes'));
    assert.ok(panes.logs.queries[0].expr.includes(source.labels.pod));
    await log.click();await settle();
    assert.equal(new URL(page.url()).pathname,'/explore');
    console.log('verified object log link',panes.logs.queries[0].expr);
    for(const uid of ['infra-overview','infra-kubernetes','infra-cdc','infra-observability']) {
      await page.goto(base+'/d/'+uid,{waitUntil:'networkidle'});await settle();
      const body=await page.locator('body').innerText();
      assert.ok(!/Organize fields only works with a single frame|An unexpected error happened/.test(body),uid+' frame transform failed');
      await page.screenshot({path:path.join(out,uid+'.png')});
      console.log('verified dashboard',uid,body.slice(-1400));
    }
    const mobile=await context.newPage();await mobile.setViewportSize({width:390,height:844});
    await mobile.goto(base+'/d/ntfy-alerting-overview',{waitUntil:'networkidle'});
    await mobile.getByText('当前问题 · 点击摘要看详情，点击证据直达对象',{exact:true}).scrollIntoViewIfNeeded();
    const mobileLink=mobile.getByRole('link',{name:source.annotations.summary,exact:true}).first();
    await mobileLink.scrollIntoViewIfNeeded();
    await mobileLink.waitFor();
    await mobile.screenshot({path:path.join(out,'mobile.png')});
    console.log('screenshots',out);
    console.log('query_models_seen',requests.length,'errors',JSON.stringify(failures));
    assert.equal(failures.length,0,'Browser errors remain');
    console.log('Live triage drilldown acceptance PASSED');
  } finally {await browser.close();await http.dispose();}
}
main().catch(e=>{console.error(e.message);process.exitCode=1;});
