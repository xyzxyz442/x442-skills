/** @type {import('@commitlint/types').UserConfig} */
const Configuration = {
  extends: ['@commitlint/config-conventional'],
  formatter: '@commitlint/format',
  rules: {
    'type-enum': [
      2,
      'always',
      [
        'feat', // New feature
        'fix', // Bug fix
        'docs', // Documentation changes
        'style', // Changes that do not affect the meaning of the code (white-space, formatting, etc.)
        'refactor', // Code changes that neither fix a bug nor add a feature
        'perf', // Performance improvement
        'test', // Adding missing tests or correcting existing tests
        'build', // Changes that affect the build system or external dependencies (example scopes: npm)
        'ci', // Changes to CI configuration files and scripts
        'chore', // Other changes that don't modify src or test files
        'revert', // Reverts a previous commit
      ],
    ],
    'scope-enum': [
      2,
      'always',
      [
        'setup', // Project setup
        'config', // Configuration files
        'deps', // Dependency updates
        'feature', // Feature-specific changes
        'bug', // Bug fixes
        'docs', // Documentation
        'style', // Code style/formatting
        'refactor', // Code refactoring
        'test', // Tests
        'build', // Build scripts or configuration
        'ci', // Continuous integration
        'release', // Release related changes
        'other', // Other changes
      ],
    ],
    'body-max-line-length': [0, 'always'],
    // OFF because it fires on prose, not on footers. conventional-commits-parser treats ANY line
    // beginning `token:` as a footer, so a wrapped body line that happens to start with a word and
    // a colon is parsed as one — and the prose after it then "has no leading blank line".
    //
    // Reproduce: these two differ only in where the line breaks, and only the first warns.
    //   ...continues onto\nlint-staged: before it was bad.   -> footer-leading-blank
    //   ...continues onto lint-staged\nand before it was bad. -> clean
    //
    // Every occurrence in this repo's history is that false positive. Kept as a warning it trained
    // readers to skip commitlint output entirely, which is what would hide a real `type-enum` or
    // `scope-enum` error — both of which are level 2 and must not be lost in noise.
    'footer-leading-blank': [0, 'always'],
  },
};

export default Configuration;
