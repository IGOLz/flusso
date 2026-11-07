const { test } = require('node:test');
const assert = require('node:assert/strict');
const complete = require('../scripts/release-issues.cjs');

function fixture() {
  const milestone = { title: 'v0.4.3', number: 3, state: 'open' };
  const issue = { number: 1, state: 'open', state_reason: null, milestone: { number: 3 }, labels: [{name: 'ready-for-release'}] };
  const state = {
    release: { id: 4, tag_name: 'v0.4.3', draft: false, prerelease: false, published_at: '2026-11-05', html_url: 'https://github.com/IGOLz/flusso/releases/tag/v0.4.3' },
    assets: ['Flusso-0.4.3.dmg', 'Flusso-0.4.3.zip', 'appcast.xml', 'SHA256SUMS.txt'].map(name => ({name, state: 'uploaded', size: 10})),
    milestones: [milestone], issues: [issue], comments: [], writes: [], calls: [], failClose: false,
  };
  const issues = {
    listMilestones: 'milestones', listForRepo: 'issues', listComments: 'comments',
    get: async ({issue_number}) => ({data: state.issues.find(i => i.number === issue_number)}),
    createComment: async data => { state.writes.push(['comment', data]); state.comments.push({...data, user: {login: 'github-actions[bot]'}}); },
    update: async data => {
      if (state.failClose === true || state.failClose === data.issue_number) throw new Error('Temporary close failure');
      state.writes.push(['close', data]); Object.assign(state.issues.find(i => i.number === data.issue_number), data);
    },
    getMilestone: async () => ({data: {...milestone, open_issues: state.issues.filter(i => i.state === 'open' && i.milestone?.number === 3).length}}),
    updateMilestone: async data => { state.writes.push(['milestone', data]); Object.assign(milestone, data); },
  };
  const github = {
    rest: { issues, repos: { getReleaseByTag: async () => { if (state.releaseError) throw state.releaseError; return {data: state.release}; }, listReleaseAssets: 'assets' } },
    paginate: async (endpoint, params) => {
      assert.equal(params.per_page, 100);
      state.calls.push({endpoint, ...params});
      if (endpoint === 'issues') {
        const pool = params.labels ? (state.candidates ?? state.issues) : state.issues;
        return pool.filter(i => i.state === params.state && i.milestone?.number === params.milestone &&
          (!params.labels || i.labels.some(label => (label.name ?? label) === params.labels)));
      }
      if (endpoint === 'comments') return state.comments.filter(comment => (comment.issue_number ?? 1) === params.issue_number);
      return state[endpoint];
    },
  };
  const logs = [];
  const run = (dryRun = false, tag = 'v0.4.3') => complete({github, context: {repo: {owner: 'IGOLz', repo: 'flusso'}}, core: {info: text => logs.push(text), warning: text => logs.push(text)}, tag, dryRun});
  return {state, run, issue, milestone, logs};
}

