'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const worktree = path.resolve(__dirname, '..', '..', '..');
const workflow = fs.readFileSync(path.join(worktree, '.github', 'workflows', 'flcad-human-intervention.yml'), 'utf8');
const blocks = [...workflow.matchAll(/node <<'NODE'\r?\n([\s\S]*?)\r?\n\s*NODE/g)].map(match => match[1]);
assert.strictEqual(blocks.length, 2, 'workflow deve conter exatamente dois blocos Node');

const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'flcad-actions-node-'));
const validationScript = path.join(temp, 'validation.js');
const apiScript = path.join(temp, 'api.js');
fs.writeFileSync(validationScript, blocks[0]);
fs.writeFileSync(apiScript, blocks[1]);

const baseEnv = {
  ...process.env,
  INPUT_JSON: JSON.stringify({
    task_id: 'AB03F4-DEMO', event: 'USER_TEST_REQUIRED', state: 'WAITING_FOR_USER',
    reason: 'operator', priority: 'P1', action_requested: 'confirmar',
    technical_summary: 'mock', report_reference: 'reports/demo.json',
    report_version: '3', report_sha256: 'a'.repeat(64),
    report_url: 'https://github.com/Fabio-Licht/FLCAD-Platform/blob/automation/reports/reports/AB03F4-DEMO/v3/report.json',
    branch: 'automation/flcad-bridge', commit: 'a'.repeat(40),
    deduplication_id: 'AB03F4-DEMO-USER_TEST_REQUIRED', publish: false
  }),
  GITHUB_ACTOR: 'Fabio-Licht'
};

function run(script, env, wrapper = script) {
  return spawnSync(process.execPath, [wrapper], { encoding: 'utf8', env });
}

let result = run(validationScript, baseEnv);
assert.strictEqual(result.status, 0, `validação válida falhou: ${result.stderr}`);

const invalidEnv = { ...baseEnv, INPUT_JSON: JSON.stringify({ ...JSON.parse(baseEnv.INPUT_JSON), event: 'IMPLEMENTATION_COMPLETED' }) };
result = run(validationScript, invalidEnv);
assert.notStrictEqual(result.status, 0, 'evento não permitido deveria falhar');

const unauthorizedEnv = { ...baseEnv, GITHUB_ACTOR: 'other-user', INPUT_JSON: JSON.stringify({ ...JSON.parse(baseEnv.INPUT_JSON), publish: true }) };
result = run(validationScript, unauthorizedEnv);
assert.notStrictEqual(result.status, 0, 'ator não autorizado deveria falhar');

function runApi({ search, status = 200, publish = 'false', response = null, raw = undefined }) {
  const wrapper = path.join(temp, `wrapper-${Math.random().toString(16).slice(2)}.js`);
  const rawBody = raw === undefined ? null : JSON.stringify(raw);
  const mock = `
    const EventEmitter = require('events');
    const Module = require('module');
    const originalLoad = Module._load;
    let postCount = 0;
    const https = { request(options, callback) {
      const request = new EventEmitter();
      request.write = body => { request.body = body; };
      request.end = () => process.nextTick(() => {
        if (options.method === 'POST') postCount++;
        const response = new EventEmitter(); response.statusCode = ${status}; response.setEncoding = () => {};
        callback(response);
        const responseBody = options.method === 'POST' ? JSON.stringify({ html_url: 'https://github.com/mock/issue/1' }) : ${rawBody === null ? JSON.stringify(JSON.stringify(response === null ? (search === undefined ? {} : search) : response)) : rawBody};
        response.emit('data', responseBody); response.emit('end');
        process.nextTick(() => process.stdout.write('POST_COUNT=' + postCount + '\\n'));
      });
      return request;
    }};
    Module._load = (request, parent, isMain) => request === 'https' ? https : originalLoad(request, parent, isMain);
    require(${JSON.stringify(apiScript)});
  `;
  fs.writeFileSync(wrapper, mock);
  const env = { ...process.env, REPOSITORY: 'Fabio-Licht/FLCAD-Platform', GITHUB_TOKEN: 'MOCK_TOKEN_SHOULD_NOT_LEAK', PUBLISH: publish, TASK_ID: 'AB03F4-DEMO', EVENT: 'USER_TEST_REQUIRED', STATE: 'WAITING_FOR_USER', REASON: 'operator', PRIORITY: 'P1', ACTION_REQUESTED: 'confirmar', TECHNICAL_SUMMARY: 'mock', REPORT_REFERENCE: 'reports/demo.json', SOURCE_BRANCH: 'automation/flcad-bridge', SOURCE_COMMIT: 'a'.repeat(40), DEDUPLICATION_ID: 'AB03F4-DEMO-USER_TEST_REQUIRED' };
  const output = run(apiScript, env, wrapper);
  assert.ok(!`${output.stdout}${output.stderr}`.includes('MOCK_TOKEN_SHOULD_NOT_LEAK'), 'token vazou na saída');
  return output;
}

assert.strictEqual(runApi({ search: { total_count: 0 } }).status, 0, 'sem duplicata deve concluir');
let duplicate = runApi({ search: { total_count: 1 } });
assert.strictEqual(duplicate.status, 0, 'duplicata aberta deve concluir sem publicar');
assert.match(duplicate.stdout, /POST_COUNT=0/, 'duplicata aberta não pode criar Issue');
duplicate = runApi({ search: { total_count: 1 } });
assert.strictEqual(duplicate.status, 0, 'duplicata fechada deve concluir sem publicar');
assert.match(duplicate.stdout, /POST_COUNT=0/, 'duplicata fechada não pode criar Issue');
for (const status of [403, 500]) {
  const failed = runApi({ search: { total_count: 0 }, status });
  assert.notStrictEqual(failed.status, 0, `HTTP ${status} deve falhar`);
  assert.match(failed.stdout, /POST_COUNT=0/, `HTTP ${status} não pode criar Issue`);
}
assert.notStrictEqual(runApi({ search: {}, raw: '{malformed' }).status, 0, 'JSON malformado deve falhar');
assert.notStrictEqual(runApi({ search: { unexpected: true } }).status, 0, 'resposta inesperada deve falhar');
assert.strictEqual(runApi({ search: { total_count: 0 }, publish: 'false' }).status, 0, 'publish=false deve bloquear publicação');
const publishedMock = runApi({ search: { total_count: 0 }, publish: 'true' });
assert.strictEqual(publishedMock.status, 0, 'publicação autorizada no mock deve concluir');
assert.match(publishedMock.stdout, /POST_COUNT=1/, 'publicação autorizada deve fazer exatamente um POST no mock');

console.log('actions-node.tests.js: PASS');
fs.rmSync(temp, { recursive: true, force: true });
