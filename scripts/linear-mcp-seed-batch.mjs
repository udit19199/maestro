#!/usr/bin/env node
/**
 * Prints save_issue payloads from linear-issues.json for MCP batch seeding.
 * Usage: node scripts/linear-mcp-seed-batch.mjs [start] [count]
 */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const start = Number(process.argv[2] ?? 0);
const count = Number(process.argv[3] ?? 12);
const issues = JSON.parse(readFileSync(join(__dirname, 'linear-issues.json'), 'utf8')).issues;
const slice = issues.slice(start, start + count);

for (const issue of slice) {
  const payload = {
    title: issue.title,
    description: `[${issue.ref}]\n\n${issue.description}`,
    team: 'Udit19199',
    project: 'Zoro',
    milestone: issue.milestone,
    state: issue.state === 'done' ? 'Done' : 'Backlog',
    labels: issue.labels,
    priority: issue.priority,
  };
  process.stdout.write(JSON.stringify(payload) + '\n');
}

console.error(`Batch ${start}-${start + slice.length - 1} (${slice.length} issues)`);
