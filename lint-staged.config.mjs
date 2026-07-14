import path from 'node:path';

/**
 * Harness fixtures are sample projects the eval harness feeds to a skill — inputs, not this
 * repo's source. Formatting or linting them would rewrite the very bytes a grader asserts on,
 * and they are deliberately imperfect (a fixture's whole job can be to start out unwired), so
 * they are excluded from every task here.
 */
const isFixture = (file) =>
  path.relative(process.cwd(), file).startsWith('harness' + path.sep) &&
  path.relative(process.cwd(), file).includes(`${path.sep}fixtures${path.sep}`);

const lintable = (files) => files.filter((file) => !isFixture(file));

/** Build the task list for `commands`, or none when every staged file was a fixture. */
const run = (files, commands) => {
  const targets = lintable(files);
  if (targets.length === 0) return [];
  const args = targets.map((file) => JSON.stringify(file)).join(' ');
  return commands.map((command) => `${command} ${args}`);
};

/** @type {import('lint-staged').Configuration} */
export default {
  '*.{js,jsx,ts,tsx}': (files) => run(files, ['prettier --write', 'eslint --fix', 'eslint']),
  '*.{json,md,yml}': (files) => run(files, ['prettier --write']),
};
