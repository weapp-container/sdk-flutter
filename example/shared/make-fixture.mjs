import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const canonical = value => {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value !== null && typeof value === 'object') return `{${Object.keys(value).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b))).map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
};
const sha = value => createHash('sha256').update(value).digest('hex');

/** Pure authored consumer fixture, not upstream compiler or conformance evidence.
 * The first parameter is retained for existing consumer generators and is never read.
 */
export function makeFixture(_unusedRepository, destination) {
  if (!destination) throw new Error('An explicit fixture destination is required');
  mkdirSync(resolve(destination, 'blobs/sha256'), { recursive: true });
  function blob(value) { const bytes = typeof value === 'string' ? value : canonical(value); const hash = sha(bytes); writeFileSync(resolve(destination, 'blobs/sha256', hash), bytes); return hash; }
  const manifest = {
    schemaVersion: 1, protocolVersion: '1.0',
    // Schema v1 fixes this name; the commit explicitly disclaims a compiler build.
    compiler: { name: 'weapp-vite', commit: 'handwritten-sdk-contract-fixture-not-a-compiler-build', platform: 'weapp' },
    app: { appJson: 'app.json', entryModule: 'app.js' },
    routes: [{ id: 'route:pages/home/index', path: 'pages/home/index', kind: 'page', config: 'pages/home/index.json', entryModule: 'pages/home/index.js' }],
    modules: [
      { id: 'module:app.js', format: 'commonjs', scope: 'app', sha256: blob('App({});') },
      { id: 'module:app.json', format: 'json', scope: 'app', sha256: blob({ pages: ['pages/home/index'] }) },
      { id: 'module:pages/home/index.js', format: 'commonjs', scope: 'page', sha256: '' },
      { id: 'module:pages/home/index.json', format: 'json', scope: 'page', sha256: blob({}) },
    ],
    templates: [{ id: 'template:pages/home/index.wxml', wxmlAst: '', bindings: [] }],
    styles: [
      { id: 'style:app.wxss', scope: 'app', wxssIr: `sha256:${blob({ version: 1, imports: [], rules: [] })}` },
      { id: 'style:pages/home/index.wxss', scope: 'page', wxssIr: '' },
    ],
    components: [], assets: [],
    // These are fixture dependencies, not a platform conformance claim. An empty
    // map intentionally disables the wx facade, including module-scope calls.
    capabilities: Object.fromEntries([
      'getCurrentPages', 'wx.getWindowInfo', 'wx.getStorageSync', 'wx.setStorageSync',
      'wx.createSelectorQuery', 'wx.request', 'wx.timer',
    ].map(name => [name, 'partial'])),
    integrity: { algorithm: 'sha256', root: '' },
  };
  const page = `
