#!/usr/bin/env node
/** Generate Linear CSV import file from linear-issues.json */

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const config = JSON.parse(readFileSync(join(__dirname, 'linear-issues.json'), 'utf8'));
const outPath = join(__dirname, 'linear-import.csv');

function csvEscape(value) {
  const str = String(value ?? '');
  if (/[",\n\r]/.test(str)) {
    return `"${str.replace(/"/g, '""')}"`;
  }
  return str;
}

const priorityMap = { 1: 'Urgent', 2: 'High', 3: 'Medium', 4: 'Low', 0: 'No priority' };

const rows = [
  ['Title', 'Description', 'Priority', 'Status', 'Labels'].join(','),
  ...config.issues.map((issue) => {
    const status = issue.state === 'done' ? 'Done' : 'Backlog';
    const labels = issue.labels.join(',');
    const description = `[${issue.ref}] ${issue.milestone}\n\n${issue.description}`;
    return [
      csvEscape(issue.title),
      csvEscape(description),
      csvEscape(priorityMap[issue.priority] ?? 'No priority'),
      csvEscape(status),
      csvEscape(labels),
    ].join(',');
  }),
];

writeFileSync(outPath, rows.join('\n') + '\n', 'utf8');
console.log(`Wrote ${config.issues.length} issues to ${outPath}`);
console.log('Import with: LINEAR_API_KEY=lin_api_... npx @linear/import --importer linearCsv --team YOUR_TEAM');
