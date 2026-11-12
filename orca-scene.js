/* HALOFLUX by Ryder191: real Orca state in the original animation and panels.
   This adapter owns no animation loop and never rebuilds scene geometry. */
(() => {
  'use strict';
  if (window.haloOrcaEnabled !== true) return;

  const FONT = 'ui-monospace,"Cascadia Mono","SF Mono",Consolas,"Liberation Mono",monospace';
  const $ = id => document.getElementById(id);
  const PALETTE = window.HALO_WORKSPACE_COLORS || [[196,182,244],[240,62,62],[92,124,250],[47,158,68]];
  const ROTATION_MS = 15000;
  const DEFAULT_SCENES = [
    ['moonshot','Moonshot Lab','A little room for big ideas.'],
    ['deep-thought','Deep Thought','Good ideas take their time.'],
    ['quiet-orbit','Quiet Orbit','Everything in its own orbit.'],
    ['coffee-break','Coffee Break','A quiet pause between ideas.']
  ].map(([id,name,note],paletteIndex)=>({id:`haloflux-default/${id}`,name,note,paletteIndex,
    isDefault:true,project:'',path:'',branch:'',status:'standby',isActive:false,lastActivityAt:0,agents:[]}));
  const INFO = {
    working: ['Working','WORK',0], waiting: ['Waiting','WAIT',1], error: ['Error','ERROR',2],
    idle: ['Idle','IDLE',3], completed: ['Completed','DONE',4], ended: ['Turn ended','ENDED',4],
    stopped: ['Stopped','STOP',5], unconfirmed: ['Unconfirmed','CHECK',5], unknown: ['Unknown','UNKNOWN',6]
  };
  const PROFILES = {
    working: {tempo:.6,ringSpeed:.6,runnerSpeed:.6,webSpin:1},
    idle: {tempo:.2,ringSpeed:.12,runnerSpeed:0,webSpin:0}
  };
  const ENDED = new Set(['ended','completed','stopped','error','unconfirmed']);
  let booted = false, snapshot = null, lastGood = null, focus = null, focusId = null;
  let connection = 'connecting', priorAgents = new Map(), initialized = false, events = [];
  let histories = new Map(), revision = 1, signature = '', lastUI = 0, uiDirty = true;
  let profile = {...PROFILES.working}, profileFrom = {...profile}, profileTarget = {...profile}, profileKey = '', profileStarted = 0;
  const accent = [180,180,180], secondary = [191.2,191.2,191.2];
  const scenePalette = {accent,secondary,purpleWeight:0};
  let paletteFrom = accent.slice(), paletteTarget = accent.slice(), paletteStarted = 0, paletteCSS = '';
  let purpleFrom = 0, purpleTarget = 0;
  let panelRefs = [];
  let selectedIds = [], lastSwitch = Date.now(), activity = 0, activityFrom = 0, activityTarget = 0;
  let selectionMode = '';
  let previousAttentionWorkspaces = new Set();
  const sceneAttention = {active:false,count:0,level:0};
  const workspaceColors = new Map(DEFAULT_SCENES.map(w=>[w.id,w.paletteIndex]));
  const headlineAgents = new Map();

  const string = (v, fallback = '') => v == null ? fallback : String(v);
  function time(v) {
    if (v == null || v === '') return 0;
    const n = Number(v); if (Number.isFinite(n)) return n > 0 && n < 1e11 ? n * 1000 : n;
    const parsed = Date.parse(v); return Number.isFinite(parsed) ? parsed : 0;
  }
  function hash(v) { let h = 2166136261; for (const c of string(v)) { h ^= c.codePointAt(0); h = Math.imul(h,16777619); } return h >>> 0; }
  function rgba(c, a = 1) { return `rgba(${c.map(v=>Math.round(v)).join(',')},${a})`; }
  function colorFor(id) {
    return PALETTE[workspaceColors.get(id) ?? hash(id) % PALETTE.length].slice();
  }
  function updatePalette(now = Date.now()) {
    const t = paletteStarted ? Math.max(0,Math.min(1,(now-paletteStarted)/1200)) : 1;
    const ease = t*t*(3-2*t);
    for(let i=0;i<3;i++){
      accent[i]=paletteFrom[i]+(paletteTarget[i]-paletteFrom[i])*ease;
      secondary[i]=accent[i]*.72+220*.28;
    }
    scenePalette.purpleWeight=purpleFrom+(purpleTarget-purpleFrom)*ease;
    const css=rgba(accent);
    if(css!==paletteCSS){
      paletteCSS=css;
      const style=document.documentElement.style;
      style.setProperty('--orca-accent',css);style.setProperty('--orca-secondary',rgba(secondary));
    }
  }
  function targetPalette(color,isPurple=false) {
    const weight=isPurple?1:0;
    if(color.every((v,i)=>v===paletteTarget[i])&&weight===purpleTarget)return;
    updatePalette();paletteFrom=accent.slice();paletteTarget=color.slice();purpleFrom=scenePalette.purpleWeight;purpleTarget=weight;paletteStarted=Date.now();
  }
  function state(a) {
    const raw = string(a?.state).toLowerCase().replace(/[\s-]+/g,'_');
    let value = 'unknown';
    if (['working','running','thinking','executing','processing','in_progress','busy'].includes(raw)) value = 'working';
    else if (['waiting','waiting_for_input','awaiting_input','needs_input','input_required','blocked'].includes(raw)) value = 'waiting';
    else if (['idle','ready'].includes(raw)) value = 'idle';
    else if (raw === 'done') value = 'ended';
    else if (['completed','complete','finished'].includes(raw)) value = 'completed';
    else if (['stopped','exited','closed','terminated','cancelled','canceled'].includes(raw)) value = 'stopped';
    else if (['error','failed','failure'].includes(raw)) value = 'error';
    if (['ended','completed'].includes(value)) {
      const outcome = string(a.outcome).toLowerCase();
      if (outcome === 'failure') value = 'error';
      else if (['interruption','cancellation','superseded'].includes(outcome) || a.interrupted === true) value = 'stopped';
      else if (outcome === 'unconfirmed') value = 'unconfirmed';
      else if (outcome === 'success') value = 'completed';
    }
    return value;
  }
  function english(value) { const v=string(value).trim(); return /^[\x20-\x7E\t]+$/.test(v)?v:''; }
  // Only the bridge's explicit pending-user-request evidence can light a page.
  // Generic waiting, child-agent waits and unread updates do not qualify.
  function needsReply(a) { return a?.needsInput===true; }
  function attentionCount(workspace) { return (workspace?.agents||[]).filter(needsReply).length; }
  function agentStatus(a,short=false) { return needsReply(a)?(short?'REPLY':'Awaiting reply'):INFO[state(a)][short?1:0]; }
  function type(a) { return english(a.type)||'Agent'; }
  function shortID(a) { return english(string(a.id).split('/').pop())?.slice(-8)||''; }
  function title(a) { return english(a.title)||[type(a),shortID(a)].filter(Boolean).join(' / '); }
  function tool(a) { return english(a.toolName); }
  function modelName(a) {
    if(!a)return '';
    const id=english(a.modelId),display=english(a.modelDisplayName);
    const value=id||display;
    // Selection modes are not confirmed model identities. Keep a supplied
    // identifier intact apart from capitalization, including version suffixes.
    const selector=value.toLowerCase().replace(/\s*\([^)]*\)\s*$/,'').replace(/[\s_]+/g,'-');
    if(!value||['auto','automatic','auto-select','auto-selection','default','default-model','system','system-default','provider-default','inherit','inherited','none','unknown','unspecified','null','n/a'].includes(selector))return '';
    return value.toUpperCase();
  }
  function headlineAgent() {
    const agents=focus?.agents||[];
    if(!agents.length)return null;
    const rank=a=>needsReply(a)?(a.parentId?-1:-2):state(a)==='working'?(a.parentId?1:0):state(a)==='waiting'?(a.parentId?3:2):a.parentId?5:4;
    const best=Math.min(...agents.map(rank));
    const candidates=agents.filter(a=>rank(a)===best);
    // Keep the same equally relevant working/waiting agent through polling.
    // Once no agent needs attention, show the most recently observed session.
    const previous=best<4?candidates.find(a=>a.id===headlineAgents.get(focusId)):null;
    const selected=previous||candidates.sort((a,b)=>Math.max(b.updatedAt,b.stateStartedAt)-Math.max(a.updatedAt,a.stateStartedAt)||a.id.localeCompare(b.id))[0];
    headlineAgents.set(focusId,selected.id);
    return selected;
  }
  function tally(agents = []) {
    const c = {working:0,waiting:0,idle:0,ended:0,unknown:0,total:agents.length,main:0,child:0,unread:0,attention:0};
    for (const a of agents) {
      const s = state(a); if (ENDED.has(s)) c.ended++; else c[s]++;
      a.parentId ? c.child++ : c.main++; if (a.activity?.unread === true) c.unread++;
      if(needsReply(a))c.attention++;
    }
    return c;
  }
  function observedWorkspaces() { return (snapshot?.connected ? snapshot : lastGood)?.workspaces || []; }
  function status() {
    if(!snapshot)return 'connecting';
    if(!snapshot.connected)return 'offline';
    if(!snapshot.observedAt||Date.now()-snapshot.observedAt>Math.max(5000,Number(window.haloOrcaStaleAfterMs)||20000))return 'stale';
    return 'live';
  }
  // Previous observations remain available for diagnostics, never as evidence
  // that a task is still running after the source disconnects or goes stale.
  function activeWorkspaces() {
    return status()==='live'?snapshot.workspaces.filter(w=>w.agents.some(a=>needsReply(a)||state(a)==='working')):[];
  }
  function usingDefaults() { return activeWorkspaces().length===0; }
  function allWorkspaces() { const active=activeWorkspaces();return active.length?active:DEFAULT_SCENES; }
  function selectedWorkspaces() { const workspaces=allWorkspaces();return selectedIds.map(id=>workspaces.find(w=>w.id===id)).filter(Boolean); }
  function allAgents() { return selectedWorkspaces().flatMap(w=>w.agents); }
  function sortedAgents() { return [...(focus?.agents || [])].sort((a,b)=>Number(needsReply(b))-Number(needsReply(a))||INFO[state(a)][2]-INFO[state(b)][2]||a.id.localeCompare(b.id)); }
  function connectionLabel() { return {connecting:'Awaiting Orca',live:'Live sync',stale:'Last observed',offline:'Source unavailable'}[connection]; }
  function standbyLabel() { return connection==='live'?'No active tasks':connectionLabel(); }
  function carouselLabel() {
    if(selectedIds.length<2)return 'FOCUS';
    return `AUTO ${Math.max(0,selectedIds.indexOf(focusId))+1}/${selectedIds.length} · ${Math.max(0,Math.ceil((ROTATION_MS-(Date.now()-lastSwitch))/1000))}s`;
  }
  function age(value) {
    if (!value) return 'No observation yet';
    const seconds = Math.max(0,Math.floor((Date.now()-value)/1000));
    if (seconds < 3) return 'Updated now';
    if (seconds < 60) return `Updated ${seconds}s ago`;
    if (seconds < 3600) return `Updated ${Math.floor(seconds/60)}m ago`;
    return `Updated ${Math.floor(seconds/3600)}h ago`;
  }
  function node(tag, cls, value) {
    const el = document.createElement(tag); if (cls) el.className = cls; if (value != null) el.textContent = value; return el;
  }
  function set(id, value) { const el = $(id); if (el) el.textContent = value; }
  function replace(id, children) { const el = $(id); if (el) el.replaceChildren(...children); }
  function normalize(payload) {
    if (!payload || payload.version !== 1) return null;
    return {version:1,connected:payload.connected === true,observedAt:time(payload.observedAt),
      activeWorkspaceId:payload.activeWorkspaceId == null ? null : string(payload.activeWorkspaceId),error:string(payload.error),
      workspaces:(Array.isArray(payload.workspaces)?payload.workspaces:[]).filter(w=>w && w.id != null).map(w=>({
        id:string(w.id),name:string(w.name).trim()||'Untitled workspace',project:string(w.project),path:string(w.path),branch:string(w.branch),
        status:string(w.status),isActive:w.isActive === true,lastActivityAt:time(w.lastActivityAt),
        agents:(Array.isArray(w.agents)?w.agents:[]).filter(a=>a && a.id != null).map(a=>({
          id:string(a.id),parentId:a.parentId == null ? null : string(a.parentId),type:string(a.type),title:string(a.title),
          modelId:typeof a.modelId==='string'?a.modelId.trim():null,
          modelDisplayName:typeof a.modelDisplayName==='string'?a.modelDisplayName.trim():null,
          needsInput:a.needsInput===true,
          attentionReason:['approval','question'].includes(a.attentionReason)?a.attentionReason:null,
          state:string(a.state),outcome:string(a.outcome),interrupted:a.interrupted === true,toolName:string(a.toolName),
          updatedAt:time(a.updatedAt),stateStartedAt:time(a.stateStartedAt),hasLivePty:a.hasLivePty === true,
          activity:a.activity && typeof a.activity === 'object' ? {unread:a.activity.unread === true,status:string(a.activity.status)} : null
        }))
      }))};
  }
  function record(next) {
    const current = new Map();
    for (const w of next.workspaces) {
      for (const a of w.agents) {
        const key = `${w.id}\u0000${a.id}`, previous = priorAgents.get(key); current.set(key,a);
        if (!initialized || !previous) continue;
        let message = null, changedAt = a.updatedAt;
        if(needsReply(a)!==needsReply(previous)){
          message=needsReply(a)?'Awaiting reply':'Reply request cleared';changedAt=next.observedAt;
        } else if (a.state !== previous.state || state(a) !== state(previous)) {
          message = `${INFO[state(previous)][0]} → ${INFO[state(a)][0]}`; changedAt = a.stateStartedAt || a.updatedAt;
        } else if (a.toolName && a.toolName !== previous.toolName) message = tool(a)?`Tool / ${tool(a)}`:'Tool changed';
        else if (a.activity?.unread === true && previous.activity?.unread !== true) message = 'New update';
        if (message) events.push({at:changedAt && changedAt <= next.observedAt ? changedAt : next.observedAt,
          workspaceId:w.id,workspace:w.name,title:title(a),message,state:needsReply(a)?'waiting':state(a),needsInput:needsReply(a),agentId:a.id});
      }
      const history = histories.get(w.id)||[];
      if (!history.length || next.observedAt > history[history.length-1].at) history.push({at:next.observedAt,...tally(w.agents)});
      histories.set(w.id,history.slice(-180));
    }
    priorAgents = current; initialized = true; events = events.slice(-80);
    for (const id of histories.keys()) if (!next.workspaces.some(w=>w.id===id)) histories.delete(id);
  }
  function chooseFocus() {
    const active=activeWorkspaces(),defaults=active.length===0,previousIds=selectedIds;
    const attentionIds=new Set(active.filter(w=>attentionCount(w)>0).map(w=>w.id));
    const recency=w=>Math.max(w.lastActivityAt,...w.agents.map(a=>a.updatedAt),0);
    const ranked=defaults?DEFAULT_SCENES:active.sort((a,b)=>Number(attentionIds.has(b.id))-Number(attentionIds.has(a.id))||recency(b)-recency(a)||a.id.localeCompare(b.id)).slice(0,4);
    const keep=new Set(ranked.map(w=>w.id));
    selectedIds=[...selectedIds.filter(id=>keep.has(id)),...ranked.map(w=>w.id).filter(id=>!selectedIds.includes(id))];
    const nextMode=defaults?'standby':selectedIds.length===1?'focus':'carousel';
    const rosterChanged=previousIds.length!==selectedIds.length||selectedIds.some((id,i)=>id!==previousIds[i]);
    // Give the four displayed workspaces distinct hues, retaining existing
    // assignments when the roster changes rather than recoloring every poll.
    const used=new Set();
    for(const id of selectedIds){
      let index=workspaceColors.get(id) ?? hash(id)%PALETTE.length;
      while(used.has(index))index=(index+1)%PALETTE.length;
      workspaceColors.set(id,index);used.add(index);
    }
    // A newly pending workspace gets one immediate visit. Remember all current
    // pending workspaces so repeated snapshots cannot keep stealing focus.
    const newlyPending=ranked.find(w=>attentionIds.has(w.id)&&!previousAttentionWorkspaces.has(w.id));
    const next=newlyPending?.id||(selectedIds.includes(focusId)?focusId:selectedIds[0]||null);
    if(newlyPending||next!==focusId||nextMode!==selectionMode||rosterChanged)lastSwitch=Date.now();
    previousAttentionWorkspaces=attentionIds;
    selectionMode=nextMode;
    setFocus(next);
  }
  function setFocus(id) {
    focus=allWorkspaces().find(w=>w.id===id)||null;
    focusId=focus?.id||null;
    const paletteIndex=focusId?(workspaceColors.get(focusId)??hash(focusId)%PALETTE.length):-1;
    targetPalette(focusId?colorFor(focusId):[180,180,180],paletteIndex===0);
    refreshAttention();
  }
  function refreshAttention() {
    const count=status()==='live'&&!focus?.isDefault?attentionCount(focus):0;
    sceneAttention.count=count;sceneAttention.active=count>0;sceneAttention.level=count>0?1:0;
  }
  function advanceCarousel(){
    if(selectedIds.length<2)return false;
    const elapsed=Date.now()-lastSwitch;
    if(elapsed<ROTATION_MS)return false;
    const steps=Math.floor(elapsed/ROTATION_MS);lastSwitch+=steps*ROTATION_MS;
    const index=Math.max(0,selectedIds.indexOf(focusId));setFocus(selectedIds[(index+steps)%selectedIds.length]);
    chooseProfile();uiDirty=true;revision++;window.haloSceneRevision=revision;return true;
  }
  function chooseProfile() {
    const next=connection==='live'&&(focus?.agents||[]).some(a=>state(a)==='working')?'working':'idle';
    if(next!==profileKey){profileKey=next;profileFrom={...profile};profileTarget={...PROFILES[next]};profileStarted=performance.now();activityFrom=activity;activityTarget=next==='working'?1:0;}
  }
  function refreshConnection() {
    const next=status();
    if(next===connection)return false;
    connection=next;chooseFocus();chooseProfile();uiDirty=true;revision++;window.haloSceneRevision=revision;
    return true;
  }
  window.haloReceiveOrcaState = function(payload) {
    if (typeof payload === 'string') { try { payload=JSON.parse(payload); } catch (_) { return false; } }
    const next=normalize(payload); if (!next || (snapshot && next.observedAt && next.observedAt<snapshot.observedAt)) return false;
    if (next.connected) { record(next); lastGood=next; }
    snapshot=next; connection=status(); chooseFocus(); chooseProfile();
    const nextSignature=JSON.stringify([focusId,connection,selectedWorkspaces().map(w=>[w.id,w.name,w.agents.map(a=>[a.id,a.parentId,a.type,a.modelId,a.modelDisplayName,a.needsInput,a.attentionReason,a.title,a.state,a.outcome,a.interrupted,a.toolName,a.activity?.unread])])]);
    if (nextSignature !== signature) { signature=nextSignature; revision++; window.haloSceneRevision=revision; }
    uiDirty=true; if (booted && !document.hidden && !window.__wpPaused) renderDOM();
    return true;
  };

  function renderDOM() {
    if (!booted) return;
    refreshConnection();document.documentElement.dataset.orcaConnection=connection;
    const defaults=usingDefaults(),workspaces=selectedWorkspaces(),total=tally(allAgents()),local=tally(focus?.agents||[]);
    document.documentElement.dataset.orcaDefault=String(defaults);
    const h1=document.querySelector('.brand h1'), subtitle=document.querySelector('.brand p');
    const headline=headlineAgent(),model=modelName(headline),client=headline?english(headline.type).toUpperCase():'';
    const heading=`${model||client||'AGENT'} / ${focus?.name||'ORCA'}`;
    if(h1){h1.textContent=heading;h1.title=heading;h1.setAttribute('aria-label',heading);}
    if(subtitle){
      const identity=headline?[model?'':client?`${client} CLIENT`:'',model?'':'Model unavailable',headline.parentId?'SUB-AGENT':'MAIN AGENT',agentStatus(headline)]:[];
      const detail=defaults?['DEFAULT SCENE',standbyLabel(),connection==='live'?connectionLabel():'','HALOFLUX by Ryder191'].filter(Boolean).join(' · '):
        [...identity,focus?.project,english(focus?.branch),connectionLabel(),'HALOFLUX by Ryder191'].filter(Boolean).join(' · ');
      subtitle.textContent=detail;subtitle.title=detail;
    }
    const values=[workspaces.length,total.total,total.working,total.waiting,total.ended];
    const labels=[defaults?'SCENES':'WORKSPACES','AGENTS','WORKING','WAITING','ENDED'];
    document.querySelectorAll('.kpi').forEach((el,i)=>{
      const k=el.querySelector('.k'),v=el.querySelector('.v'),bar=el.querySelector('.seg i');
      if(k)k.textContent=labels[i]; if(v)v.textContent=values[i];
      if(bar)bar.style.width=`${i<2?(values[i]?100:0):total.total?values[i]/total.total*100:0}%`;
    });
    set('chkK',focus?.name||'ORCA');set('chkV',defaults?standbyLabel():local.attention?`${local.attention} AWAITING REPLY · ${local.working} WORKING`:`${local.working} WORKING · ${local.waiting} WAITING`);
    const chk=$('chk'); if(chk)chk.style.opacity='1';
    const mode=defaults?'STANDBY':connection!=='live'?'STALE':local.attention?'AWAITING REPLY':local.working?'PROCESSING':'STANDBY';
    set('stBig',defaults?'STANDBY · DEFAULT SCENE':local.attention?`${mode} · ${local.attention} AGENT${local.attention===1?'':'S'}`:`${mode} · ${local.main} MAIN · ${local.child} SUB`);
    const sm=document.querySelector('.status .sm');
    const observation=defaults&&connection==='live'?'No active tasks':age(lastGood?.observedAt||snapshot?.observedAt);
    if(sm)sm.textContent=`${connectionLabel()} · ${observation} · ${carouselLabel()}`;
    const focusedEvents=events.filter(e=>!focus||e.workspaceId===focus.id).slice(-14);
    replace('feed',focusedEvents.length?focusedEvents.map(e=>{
      const row=node('div'),clock=e.at?new Date(e.at).toLocaleTimeString('en-GB',{hour12:false,hour:'2-digit',minute:'2-digit'}):'--';
      row.append(node('span','n',clock),node('span',`vb orca-${e.state}`,e.needsInput?'REPLY':INFO[e.state][1]),document.createTextNode(`${e.title} · ${e.message}`)); return row;
    }):[node('div','orca-muted',defaults?`${standbyLabel()} · default scene`:connection==='live'?'Awaiting the next state change':'No new observations')]);
    const agents=sortedAgents();
    replace('code',agents.length?agents.slice(0,14).map(a=>{
      const row=node('div'); row.append(node('span','ln',a.parentId?'SUB':'MAIN'),node('span',`fn orca-${needsReply(a)?'waiting':state(a)}`,needsReply(a)?agentStatus(a):tool(a)||agentStatus(a)),node('span','op',` · ${title(a)}`)); return row;
    }):[node('div','orca-muted',defaults?standbyLabel():focus?'No agents in this workspace':'Awaiting agent sessions')]);
    const routes=[];
    for(const v of [defaults?'SCENE':'WORKSPACE','WORK','WAIT','END'])routes.push(node('span','h',v));
    const ordered=workspaces;
    for(const w of ordered.slice(0,12)){
      const c=tally(w.agents); routes.push(node('span',`nm${w.id===focusId?' current':''}`,w.name));
      for(const key of ['working','waiting','ended']){const cell=node('span');cell.append(node('span',`chip ${c[key]?'done':''}`,c[key]));routes.push(cell);}
    }
    if(!ordered.length)routes.push(node('span','nm','No workspaces')); replace('routes',routes);
    replace('agents',agents.length?agents.slice(0,28).map((a,i)=>{
      const row=node('div','ag'),cells=node('span','cells'),dot=node('i');
      dot.style.background=needsReply(a)?'#c9bd9e':state(a)==='working'?'var(--orca-accent)':state(a)==='waiting'?'#c9bd9e':'#69707b'; cells.append(dot);
      row.append(node('span','id',a.parentId?'>':String(i+1).padStart(2,'0')),node('span','rl',type(a)),cells,node('span',`st orca-${needsReply(a)?'waiting':state(a)}`,agentStatus(a)));
      row.title=`${title(a)} · ${a.parentId?'Sub-agent':'Main agent'}${a.hasLivePty?' · Terminal online':''}`;return row;
    }):[node('div','orca-muted',defaults?standbyLabel():'No agents')]);
    const buttons=document.querySelectorAll('#advBtns span');
    ['WORK','REPLY','STANDBY'].forEach((label,i)=>{if(buttons[i]){buttons[i].textContent=label;buttons[i].classList.toggle('on',defaults?i===2:connection==='live'&&[!local.attention&&local.working>0,local.attention>0,!local.attention&&!local.working&&local.total>0][i]);}});
    const fieldHeading=panelRefs[1]?.querySelector('h3');if(fieldHeading)fieldHeading.textContent=`PARTICLE FIELD / ${local.attention?'REPLY':connection==='live'&&local.working?'WORKING':'STANDBY'}`;
    const routeHeading=panelRefs[4]?.querySelector('h3');if(routeHeading)routeHeading.textContent=defaults?'DEFAULT / SCENES':'WORKSPACE / ROUTES';
    const countHeading=panelRefs[7]?.querySelector('h3');if(countHeading)countHeading.textContent=defaults?'DEFAULT / STANDBY':'WORKSPACE / AGENT COUNTS';
    const captions=defaults?{1:focus?.note||standbyLabel(),3:`Standby · ${standbyLabel()}`,4:`${workspaces.length} default scenes · ${focus?.name||'standby'}`,
      5:`${standbyLabel()} · standby`,6:'Default scene · no task data shown',7:'Default scenes · no agent counts'}:
      {1:local.attention?`${local.attention} agent${local.attention===1?'':'s'} awaiting reply`:'Visual activity follows the selected workspace',3:`${local.total} agents · one dot per observed session`,4:`${workspaces.length} selected workspaces · ${focus?.name||'none selected'}`,5:'Samples recorded from received state',6:`${local.main} main / ${local.child} sub · ${local.unread} unread updates`,7:'Observed agent counts per workspace'};
    for(const [i,value] of Object.entries(captions)){const cap=panelRefs[i]?.querySelector('.cap');if(cap)cap.textContent=value;}
    uiDirty=false; lastUI=performance.now();
  }
  window.haloSceneTick=function(_dt){
    if(!booted||document.hidden||window.__wpPaused)return;
    const now=performance.now();refreshConnection();
    advanceCarousel();
    refreshAttention();
    updatePalette();
    const t=Math.max(0,Math.min(1,(now-profileStarted)/1200)),ease=t*t*(3-2*t);
    activity=activityFrom+(activityTarget-activityFrom)*ease;window.haloSceneActivity=activity;
    for(const k of Object.keys(profileTarget)){
      const next=profileFrom[k]+(profileTarget[k]-profileFrom[k])*ease;
      if(Math.abs(next-profile[k])>.00001){profile[k]=next;if(typeof window.setParam==='function')window.setParam(k,next,true);}
    }
    if(uiDirty||now-lastUI>1000)renderDOM();
  };

  function canvasInfo(canvas){
    if(!canvas)return null;const x=canvas.x||canvas.getContext('2d'),r=canvas.getBoundingClientRect(),w=canvas.w||r.width,h=canvas.h||r.height;
    if(!x||w<2||h<2)return null;return{x,w,h};
  }
  function drawText(x,value,px,py,color='#9a9ea7',size=7,weight=500){x.fillStyle=color;x.font=`${weight} ${size}px ${FONT}`;x.textBaseline='top';x.textAlign='left';x.fillText(string(value),px,py);}
  function clipped(x,value,max){let v=string(value);while(v&&x.measureText(v).width>max)v=v.slice(0,-1);return v===string(value)?v:`${v.slice(0,-1)}…`;}
  function stateColor(s,alpha=1){return s==='working'?rgba(accent,alpha):s==='waiting'?`rgba(205,189,155,${alpha})`:s==='error'?`rgba(220,160,174,${alpha})`:`rgba(166,175,189,${alpha})`;}
  function guide(x,y,w){x.strokeStyle='#25282e';x.lineWidth=.6;x.beginPath();x.moveTo(0,y);x.lineTo(w,y);x.stroke();}
  function drawStatePanel(x,w,h){
    const agents=focus?.agents||[],c=tally(agents),keys=['working','waiting','idle','ended','unknown'];
    const names=['WORKING','WAITING','IDLE','ENDED','UNKNOWN'],max=Math.max(1,...keys.map(k=>c[k]));
    const row=Math.min(13,Math.max(7,(h-24)/5)),left=49,right=24,bw=Math.max(1,w-left-right);
    keys.forEach((key,i)=>{
      const y=i*row;drawText(x,names[i],0,y,'#757b85',6.5);drawText(x,c[key],w-right+5,y,stateColor(key),7,700);
      x.fillStyle='#242830';x.fillRect(left,y+2,bw,2);
      x.fillStyle=stateColor(key,.8);x.fillRect(left,y+2,bw*c[key]/max,2);
      for(let j=0;j<Math.min(c[key],Math.floor(bw/3));j++){x.fillStyle=stateColor(key,.55);x.fillRect(left+j*3,y+6,1.4,1.2);}
    });
    const y0=keys.length*row+4,cols=Math.max(1,Math.floor(w/4)),capacity=cols*Math.max(0,Math.floor((h-y0)/4));
    agents.slice(0,capacity).forEach((a,i)=>{x.fillStyle=stateColor(state(a),.75);x.fillRect((i%cols)*4,y0+Math.floor(i/cols)*4,2.4,2.4);});
    if(!agents.length)drawText(x,usingDefaults()?standbyLabel().toUpperCase():'NO AGENTS',0,Math.min(h-8,y0),'#555b65',6.5);
  }
  function drawHistoryPanel(x,w,h){
    const history=(histories.get(focusId)||[]).slice(-90),keys=['working','waiting','ended'],names=['WORK','WAIT','END'];
    if(!history.length){drawText(x,usingDefaults()?standbyLabel().toUpperCase():'WAITING FOR OBSERVATIONS',0,4,'#6b6f78',7);return;}
    const left=35,right=20,row=h/3,first=history[0].at,last=history[history.length-1].at;
    keys.forEach((key,i)=>{
      const top=i*row+2,baseline=(i+1)*row-4,plotH=Math.max(2,row-10),max=Math.max(1,...history.map(p=>p[key]));
      drawText(x,names[i],0,top,'#777d87',6.5);drawText(x,history[history.length-1][key],w-right+4,top,stateColor(key),7,700);
      x.strokeStyle='#25282e';x.lineWidth=.6;x.beginPath();x.moveTo(left,baseline);x.lineTo(w-right,baseline);x.stroke();
      x.strokeStyle=stateColor(key,.82);x.lineWidth=.8;x.beginPath();let previous=null;
      history.forEach(point=>{
        const px=left+(last>first?(point.at-first)/(last-first):0)*Math.max(1,w-left-right),py=baseline-point[key]/max*plotH;
        if(!previous||point.at-previous.at>20000)x.moveTo(px,py);else{x.lineTo(px,previous.y);x.lineTo(px,py);}previous={at:point.at,y:py};
      });x.stroke();
      const point=history[history.length-1],px=history.length>1?w-right:left,py=baseline-point[key]/max*plotH;
      x.fillStyle=stateColor(key);x.fillRect(px-1,py-1,2,2);
    });
  }
  function drawWorkspacePanel(x,w,h){
    const workspaces=selectedWorkspaces();
    if(!workspaces.length){drawText(x,'NO WORKSPACES',0,4,'#6b6f78',7);return;}
    const row=11,shown=workspaces.slice(0,Math.max(1,Math.floor((h-12)/row))),labelW=Math.min(75,w*.3),countW=64,barW=Math.max(1,w-labelW-countW-7);
    const max=Math.max(1,...workspaces.map(ws=>ws.agents.length));
    const defaults=usingDefaults();
    drawText(x,defaults?'SCENE':'WORKSPACE',0,0,'#6b6f78',6);drawText(x,defaults?'STATUS':'W / Q / I / E',w-countW,0,'#6b6f78',6);
    shown.forEach((ws,i)=>{
      const y=12+i*row,c=tally(ws.agents);x.font=`600 6.5px ${FONT}`;drawText(x,clipped(x,ws.name,labelW-4),0,y,ws.id===focusId?rgba(accent):'#9a9ea7',6.5);
      x.fillStyle='#22262d';x.fillRect(labelW,y+2,barW,3);let bx=labelW;
      for(const key of ['working','waiting','idle','ended','unknown']){const span=barW*c[key]/max;x.fillStyle=stateColor(key,.8);x.fillRect(bx,y+2,span,3);bx+=span;}
      drawText(x,defaults?'STANDBY':`${c.working}/${c.waiting}/${c.idle}/${c.ended}`,w-countW,y,'#bfc4cd',6.5);
    });
  }
  window.haloDrawMetricPanel=function(kind,canvas,_dt){
    if(!booted)return false;const info=canvasInfo(canvas);if(!info)return true;
    const {x,w,h}=info;x.save();x.clearRect(0,0,w,h);x.textAlign='left';x.textBaseline='top';
    const key=string(kind).toLowerCase();
    if(['diff','state','states','cdiff'].includes(key))drawStatePanel(x,w,h);
    else if(['val','history','cval'].includes(key))drawHistoryPanel(x,w,h);
    else if(['idx','workspace','workspaces','cidx'].includes(key))drawWorkspacePanel(x,w,h);
    else{x.restore();return false;}x.restore();return true;
  };

  function slotText(x,value,px,py,width,color,size=3.5,weight=500){x.font=`${weight} ${size}px ${FONT}`;drawText(x,clipped(x,value,Math.max(1,width)),px,py,color,size,weight);}
  function slotDecoration(x,x0,x1,y0,y1,seed,mask=null){
    // Fixed typographic texture, never presented as a measurement or progress.
    for(let px=x0,col=0;px<x1-1;px+=2.8,col++)for(let py=y0,row=0;py<y1-1;py+=2.6,row++){
      const bits=hash(`${seed}:${col}:${row}`);if((bits&7)>4)continue;
      const alpha=.18+((bits>>>4)&7)*.065;
      if(mask&&bits%11===0){mask.fillStyle=`rgba(255,255,255,${alpha})`;mask.fillRect(px,py,1.25,1.3);}
      else{x.fillStyle=`rgba(225,228,236,${alpha})`;x.fillRect(px,py,1.25,1.3);}
    }
  }
  function slotHistory(x,x0,x1,y0,y1,key){
    const history=(histories.get(focusId)||[]).slice(-36);if(!history.length||y1-y0<2)return;
    const max=Math.max(1,...history.map(p=>p[key])),first=history[0].at,last=history[history.length-1].at;
    x.strokeStyle='rgba(225,230,240,.16)';x.lineWidth=.4;x.beginPath();x.moveTo(x0,y1);x.lineTo(x1,y1);x.stroke();
    x.strokeStyle='rgba(225,230,240,.83)';x.lineWidth=.5;x.beginPath();let prior=null;
    history.forEach(p=>{const xx=x0+(last>first?(p.at-first)/(last-first):0)*(x1-x0),yy=y1-p[key]/max*(y1-y0);
      if(!prior||p.at-prior.at>20000)x.moveTo(xx,yy);else{x.lineTo(xx,prior.y);x.lineTo(xx,yy);}prior={at:p.at,y:yy};});x.stroke();
  }
  window.haloRenderAgentSlot=function(s,g){
    if(!booted||!g||!(g.band>0)||!(g.h>0)||!(g.rasterScale>0))return false;
    const {band,h,rasterScale,dz0,dz1,oz0,oz1}=g;
    const width=Math.ceil(band*rasterScale),height=Math.ceil((h+2/1.25)*rasterScale);
    const layer=()=>{
      const canvas=document.createElement('canvas');canvas.width=width;canvas.height=height;
      const context=canvas.getContext('2d');context.scale(rasterScale,rasterScale);context.textBaseline='top';
      return {canvas,context};
    };
    // Cache neutral text separately from monochrome masks. The original ring
    // compositor tints these masks every frame, so even standby slots share
    // the current workspace palette without regenerating their textures.
    const base=layer(),primary=layer(),soft=layer(),c=base.canvas,x=base.context,m=primary.context,n=soft.context;
    const ordered=[...(focus?.agents||[])].sort((a,b)=>a.id.localeCompare(b.id));
    const index=Math.floor((((s.a||0)%(Math.PI*2)+Math.PI*2)%(Math.PI*2))/(Math.PI*2)*Math.max(1,ordered.length));
    const a=ordered[index],seed=hash(`${focusId||'empty'}:${Math.round((s.a||0)*100000)}`),mode=seed%4;
    const bodyW=Math.max(1,dz1-dz0),counts=tally(focus?.agents||[]);
    for(const context of [x,m,n]){context.save();context.beginPath();context.rect(dz0,0,Math.max(1,dz1-dz0),h+1);context.clip();}
    const heading=a?`${type(a)} / ${a.parentId?'SUB':'MAIN'}`:usingDefaults()?'STANDBY':connection==='live'?'NO AGENTS':'ORCA / WAIT';
    slotText(m,heading,dz0,1,bodyW,'rgba(255,255,255,.94)',4.3,700);
    x.fillStyle='rgba(225,228,236,.28)';x.fillRect(dz0,6.6,bodyW,.45);
    let y=8;
    if(a){
      const lines=[`${agentStatus(a,true)} · ${title(a)}`,tool(a)?`TOOL ${tool(a)}`:`STATE ${agentStatus(a)}`,
        `WORK ${counts.working}  WAIT ${counts.waiting}  END ${counts.ended}`,focus?.name||''];
      const reserve=(mode===1||mode===2)&&h>29?Math.min(12,h*.28):0;
      for(let i=0;i<lines.length;i++){
        if(y>h-reserve-3.5)break;
        if(i===1&&tool(a)){
          const prefix='TOOL ';n.font=`500 3.5px ${FONT}`;const prefixWidth=n.measureText(prefix).width;
          slotText(n,prefix,dz0,y,bodyW,'rgba(255,255,255,.86)',3.5);
          if(bodyW>prefixWidth)slotText(x,tool(a),dz0+prefixWidth,y,bodyW-prefixWidth,'rgba(219,224,235,.78)',3.5);
        }else slotText(x,lines[i],dz0,y,bodyW,i===0?'rgba(235,238,244,.88)':'rgba(219,224,235,.68)',3.5);
        y+=4.8;
      }
      if(mode===1&&h-y>4)slotHistory(x,dz0,dz1,y+1,h-2,'working');
      else if(mode===2&&h-y>4){
        const max=Math.max(1,counts.working,counts.waiting,counts.idle,counts.ended),keys=['working','waiting','idle','ended'];
        const rh=Math.max(1.5,(h-y-1)/keys.length);
        keys.forEach((key,i)=>{x.fillStyle=`rgba(220,226,236,${.68-i*.08})`;x.fillRect(dz0,y+i*rh,(bodyW-1)*counts[key]/max,Math.min(1.2,rh-.3));});
      }else if(h-y>3)slotDecoration(x,dz0,dz1,y,h-1,seed);
    }else{
      slotText(x,usingDefaults()?standbyLabel():connectionLabel(),dz0,y,bodyW,'rgba(220,225,235,.65)',3.6);y+=5;
      slotText(x,focus?.name||'WAITING FOR ORCA',dz0,y,bodyW,'rgba(220,225,235,.5)',3.5);y+=5;
      if(h-y>3)slotDecoration(x,dz0,dz1,y,h-1,seed);
    }
    for(const context of [x,m,n])context.restore();
    const outerW=Math.max(0,oz1-oz0);
    if(outerW>2){
      slotText(n,a?agentStatus(a,true):usingDefaults()?'DEFAULT':'ORCA',oz0,1,outerW,'rgba(255,255,255,.86)',3.1,600);
      if(a&&h>12)slotText(x,shortID(a),oz0,8,outerW,'rgba(225,228,236,.5)',3.1);
      slotDecoration(x,oz0,oz1,Math.min(h,15),h-1,seed+1,n);
    }
    for(let px=dz0,i=0;px<oz1;px+=3.4,i++){
      const context=i%5===0?m:x;context.fillStyle=i%5===0?'rgba(255,255,255,.48)':'rgba(220,224,232,.4)';context.fillRect(px,h+.3,1.1,1.1);
    }
    s.c=c;s.haloAccentMask=primary.canvas;s.haloSecondaryMask=soft.canvas;s.haloSceneRevision=revision;return true;
  };
  window.haloSetPaused=function(paused){
    const wasPaused=!!window.__wpPaused;window.__wpPaused=!!paused;
    if(!paused){
      // Resume with a full dwell interval instead of skipping scenes to catch
      // up with time spent locked or asleep. Repeated unpaused notifications
      // must not keep resetting an otherwise active carousel.
      if(wasPaused)lastSwitch=Date.now();
      refreshConnection();uiDirty=true;lastUI=0;
    }
  };
  window.haloDebugState=function(){refreshConnection();refreshAttention();const defaults=usingDefaults(),headline=headlineAgent();return{page:'original-orca-scene',connection,observedAt:lastGood?.observedAt||snapshot?.observedAt||null,
    defaultScenes:defaults,selectionMode,activeWorkspaceCount:activeWorkspaces().length,carousel:carouselLabel(),sceneCount:selectedIds.length,focusSceneId:focusId,selectedSceneIds:[...selectedIds],rotationMs:ROTATION_MS,
    activeWorkspaceId:snapshot?.activeWorkspaceId||null,focusWorkspaceId:defaults?null:focusId,selectedWorkspaceIds:defaults?[]:[...selectedIds],workspaceCount:defaults?0:selectedIds.length,availableWorkspaceCount:observedWorkspaces().length,
    headlineAgentId:headline?.id||null,headlineModelId:headline?.modelId||null,headlineModelDisplayName:modelName(headline)||null,headlineClientType:headline?.type||null,
    agents:tally(focus?.agents||[]),sceneRevision:revision,profile:profileKey,activity,attention:{...sceneAttention},
    palette:{accent:[...accent],secondary:[...secondary],purpleWeight:scenePalette.purpleWeight},paletteTarget:[...paletteTarget],
    workspacePaletteIndices:selectedIds.map(id=>({id,index:workspaceColors.get(id)})),
    paused:!!window.__wpPaused,visibility:document.visibilityState};};
  window.haloSceneRevision=revision;
  window.haloSceneActivity=0;
  window.haloScenePalette=scenePalette;
  window.haloSceneAttention=sceneAttention;
  window.haloOrcaReady=true;
  function boot(){
    if(booted)return;booted=true;document.documentElement.dataset.orcaScene='true';panelRefs=[...document.querySelectorAll('.panels > .p')];
    const names=['AGENT / STATE FEED','PARTICLE FIELD / LIVE VISUAL','AGENT / TOOL ACTIVITY','AGENT / STATE DISTRIBUTION',
      'WORKSPACE / ROUTES','STATE / OBSERVED HISTORY','MAIN / SUB AGENTS','WORKSPACE / AGENT COUNTS'];
    panelRefs.forEach((p,i)=>{const h=p.querySelector('h3');if(h)h.textContent=names[i]||h.textContent;});
    connection=status();chooseFocus();chooseProfile();renderDOM();if(window.haloInitialOrcaState)window.haloReceiveOrcaState(window.haloInitialOrcaState);
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot,{once:true});else boot();
})();
