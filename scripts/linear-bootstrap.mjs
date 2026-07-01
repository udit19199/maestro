#!/usr/bin/env node
/**
 * Bootstrap Zoro project in Linear via GraphQL API.
 *
 * Usage:
 *   LINEAR_API_KEY=lin_api_... node scripts/linear-bootstrap.mjs
 *   LINEAR_API_KEY=lin_api_... LINEAR_TEAM_ID=<uuid> node scripts/linear-bootstrap.mjs
 *   node scripts/linear-bootstrap.mjs --dry-run
 *
 * Get API key: Linear → Settings → Account → Security & access → Personal API keys
 * Get team ID: Linear → Cmd/Ctrl+K → "Copy model UUID" on a team, or omit to use first team.
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const DATA_PATH = join(__dirname, 'linear-issues.json');
const STATE_PATH = join(__dirname, '.linear-bootstrap-state.json');

const API_URL = 'https://api.linear.app/graphql';
const dryRun = process.argv.includes('--dry-run');
const apiKey = process.env.LINEAR_API_KEY;
const teamIdArg = process.env.LINEAR_TEAM_ID;

function log(...args) {
  console.log('[linear-bootstrap]', ...args);
}

function fail(message) {
  console.error('[linear-bootstrap] ERROR:', message);
  process.exit(1);
}

async function gql(query, variables = {}) {
  if (dryRun) {
    return { dryRun: true, query, variables };
  }

  const response = await fetch(API_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: apiKey,
    },
    body: JSON.stringify({ query, variables }),
  });

  const payload = await response.json();
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}: ${JSON.stringify(payload)}`);
  }
  if (payload.errors?.length) {
    throw new Error(payload.errors.map((e) => e.message).join('; '));
  }
  return payload.data;
}

async function getViewer() {
  const data = await gql(`query { viewer { id name email } }`);
  return data.viewer;
}

async function getTeams() {
  const data = await gql(`query { teams { nodes { id key name } } }`);
  return data.teams.nodes;
}

async function getTeamStates(teamId) {
  const data = await gql(
    `query TeamStates($teamId: String!) {
      team(id: $teamId) {
        states { nodes { id name type } }
      }
    }`,
    { teamId }
  );
  return data.team.states.nodes;
}

async function findProjectByName(teamId, name) {
  const data = await gql(
    `query TeamProjects($teamId: String!) {
      team(id: $teamId) {
        projects { nodes { id name } }
      }
    }`,
    { teamId }
  );
  return data.team.projects.nodes.find((p) => p.name === name) ?? null;
}

async function createProject(teamId, project) {
  const data = await gql(
    `mutation ProjectCreate($input: ProjectCreateInput!) {
      projectCreate(input: $input) {
        success
        project { id name url }
      }
    }`,
    {
      input: {
        name: project.name,
        description: project.description,
        teamIds: [teamId],
      },
    }
  );
  if (!data.projectCreate.success) {
    throw new Error(`Failed to create project ${project.name}`);
  }
  return data.projectCreate.project;
}

async function getExistingLabels(teamId) {
  const data = await gql(
    `query TeamLabels($teamId: String!) {
      team(id: $teamId) {
        labels { nodes { id name } }
      }
    }`,
    { teamId }
  );
  return data.team.labels.nodes;
}

async function createLabel(teamId, name) {
  const data = await gql(
    `mutation IssueLabelCreate($input: IssueLabelCreateInput!) {
      issueLabelCreate(input: $input) {
        success
        issueLabel { id name }
      }
    }`,
    { input: { name, teamId } }
  );
  if (!data.issueLabelCreate.success) {
    throw new Error(`Failed to create label ${name}`);
  }
  return data.issueLabelCreate.issueLabel;
}

async function getProjectMilestones(projectId) {
  const data = await gql(
    `query ProjectMilestones($projectId: String!) {
      project(id: $projectId) {
        projectMilestones { nodes { id name } }
      }
    }`,
    { projectId }
  );
  return data.project.projectMilestones.nodes;
}

async function createProjectMilestone(projectId, milestone) {
  const data = await gql(
    `mutation ProjectMilestoneCreate($input: ProjectMilestoneCreateInput!) {
      projectMilestoneCreate(input: $input) {
        success
        projectMilestone { id name }
      }
    }`,
    {
      input: {
        projectId,
        name: milestone.name,
        description: milestone.description,
      },
    }
  );
  if (!data.projectMilestoneCreate.success) {
    throw new Error(`Failed to create milestone ${milestone.name}`);
  }
  return data.projectMilestoneCreate.projectMilestone;
}

async function findIssueByTitle(teamId, title) {
  const data = await gql(
    `query TeamIssues($teamId: String!, $title: String!) {
      team(id: $teamId) {
        issues(first: 10, filter: { title: { eq: $title } }) {
          nodes { id identifier title url }
        }
      }
    }`,
    { teamId, title }
  );
  return data.team.issues.nodes[0] ?? null;
}

async function createIssue({
  teamId,
  projectId,
  milestoneId,
  labelIds,
  stateId,
  priority,
  title,
  description,
}) {
  const data = await gql(
    `mutation IssueCreate($input: IssueCreateInput!) {
      issueCreate(input: $input) {
        success
        issue { id identifier title url state { name } }
      }
    }`,
    {
      input: {
        teamId,
        projectId,
        projectMilestoneId: milestoneId,
        labelIds,
        stateId,
        priority,
        title,
        description,
      },
    }
  );
  if (!data.issueCreate.success) {
    throw new Error(`Failed to create issue ${title}`);
  }
  return data.issueCreate.issue;
}

function loadState() {
  try {
    return JSON.parse(readFileSync(STATE_PATH, 'utf8'));
  } catch {
    return {};
  }
}

function saveState(state) {
  if (!dryRun) {
    writeFileSync(STATE_PATH, JSON.stringify(state, null, 2));
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
  const config = JSON.parse(readFileSync(DATA_PATH, 'utf8'));

  if (!dryRun && !apiKey) {
    fail(
      'LINEAR_API_KEY is required. Create one at Linear → Settings → Account → Security & access → Personal API keys.\n' +
        'Alternatively, authenticate Linear MCP in Cursor Desktop (Settings → MCP → Linear) and ask the agent to run setup via MCP.'
    );
  }

  if (dryRun) {
    log('DRY RUN — no API calls will be made');
    log(`Would create project: ${config.project.name}`);
    log(`Would create ${config.labels.length} labels`);
    log(`Would create ${config.milestones.length} milestones`);
    log(`Would create ${config.issues.length} issues`);
    log(`  - shipped (done): ${config.issues.filter((i) => i.state === 'done').length}`);
    log(`  - backlog: ${config.issues.filter((i) => i.state !== 'done').length}`);
    return;
  }

  const viewer = await getViewer();
  log(`Authenticated as ${viewer.name} (${viewer.email})`);

  const teams = await getTeams();
  if (!teams.length) fail('No teams found in Linear workspace');

  const team = teamIdArg
    ? teams.find((t) => t.id === teamIdArg) ?? fail(`Team ID not found: ${teamIdArg}`)
    : teams[0];

  log(`Using team: ${team.name} (${team.key})`);

  const state = loadState();
  state.teamId = team.id;

  // Project
  let project = state.projectId
    ? { id: state.projectId, name: config.project.name }
    : await findProjectByName(team.id, config.project.name);

  if (!project) {
    log(`Creating project "${config.project.name}"...`);
    project = await createProject(team.id, config.project);
    state.projectId = project.id;
    saveState(state);
    log(`Created project: ${project.url ?? project.id}`);
  } else {
    state.projectId = project.id;
    saveState(state);
    log(`Project already exists: ${project.name}`);
  }

  // Labels
  const existingLabels = await getExistingLabels(team.id);
  const labelMap = Object.fromEntries(existingLabels.map((l) => [l.name, l.id]));
  for (const labelName of config.labels) {
    if (!labelMap[labelName]) {
      log(`Creating label: ${labelName}`);
      const created = await createLabel(team.id, labelName);
      labelMap[labelName] = created.id;
      await sleep(150);
    }
  }
  state.labelIds = labelMap;
  saveState(state);
  log(`Labels ready: ${config.labels.length}`);

  // Milestones
  const existingMilestones = await getProjectMilestones(project.id);
  const milestoneMap = Object.fromEntries(existingMilestones.map((m) => [m.name, m.id]));
  for (const milestone of config.milestones) {
    if (!milestoneMap[milestone.name]) {
      log(`Creating milestone: ${milestone.name}`);
      const created = await createProjectMilestone(project.id, milestone);
      milestoneMap[milestone.name] = created.id;
      await sleep(150);
    }
  }
  state.milestoneIds = milestoneMap;
  saveState(state);
  log(`Milestones ready: ${config.milestones.length}`);

  // Workflow states
  const states = await getTeamStates(team.id);
  const doneState = states.find((s) => s.type === 'completed') ?? states.find((s) => /done/i.test(s.name));
  const backlogState = states.find((s) => s.type === 'backlog') ?? states.find((s) => /backlog/i.test(s.name)) ?? states.find((s) => s.type === 'unstarted');

  if (!doneState || !backlogState) {
    fail(`Could not resolve workflow states. Found: ${states.map((s) => `${s.name}(${s.type})`).join(', ')}`);
  }

  // Issues
  state.createdIssues = state.createdIssues ?? {};
  let created = 0;
  let skipped = 0;

  for (const issue of config.issues) {
    if (state.createdIssues[issue.ref]) {
      skipped++;
      continue;
    }

    const existing = await findIssueByTitle(team.id, issue.title);
    if (existing) {
      state.createdIssues[issue.ref] = existing.identifier;
      skipped++;
      continue;
    }

    const labelIds = issue.labels.map((name) => labelMap[name]).filter(Boolean);
    const milestoneId = milestoneMap[issue.milestone];
    const stateId = issue.state === 'done' ? doneState.id : backlogState.id;

    log(`Creating ${issue.ref}: ${issue.title}`);
    const createdIssue = await createIssue({
      teamId: team.id,
      projectId: project.id,
      milestoneId,
      labelIds,
      stateId,
      priority: issue.priority,
      title: issue.title,
      description: `[${issue.ref}]\n\n${issue.description}`,
    });

    state.createdIssues[issue.ref] = createdIssue.identifier;
    saveState(state);
    created++;
    await sleep(200);
  }

  log('Done.');
  log(`Project: ${project.name} (${project.id})`);
  log(`Issues created this run: ${created}`);
  log(`Issues skipped (already exist): ${skipped}`);
  log(`Total tracked refs: ${Object.keys(state.createdIssues).length}`);
  log('');
  log('Manual follow-up in Linear UI:');
  log('- Create saved views: Roadmap, Shipped Inventory, Gmail Focus, iMessage Focus, Needs macOS Verification');
  log('- Review v0 Shipped issues are in Done state');
  log('- Prioritize v1 Gmail Hardening backlog');
}

main().catch((error) => {
  console.error('[linear-bootstrap] FATAL:', error.message);
  process.exit(1);
});
