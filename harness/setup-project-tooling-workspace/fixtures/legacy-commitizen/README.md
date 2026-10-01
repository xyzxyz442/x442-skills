# legacy-commitizen (setup-project-tooling pre-state fixture)

A Node project on the older commit and release stack: commitizen with the conventional-changelog
adapter, standard-version with a `.versionrc.json`, the husky package behind a `prepare` script, and
a `.gitignore` that hides the whole `.husky` directory. An agent runs setup-project-tooling, accepts
the release-it migration, and the legacy stack and the broad ignore rule are gone.
