#!/usr/bin/env bash
# AGTE-83: fixture confs and logs produce both accepted public status documents.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
FIXTURE="$HERE/fixtures/agent-status"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp -a "$FIXTURE/." "$TMP/"

"$ROOT/scripts/agent-status" collect \
  --config-dir "$TMP/confs" --state-dir "$TMP/state" --health "$TMP/health.json" \
  --now 1789728000 --output "$TMP/factory-status.json"

node --input-type=module - "$TMP" "$HERE/factory-status-normalizer.mjs" <<'NODE'
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {pathToFileURL} from 'node:url';
const root=process.argv[2];
const {normalizeFactoryStatus}=await import(pathToFileURL(process.argv[3]));
const snapshot=JSON.parse(fs.readFileSync(`${root}/factory-status.json`));
const normalized=normalizeFactoryStatus(snapshot);
assert.equal(normalized.complete,true);
assert.deepEqual(normalized.agents.map(agent=>[agent.slug,agent.role]),[
  ['product-bot','manager'],['tk-dev-1','dev'],['tk-qa-1','qa'],
]);
const dev=normalized.agents.find(agent=>agent.slug==='tk-dev-1');
assert.equal(dev.current_ticket.ticket_key,'AGTE-83');
assert.equal(dev.execution.phase,'working');
assert.equal(normalized.sources.supervisor.state,'needs_attention');
assert.equal(normalized.incidents.length,1);
assert.equal(normalized.incidents[0].affected_agent_slug,'tk-dev-1');

const metrics=JSON.parse(fs.readFileSync(`${root}/state/agent-status-metrics.json`));
assert.deepEqual(metrics.first_pass,{passed:1,total:2,rate:50,daily:metrics.first_pass.daily});
assert.equal(metrics.live_tickets.count,2);
assert.ok(metrics.cost_per_ticket.by_provider_percent.cursor>0);
const feed=JSON.parse(fs.readFileSync(`${root}/state/agent-feed.json`));
assert.equal(feed.kpi.liveTickets.today.agents,2);
assert.equal(feed.kpi.firstPass.rate,50);
assert.ok(feed.kpi.costPerLiveTicket.cursor>0);
assert.equal(feed.agents.length,3);
NODE

ROOT="$ROOT" TMP="$TMP" python3 <<'PY'
import importlib.machinery
import importlib.util
import io
import os
from pathlib import Path
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("agent_status", str(Path(os.environ["ROOT"]) / "scripts/agent-status"))
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
root = Path(os.environ["TMP"])
app = root / "app.env"
runtime = root / "runtime.env"
app.write_text('HYPERTASK_APP_BASE="https://hypertask.app"\nHYPERTASK_APP_CF_CLIENT_ID="test-client"\nHYPERTASK_APP_CF_CLIENT_SECRET="test-access"\n')
runtime.write_text('AGENT_RUNTIME_TOKEN="test-bearer"\n')
os.environ["AGENT_RUNTIME_CONFIG"] = str(runtime)
requests = []
class Response(io.BytesIO):
    status = 200
    def __enter__(self): return self
    def __exit__(self, *args): return False
class Opener:
    def open(self, request, timeout):
        requests.append((request, timeout))
        return Response(b'{"ok":true}')
with patch.object(module.urllib.request, "build_opener", return_value=Opener()):
    module.publish({"schema_version": 1}, app, "https://hypertask.app", "/api/factory-status", module.MAX_BYTES)
request, timeout = requests[0]
assert request.full_url == "https://hypertask.app/api/factory-status?project=hypertask"
assert request.get_header("Authorization") == "Bearer test-bearer"
assert request.get_header("Cf-access-client-id") == "test-client"
assert request.get_header("Cf-access-client-secret") == "test-access"
assert timeout == 15
PY

grep -qF 'OnUnitActiveSec=60s' "$ROOT/install.sh"
grep -qF 'ExecStart=$BIN/agent-status publish' "$ROOT/install.sh"
printf 'PASS %-36s %s\n' agent-status-snapshot 'fixtures normalize and publish current work, health, first-pass, and duration cost metrics'
