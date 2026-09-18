// Copied from hypertask-analytics/src/lib/factoryStatus.mjs. Keep this eval
// independent so a toolkit fixture proves it satisfies the deployed reader.
const validProject = value => typeof value === 'string' && /^[a-z][a-z0-9-]{0,62}$/.test(value);
const factoryStatusKey = project => {if (!validProject(project)) throw new Error('Invalid project');return `ops/factory-status/${project}.json`;};
const number = n => typeof n === 'number' && Number.isFinite(n) && n >= 0 ? n : null;
const integer = n => Number.isSafeInteger(n) && n > 0 ? n : null;
const id = s => typeof s === 'string' && /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,239}$/.test(s) ? s : null;
const key = s => typeof s === 'string' && /^[A-Z][A-Z0-9]{0,15}-[1-9][0-9]*$/.test(s) ? s : null;
const member = (value, choices, fallback = 'unknown') => choices.includes(value) ? value : fallback;
const list = (value, max) => {if (!Array.isArray(value) || value.length > max) throw new Error('Invalid snapshot list');return value;};
const phases = ['working','waiting','done','idle','unknown','blocked','fixing','qa','claiming','reporting','chat','recovering'];
const states = ['open','unresolved','dispatched','verifying','awaiting_decision','resolved'];
const ACTION_SUMMARIES = Object.freeze({launch:'Dispatch recovery.',restart:'Restart the recovery session.',follow_up:'Execute the scheduled repair.',wait:'Await independent verification.',wait_for_manager:'Await an available Manager.',wait_for_worker:'Await the current worker.',wait_for_confirmation:'Await another complete detector observation.',escalate:'An authorized decision is required.',stop_and_escalate:'Stop recovery and request an authorized decision.',review_due:'Review the overdue recovery action.',observe:'Observe the recorded incident.',unknown:'Recovery action is unavailable.',none:'No recovery action is pending.'});
const actionKind = value => Object.hasOwn(ACTION_SUMMARIES, value) ? value : 'unknown';
function ticket(input) {
  if (input === null || input === undefined) return null;
  const board = integer(input.board_id), identity = integer(input.ticket_id), ticketKey = key(input.ticket_key), title = input.title;
  if (!board || !identity || !ticketKey || typeof title !== 'string' || !title.trim() || title.length > 10000 || /[\x00-\x1f\x7f]/.test(title)) throw new Error('Invalid ticket reference');
  const url = `https://app.hypertask.ai/detail/project-${board}/${ticketKey.split('-').at(-1)}`;
  if (input.url !== url) throw new Error('Invalid ticket URL');
  return {board_id:board,ticket_id:identity,ticket_key:ticketKey,title,url};
}
function source(input, allowed) {return {checked_at:number(input?.checked_at),state:member(input?.state,allowed),complete:input?.complete===true};}
function progress(input, role, generation) {
  if (role !== 'dev' || input?.state !== 'observed') return {state:'unknown'};
  const names=['observation_at','clock_at','active_seconds','active_without_progress_seconds','active_without_merge_ready_seconds','progress_episode'];
  const counts=Object.fromEntries(names.map(n=>[n,number(input[n])]));
  if (Object.values(counts).some(v=>v===null) || counts.clock_at!==generation || counts.observation_at>generation || counts.active_without_progress_seconds>counts.active_seconds || counts.active_without_merge_ready_seconds>counts.active_seconds || !Number.isSafeInteger(counts.progress_episode) || !['working','waiting','done'].includes(input.phase) || typeof input.merge_ready!=='boolean' || input.clock_paused !== (input.phase!=='working')) return {state:'unknown'};
  const e=input.latest_evidence;let receipt=null;
  if (e) {const at=number(e.observed_at),revision=id(e.revision)||(Number.isSafeInteger(e.revision)?e.revision:null);if(!id(e.id)||!['acceptance','necessary_job_progress'].includes(e.kind)||at===null||at>generation||revision===null||at!==input.last_verified_at)return {state:'unknown'};receipt={id:e.id,kind:e.kind,observed_at:at,revision};}
  else if (input.last_verified_at!==null || counts.progress_episode!==0) return {state:'unknown'};
  return {state:'observed',...counts,phase:input.phase,clock_paused:input.clock_paused,merge_ready:input.merge_ready,last_verified_at:receipt?.observed_at??null,latest_evidence:receipt};
}
function incident(input, slugs, generation) {
  if (!id(input?.id)) throw new Error('Invalid incident');
  let state=member(input.state,states),resolution='unverified',verification=null;const episode=number(input.episode),resolved=number(input.resolved_at),v=input.verification;
  if(state==='resolved'&&input.resolution_kind==='independently_verified'&&v&&key(v.ticket)&&integer(v.comment_id)&&id(v.verifier_agent_id)&&id(v.run_id)&&number(v.verified_at)!==null&&episode!==null&&resolved!==null&&v.verified_at>=episode&&resolved>=v.verified_at&&resolved<=generation){verification={ticket:v.ticket,comment_id:v.comment_id,verifier_agent_id:v.verifier_agent_id,run_id:v.run_id,verified_at:v.verified_at};resolution='independently_verified';}
  else if(state==='resolved'&&input.resolution_kind==='transient_cleared'&&!v&&episode!==null&&resolved!==null&&resolved>=episode&&resolved<=generation)resolution='transient_cleared';else if(state==='resolved')state='unresolved';
  const kind=['resolved','unknown'].includes(state)?'none':actionKind(input.action_kind);
  return {id:input.id,episode,state,current:input.current===true,affected_agent_slug:slugs.has(input.affected_agent_slug)?input.affected_agent_slug:null,ticket_key:key(input.ticket_key),owner:slugs.has(input.owner)?input.owner:null,action_kind:kind,action_summary:ACTION_SUMMARIES[kind],detected_at:number(input.detected_at),last_seen_at:number(input.last_seen_at),next_deadline:state==='unknown'?null:number(input.next_deadline),attention_required:member(input.attention_required,['escalate','stop_and_escalate','review_due'],null),coalesced_into:id(input.coalesced_into),related_incident_ids:list(input.related_incident_ids??[],100).map(id).filter(Boolean),resolved_at:resolution==='unverified'?null:resolved,resolution_kind:resolution,verification};
}
export function normalizeFactoryStatus(input, project='hypertask') {
  factoryStatusKey(project);
  if (!input || input.schema_version!==1 || input.project_key!==project || number(input.collected_at)===null || input.generation!==null&&number(input.generation)===null) throw new Error('Invalid factory snapshot');
  const agents=list(input.agents,100).map(a=>{if(!id(a?.agent_id)||!id(a.slug)||!['dev','qa','manager'].includes(a.role))throw new Error('Invalid factory agent');return {agent_id:a.agent_id,slug:a.slug,role:a.role,current_ticket:ticket(a.current_ticket),obligations:list(a.obligations??[],100).map(ticket).filter(Boolean),execution:{phase:member(a.execution?.phase,phases),observed_at:number(a.execution?.observed_at)},progress:progress(a.progress,a.role,input.generation),incident_ids:list(a.incident_ids??[],500).map(id).filter(Boolean)};});
  if(new Set(agents.map(a=>a.agent_id)).size!==agents.length||new Set(agents.map(a=>a.slug)).size!==agents.length)throw new Error('Duplicate factory identity');
  const slugs=new Set(agents.map(a=>a.slug));const incidents=list(input.incidents,500).map(i=>incident(i,slugs,input.generation));if(new Set(incidents.map(i=>i.id)).size!==incidents.length)throw new Error('Duplicate incident');
  return {schema_version:1,project_key:project,generation:input.generation,collected_at:input.collected_at,complete:input.complete===true,sources:{metadata:source(input.sources?.metadata,['observed']),progress:source(input.sources?.progress,['observed']),supervisor:source(input.sources?.supervisor,['observing','recovering','needs_attention'])},agents,incidents};
}
