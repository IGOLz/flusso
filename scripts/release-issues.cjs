// Shared by the release Action and offline tests. All GitHub writes live here.
module.exports = async function releaseIssues({ github, context, core, tag, dryRun = true }) {
  const repo = context.repo;
  if (!/^v\d+\.\d+\.\d+$/.test(tag)) throw new Error('Expected a stable release tag such as v0.4.3');
  const { data: release } = await github.rest.repos.getReleaseByTag({ ...repo, tag });
  if (release.draft || release.prerelease || !release.published_at) {
    core.info('Skipping an unpublished release or prerelease.');
    return;
  }
  const version = tag.slice(1);
  const required = [`Flusso-${version}.dmg`, `Flusso-${version}.zip`, 'appcast.xml', 'SHA256SUMS.txt'];
  const assets = await github.paginate(github.rest.repos.listReleaseAssets, { ...repo, release_id: release.id, per_page: 100 });
  if (required.some(name => !assets.some(asset => asset.name === name && asset.state === 'uploaded' && asset.size > 0))) {
    throw new Error('Release downloads are incomplete. Upload every release asset, then rerun this workflow.');
  }
  const milestones = await github.paginate(github.rest.issues.listMilestones, { ...repo, state: 'all', per_page: 100 });
  const milestone = milestones.find(item => item.title === tag);
  if (!milestone) {
    core.info(`No milestone named ${tag}; no issues to close.`);
    return;
  }
  if (milestone.state === 'closed') {
    core.info(`Milestone ${tag} is already closed.`);
    return;
  }
  const issues = await github.paginate(github.rest.issues.listForRepo, {
    ...repo, milestone: milestone.number, state: 'open', labels: 'ready-for-release', per_page: 100,
  });
  const marker = `<!-- released:${tag} -->`;
  let count = 0;
  const failures = [];
  const completed = new Set();
  for (const candidate of issues) {
    if (candidate.pull_request) continue;
    const params = { ...repo, issue_number: candidate.number };
    try {
      // Recheck selection in case a maintainer changed the issue during this run.
      const { data: issue } = await github.rest.issues.get(params);
      if (issue.state !== 'open' || issue.pull_request || issue.milestone?.number !== milestone.number ||
          !issue.labels.some(label => (typeof label === 'string' ? label : label.name) === 'ready-for-release')) continue;
      const comments = await github.paginate(github.rest.issues.listComments, { ...params, per_page: 100 });
      const alreadyCommented = comments.some(comment => comment.user?.login === 'github-actions[bot]' && comment.body?.includes(marker));
      if (alreadyCommented && issue.state_reason === 'reopened') {
        core.warning(`Skipping issue #${issue.number}, reopened after ${tag}.`);
        continue;
      }
      core.info(`${dryRun ? 'Would release' : 'Releasing'} #${issue.number} in ${tag}`);
      if (dryRun) { count++; completed.add(issue.number); continue; }
      if (!alreadyCommented) {
        await github.rest.issues.createComment({ ...params, body: `${marker}\nAvailable in [Flusso ${tag}](${release.html_url}). Thank you for reporting this!` });
      }
      // A comment followed by a failed close is safe to retry without another comment.
      await github.rest.issues.update({ ...params, state: 'closed', state_reason: 'completed' });
      count++;
      completed.add(issue.number);
    } catch (error) {
      failures.push(candidate.number);
      core.warning(`Could not complete #${candidate.number}: ${error.message}`);
    }
  }
  // Recount open items rather than relying on GitHub's cached milestone counter.
  const remaining = await github.paginate(github.rest.issues.listForRepo, {
    ...repo, milestone: milestone.number, state: 'open', per_page: 100,
  });
  const remainingCount = dryRun ? remaining.filter(issue => !completed.has(issue.number)).length : remaining.length;
  if (!dryRun && !failures.length && remainingCount === 0) {
    await github.rest.issues.updateMilestone({ ...repo, milestone_number: milestone.number, state: 'closed' });
  }
  core.info(`${dryRun ? 'Simulation' : 'Release completion'}: ${count} issue(s); remaining open milestone items: ${remainingCount}.`);
  if (failures.length) throw new Error(`Could not complete issue(s): ${failures.map(number => '#' + number).join(', ')}. Rerun this workflow after resolving the errors.`);
};