test('stable published release comments, closes as completed, then closes empty milestone', async () => {
  const f = fixture(); await f.run();
  assert.deepEqual(f.state.writes.map(w => w[0]), ['comment', 'close', 'milestone']);
  assert.match(f.state.comments[0].body, /Available in \[Flusso v0.4.3\]\(https:\/\/github.com/);
  assert.equal(f.issue.state_reason, 'completed');
  await f.run(); assert.equal(f.state.comments.length, 1);
});
test('dry run reads selection but never comments or closes anything', async () => {
  const f = fixture(); await f.run(true); assert.deepEqual(f.state.writes, []);
  assert(f.logs.some(s => s.includes('Simulation: 1 issue')));
});
test('unpublished drafts and prereleases make no changes', async () => {
  for (const field of ['draft', 'prerelease', 'published_at']) {
    const f = fixture(); f.state.release[field] = field === 'published_at' ? null : true;
    await f.run(); assert.deepEqual(f.state.writes, []);
  }
});
test('invalid tags fail before making changes', async () => {
  const f = fixture(); await assert.rejects(f.run(false, 'v0.4.3-beta.1'), /stable release tag/);
  assert.deepEqual(f.state.writes, []);
});
test('missing, empty, or unfinished download assets block all writes', async () => {
  for (const mutate of [f => f.state.assets.pop(), f => f.state.assets[0].size = 0, f => f.state.assets[0].state = 'new']) {
    const f = fixture(); mutate(f); await assert.rejects(f.run(), /downloads are incomplete/); assert.deepEqual(f.state.writes, []);
  }
});
test('missing milestone does not close any issue', async () => {
  const f = fixture(); f.state.milestones = []; await f.run(); assert.deepEqual(f.state.writes, []);
});
test('unready issues and pull requests stay open and prevent milestone closure', async () => {
  const f = fixture(); f.state.issues.push({...f.issue, number: 2, labels: []}, {...f.issue, number: 3, pull_request: {}});
  await f.run(); assert.equal(f.issue.state, 'closed');
  assert.equal(f.state.issues[1].state, 'open'); assert.equal(f.state.issues[2].state, 'open'); assert.equal(f.milestone.state, 'open');
});
test('fresh issue checks protect moved, unlabelled, and already closed candidates', async () => {
  for (const mutate of [f => f.issue.milestone = {number: 99}, f => f.issue.labels = [], f => f.issue.state = 'closed']) {
    const f = fixture(); f.state.candidates = [{...f.issue}]; mutate(f); await f.run();
    assert(!f.state.writes.some(w => ['comment', 'close'].includes(w[0])));
  }
});
test('retry after failed close does not duplicate the successful bot comment', async () => {
  const f = fixture(); f.state.failClose = true;
  await assert.rejects(f.run(), /Could not complete issue\(s\): #1/); assert.equal(f.state.comments.length, 1);
  f.state.failClose = false; await f.run(); assert.equal(f.state.comments.length, 1); assert.equal(f.issue.state, 'closed');
});
test('all comment pages are inspected and user-authored markers do not impersonate the bot', async () => {
  const f = fixture(); f.state.comments = Array.from({length: 101}, () => ({user: {login: 'someone'}, body: '<!-- released:v0.4.3 -->'}));
  await f.run(); assert.equal(f.state.comments.length, 102);
});
test('reopened issues already announced for this release are not closed again', async () => {
  const f = fixture(); f.issue.state_reason = 'reopened'; f.state.comments = [{user: {login: 'github-actions[bot]'}, body: '<!-- released:v0.4.3 -->'}];
  await f.run(); assert.deepEqual(f.state.writes, []); assert.equal(f.issue.state, 'open');
  assert(!f.logs.some(line => line.includes('Releasing #1')));
});
test('reopened issue can be completed by a subsequent release', async () => {
  const f = fixture(); f.issue.state_reason = 'reopened'; f.state.comments = [{user: {login: 'github-actions[bot]'}, body: '<!-- released:v0.4.2 -->'}];
  await f.run(); assert.equal(f.issue.state, 'closed');
});

test('failed issue does not block other ready issues; milestone remains open and run fails', async () => {
  const f = fixture(); f.state.issues.push({...f.issue, number: 2}); f.state.failClose = 1;
  await assert.rejects(f.run(), /Could not complete issue\(s\): #1/);
  assert.equal(f.issue.state, 'open'); assert.equal(f.state.issues[1].state, 'closed'); assert.equal(f.milestone.state, 'open');
  assert.equal(f.state.comments.length, 2);
});
test('cached milestone counters are not used to decide closure', async () => {
  const f = fixture(); f.milestone.open_issues = 99;
  await f.run(); assert.equal(f.milestone.state, 'closed');
  const recount = f.state.calls.filter(call => call.endpoint === 'issues' && !call.labels);
  assert.equal(recount.length, 1); assert.equal(recount[0].milestone, 3); assert.equal(recount[0].state, 'open');
});
test('simulation reports remaining items after the proposed closures', async () => {
  const f = fixture(); f.state.issues.push({...f.issue, number: 2, labels: []});
  await f.run(true); assert.deepEqual(f.state.writes, []);
  assert(f.logs.some(line => line.includes('remaining open milestone items: 1.')));
});
test('selection requests both milestone and ready label; foreign issues remain untouched', async () => {
  const f = fixture(); f.state.issues.push({...f.issue, number: 2, milestone: {number: 99}});
  await f.run(); assert.equal(f.state.issues[1].state, 'open');
  const selection = f.state.calls.find(call => call.endpoint === 'issues' && call.labels);
  assert.deepEqual({milestone: selection.milestone, labels: selection.labels, state: selection.state},
    {milestone: 3, labels: 'ready-for-release', state: 'open'});
});
test('already-closed milestone is untouched', async () => {
  const f = fixture(); f.milestone.state = 'closed'; await f.run(); assert.deepEqual(f.state.writes, []);
});
test('missing release fails without writes', async () => {
  const f = fixture(); f.state.releaseError = Object.assign(new Error('Release not found'), {status: 404});
  await assert.rejects(f.run(), /Release not found/); assert.deepEqual(f.state.writes, []);
});
test('assets are enumerated through paginate even beyond the first hundred', async () => {
  const f = fixture(); f.state.assets.unshift(...Array.from({length: 101}, (_, index) => ({name: 'extra-' + index, size: 1, state: 'uploaded'})));
  await f.run(); assert.equal(f.issue.state, 'closed');
  assert(f.state.calls.some(call => call.endpoint === 'assets' && call.release_id === 4 && call.per_page === 100));
});