const firstWindow = wx.getWindowInfo();
Page({
 data: {count:0,message:'Independent SDK consumer',shows:0},
 onLoad() {
   const stored = wx.getStorageSync('sdk-count') || 0;
   this.setData({count:stored});
   weappContainer.postMessage({kind:'initial',stored,...firstWindow});
   weappContainer.postMessage({kind:'initWindow',window:firstWindow});
   // iOS/framework consumers register this probe; a consumer using only the
   // Android host.echo convention does not increment its echo counter here.
   weappContainer.invoke('native.echo',{from:'javascript'}).then(result => weappContainer.postMessage({kind:'hostResult',result})).catch(() => {});
   this.listener = message => {
     const pages = getCurrentPages(); if (pages[pages.length-1] !== this) return;
     if(message.kind === 'hidden') weappContainer.invoke('native.delayed',{hidden:true}).then(result => weappContainer.postMessage({kind:'hiddenDone',result}));
     else if(message.op === 'echo') weappContainer.invoke('host.echo',message.value).then(value => weappContainer.postMessage({kind:'echo',value}));
     else if(message.op === 'hang') weappContainer.invoke('host.hang',{}, {timeout:80}).catch(error => weappContainer.postMessage({kind:'timeout',error:String(error)}));
     else if(message.op === 'store') { wx.setStorageSync('consumer-value',message.value); weappContainer.postMessage({kind:'stored'}); }
     else if(message.op === 'read') weappContainer.postMessage({kind:'storedValue',value:wx.getStorageSync('consumer-value')});
     else if(message.op === 'request') wx.request({url:message.url,success:response => weappContainer.postMessage({kind:'network',value:response.data}),fail:error => weappContainer.postMessage({kind:'networkFailure',error})});
     else if(message.op === 'inspect') wx.createSelectorQuery().select('#sdk-scroll').boundingClientRect().exec(rects => weappContainer.postMessage({kind:'geometry',scroll:rects[0],tap:{x:40,y:80},...wx.getWindowInfo()}));
     else weappContainer.postMessage({kind:message.kind === 'recovered'?'recovered':'echo',message});
   };
   weappContainer.onMessage(this.listener);
 },
 onShow() { this.setData({shows:this.data.shows+1}); weappContainer.postMessage({kind:'show',shows:this.data.shows,route:this.route}); },
 onHide() { weappContainer.postMessage({kind:'hide'}); },
 onUnload() { weappContainer.offMessage(this.listener); },
 onResize() { weappContainer.postMessage({kind:'resize',...wx.getWindowInfo()}); },
 onScroll(event) { weappContainer.postMessage({kind:'scroll',scrollTop:event.detail.scrollTop,scrollLeft:event.detail.scrollLeft}); },
 onTap() {
   this.setData({count:this.data.count+1}); wx.setStorageSync('sdk-count',this.data.count);
   weappContainer.postMessage({kind:'tap',count:this.data.count});
   setTimeout(() => { this.setData({message:'Timer completed'}); weappContainer.postMessage({kind:'timer',count:this.data.count}); },80);
 }
});
`;
  const text = value => ({ kind: 'text', value, bindings: [] });
  const element = (tag, attrs, children, events) => ({ kind: 'element', tag, attrs, bindings: [], ...(events ? { directives: { events } } : {}), children });
  const template = { version: 1, nodes: [element('view', { class: 'screen', bindtap: 'onTap' }, [
    element('text', { class: 'title' }, [text('Weapp Container SDK')]),
    element('text', { class: 'message' }, [{ ...text('{{message}}'), bindings: ['message'] }]),
    element('text', { class: 'count' }, [{ ...text('Tap count: {{count}}'), bindings: ['count'] }]),
    element('scroll-view', { id: 'sdk-scroll', class: 'scroller', 'scroll-y': 'true', bindscroll: 'onScroll' }, [
      element('view', { class: 'long' }, [element('text', {}, [text('Drag to scroll — native input')])]),
    ], { bindscroll: 'onScroll' }),
  ], { bindtap: 'onTap' })] };
  const declarations = values => values.map(([property, value]) => ({ important: false, property, value }));
  const style = { version: 1, imports: [], rules: [
    { selectors: ['.screen'], nested: [], declarations: declarations([['height', '100%'], ['padding', '28px'], ['background', '#dcecff']]) },
    { selectors: ['.title', '.message', '.count'], nested: [], declarations: declarations([['display', 'block'], ['font-size', '18px'], ['height', '32px']]) },
    { selectors: ['.scroller'], nested: [], declarations: declarations([['display', 'block'], ['height', '160px'], ['width', '100%'], ['background', '#bfd8f5']]) },
    { selectors: ['.long'], nested: [], declarations: declarations([['height', '900px'], ['padding', '12px']]) },
  ] };
  const pageHash = blob(page), templateHash = blob(template), styleHash = blob(style);
  const homeModule = manifest.modules.find(m => m.id === 'module:pages/home/index.js'); homeModule.sha256 = pageHash;
  const homeTemplate = manifest.templates.find(t => t.id === 'template:pages/home/index.wxml'); homeTemplate.wxmlAst = `sha256:${templateHash}`; homeTemplate.bindings = ['count', 'message'];
  const homeStyle = manifest.styles.find(s => s.id === 'style:pages/home/index.wxss'); homeStyle.wxssIr = `sha256:${styleHash}`;
  manifest.modules.push({ ...homeModule, id: 'module:pages/detail/index.js' }, { id: 'module:pages/detail/index.json', format: 'json', scope: 'page', sha256: blob({}) });
  manifest.templates.push({ ...homeTemplate, id: 'template:pages/detail/index.wxml' });
  manifest.styles.push({ ...homeStyle, id: 'style:pages/detail/index.wxss' });
  manifest.routes.push({ config: 'pages/detail/index.json', entryModule: 'pages/detail/index.js', id: 'route:pages/detail/index', kind: 'page', path: 'pages/detail/index' });
  const appModule = manifest.modules.find(m => m.id === 'module:app.json');
  const app = JSON.parse(readFileSync(resolve(destination, 'blobs/sha256', appModule.sha256))); app.pages = ['pages/home/index', 'pages/detail/index']; appModule.sha256 = blob(app);
  const document = manifest.viewCompilation?.documents.find(d => d.documentId === 'pages/home/index.wxml');
  if (document) { document.wxmlAst = `sha256:${templateHash}`; manifest.viewCompilation.documents.push({ ...document, documentId: 'pages/detail/index.wxml' }); }
  manifest.integrity.root = ''; manifest.integrity.root = sha(canonical(manifest));
  writeFileSync(resolve(destination, 'manifest.json'), canonical(manifest));
  return manifest.integrity.root;
}

export function makeAcceptancePack(destination) { return makeFixture(undefined, destination); }

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const index = process.argv.indexOf('--out');
  const destination = index >= 0 ? process.argv[index + 1] : undefined;
  if (!destination) throw new Error('--out requires a directory');
  console.log(JSON.stringify({ destination: resolve(destination), integrity: makeAcceptancePack(resolve(destination)), provenance: 'handwritten-sdk-fixture' }, null, 2));
}
