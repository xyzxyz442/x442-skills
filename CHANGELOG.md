# Changelog

## [0.6.0](https://github.com/xyzxyz442/x442-skills/compare/v0.5.0...v0.6.0) (2026-07-23)

### 🚀 Features

- **feature:** add the release-announcement skill and its text-output eval harness ([be61dcb](https://github.com/xyzxyz442/x442-skills/commit/be61dcba822e9a7f73052f4fac1f2e349c6c8e6d))
- **feature:** prefer vector search with per-search tier markers in graph hooks ([aa9d449](https://github.com/xyzxyz442/x442-skills/commit/aa9d449e6c964c972a40f6c5678aca16cf2f5596))
- **feature:** recheck and run the full setup chain from initial-project ([65ef9aa](https://github.com/xyzxyz442/x442-skills/commit/65ef9aa1977f0693a90d7d88425910c931f4c85f))
- **feature:** replace the husky echo-fragment chain with script dispatchers ([15c39af](https://github.com/xyzxyz442/x442-skills/commit/15c39afe80a4307fc57c1cdaac66bb92dd26afe0))
- **feature:** restructure the board and add the orchestrator handoff type ([f0eae70](https://github.com/xyzxyz442/x442-skills/commit/f0eae7099569d60a587e6ad5e7bcc97a355eba0f))

### 🐞 Bug Fixes

- **bug:** enforce lowercase kebab-case handoff ids ([ad65169](https://github.com/xyzxyz442/x442-skills/commit/ad6516954912ed1a08f1b0fb115781658dc3e151))
- **bug:** fold colons out of handoff titles to keep frontmatter parseable ([a6f75c9](https://github.com/xyzxyz442/x442-skills/commit/a6f75c9f537075447c2da0fd26ab40fffcce5675))
- **bug:** re-sync the board README copies with the payload ([28cf45b](https://github.com/xyzxyz442/x442-skills/commit/28cf45b8e0315c140dd5e68f82f5ffee0b85d866))

### 📚 Documentation

- **docs:** close the release-announcement harness handoff as done ([4c80f14](https://github.com/xyzxyz442/x442-skills/commit/4c80f14592e9e5a918b1693b8f4fe084b2b4ece2))
- **docs:** document the new layout, orchestrators, and the bug-filing rule ([b8ed4a0](https://github.com/xyzxyz442/x442-skills/commit/b8ed4a05ac93da728d14e4119b5909bd8b262c1e))
- **docs:** re-audit the husky migration at full depth, 16 carriers ([ea54212](https://github.com/xyzxyz442/x442-skills/commit/ea54212a9992ab6f35b28cda58fdb6823d347b4c))
- **docs:** record re-verification in the cross-repo eval report ([0da55cd](https://github.com/xyzxyz442/x442-skills/commit/0da55cd0a3e8e4eda63660e8414b3abc486bda59))
- **docs:** record the husky-migration audit results on the handoff ([816b3ba](https://github.com/xyzxyz442/x442-skills/commit/816b3ba9f72b8456aea0b4709a34b62949eba628))
- **docs:** sync graph-search-tier docs — initial-project chain note + repo AGENTS.md tier ladder ([81745ce](https://github.com/xyzxyz442/x442-skills/commit/81745ce07501587c135f04388ca1a573f6fabecc))

### 🧪 Tests

- **test:** cover ids, layout migration, orchestrators and release validation ([e39b1dc](https://github.com/xyzxyz442/x442-skills/commit/e39b1dcb25470af5d15cae5b392eb76ad9f9c54e))

### 🧹 Miscellaneous Chores

- **other:** bump prettier and lint-staged ([4e3ba44](https://github.com/xyzxyz442/x442-skills/commit/4e3ba44d831e2464ffb992079d3ece511c51a2db))
- **other:** update the handoff board ([9030671](https://github.com/xyzxyz442/x442-skills/commit/903067184c3617e3aa130f421f309461388390a5))

## [0.5.0](https://github.com/xyzxyz442/x442-skills/compare/v0.4.0...v0.5.0) (2026-07-20)

### 🚀 Features

- **setup:** name handoff docs <id>-handoff.md, use filename as id ([86292ba](https://github.com/xyzxyz442/x442-skills/commit/86292ba6ead53c437028cd29ceb2b2ee28317a2b))

### 🐞 Bug Fixes

- **setup:** cross-repo shared board — per-repo identity, path substitution, topology-aware gitignore ([4907c19](https://github.com/xyzxyz442/x442-skills/commit/4907c19616be32fede0c1346e8e37ff609baa80b))

## [0.4.0](https://github.com/xyzxyz442/x442-skills/compare/v0.3.1...v0.4.0) (2026-07-20)

### 🚀 Features

- **setup:** add run-handoff discipline skill ([eea16c9](https://github.com/xyzxyz442/x442-skills/commit/eea16c905eb82b3329fc94bcf810ec487477221a))
- **setup:** add setup-handoff coordination skill ([7b0eaad](https://github.com/xyzxyz442/x442-skills/commit/7b0eaad42fbc2fa0c22abaab790037508a837538))
- **setup:** add standalone handoff type (isolated, claim-exempt) + import ([344af84](https://github.com/xyzxyz442/x442-skills/commit/344af84548d893b07895571b809223c0dec20ea0))

### 📚 Documentation

- **setup:** add handoff-types eval report and update the sync handoff ([a10529a](https://github.com/xyzxyz442/x442-skills/commit/a10529abd92b0affa84bf33737ff6f944bb1bdd2))
- **setup:** index and document the handoff skills ([899187b](https://github.com/xyzxyz442/x442-skills/commit/899187b4675c7c81d23a80392ee1f669faeea696))
- **setup:** redact secrets, suggest skills, link-don't-duplicate in handoff docs ([ea0e8fe](https://github.com/xyzxyz442/x442-skills/commit/ea0e8feee56d0d7aee80a1b9e1dd4124282ba127))

### 💅 Styles

- **setup:** apply prettier-sh formatting to handoff shell scripts ([9d0180c](https://github.com/xyzxyz442/x442-skills/commit/9d0180ca5037b5d8bbd2aeaf99dcc7519b9a16df))

### 🧹 Miscellaneous Chores

- **ci:** configure Dependabot for daily npm and pip updates ([2f4e2ab](https://github.com/xyzxyz442/x442-skills/commit/2f4e2ab4dcd06d52067997aa9bc6279e784bde9d))
- **setup:** install handoff board and wire enforcement hooks ([a21645b](https://github.com/xyzxyz442/x442-skills/commit/a21645b9c781ab0d1ca5ab3cfc7068eab8cbb160))
- **setup:** migrate reference docs into the board as standalone handoffs ([d468353](https://github.com/xyzxyz442/x442-skills/commit/d4683531bed49f2370bd4a5614b54a3ad72ffa4c))

## [0.3.1](https://github.com/xyzxyz442/x442-skills/compare/v0.3.0...v0.3.1) (2026-07-18)

### 🐞 Bug Fixes

- **setup:** make setup-graph-hooks surface the embeddings choice reliably ([9a9804c](https://github.com/xyzxyz442/x442-skills/commit/9a9804c80c3f1313d70de66f25dda1825547dd9c))

### 🏗️ Build System

- **deps:** pin conventional-changelog to v8 for a correct release changelog ([12653d3](https://github.com/xyzxyz442/x442-skills/commit/12653d3e910a03c4f9a0f6cd713a6160a929d449))

## [0.3.0](https://github.com/xyzxyz442/x442-skills/compare/v0.2.1...v0.3.0) (2026-07-16)

### 🚀 Features

- **setup:** promote repair-graph-hooks and register-cross-repo-graph to stable ([e3788ec](https://github.com/xyzxyz442/x442-skills/commit/e3788ec851272c2c3fdc8b0d114788a87a17ab10))
- **test:** add the first deterministic A/B eval iterations ([873bcda](https://github.com/xyzxyz442/x442-skills/commit/873bcda061be78fbf7ad9c1c2a3f0faa68605833))
- **test:** label evals pre-state/post-state and hint on raw pre-state grading ([77fc016](https://github.com/xyzxyz442/x442-skills/commit/77fc016caa9df0dae204e315058ec3c993511ec6))
- **test:** add the setup-project-tooling eval workspace ([dba5076](https://github.com/xyzxyz442/x442-skills/commit/dba5076b58dd7252deee1eeffc363be29a811340))
- **test:** add a skipped expectation state to the grading library ([0cbbd62](https://github.com/xyzxyz442/x442-skills/commit/0cbbd62463056ef802cc39f93b398dc4926c6e1d))
- **test:** add the repair-graph-hooks eval workspace ([dddd647](https://github.com/xyzxyz442/x442-skills/commit/dddd6470504370b5a36673d56c0b1576ea3ba94d))
- **test:** add the register-cross-repo-graph eval workspace ([57c1a79](https://github.com/xyzxyz442/x442-skills/commit/57c1a792de305d80e55d28f2efc3de4b4b82a99c))
- **test:** add the setup-graph-hooks eval workspace ([54e63ee](https://github.com/xyzxyz442/x442-skills/commit/54e63ee8f7e62851766cf5f674f70a78e7d03229))
- **test:** add the initial-project eval workspace ([b3d99d4](https://github.com/xyzxyz442/x442-skills/commit/b3d99d4ba4e6a162a11d8e7ff5f0625fd2707995))
- **test:** add the shared skill-eval grading library ([ab7c458](https://github.com/xyzxyz442/x442-skills/commit/ab7c4581760e8fb7e7ba62dfff7c5ce0f0119114))

### 🐞 Bug Fixes

- **test:** keep prettier off generated benchmarks for byte-idempotent re-runs ([dcb1556](https://github.com/xyzxyz442/x442-skills/commit/dcb1556487d911d7a2eda41a8ea1096a1fa94948))
- **test:** isolate the initial-project grader from the outer repo ([6124f6a](https://github.com/xyzxyz442/x442-skills/commit/6124f6aede990f0a905cfc8d9d1153e95d68bde1))
- **test:** make the cross-repo grader's tool dependencies explicit ([28d4a58](https://github.com/xyzxyz442/x442-skills/commit/28d4a58af28a2f77a0ad037fae9d7afd0d1237ac))
- **setup:** exit 0 when cross-repo access is not configured ([097075a](https://github.com/xyzxyz442/x442-skills/commit/097075af66375a125727e25db918c8c611953b6c))
- **test:** grade fixtures in isolation from the outer repo ([2e8f9c0](https://github.com/xyzxyz442/x442-skills/commit/2e8f9c09b383db344568f2984a59d35153bc0a40))
- **setup:** close the sibling-refresh loop in cross-repo scope ([c76d5e5](https://github.com/xyzxyz442/x442-skills/commit/c76d5e574e9695a8ed6c496846224f91f894dd5e))
- **test:** regenerate wired graph-hooks fixtures against the current skill ([0960cab](https://github.com/xyzxyz442/x442-skills/commit/0960caba949a0f2c6aa1d70368172fff22ff00e5))
- **setup:** freshness-gate cross-repo greps and answer with call sites ([82a40d9](https://github.com/xyzxyz442/x442-skills/commit/82a40d98d9476dce9949f8df1e3f5cc24f7f8c70))
- **test:** regenerate the wired graph-hooks fixtures against the current skill ([b5a1ada](https://github.com/xyzxyz442/x442-skills/commit/b5a1ada0f02f4829484113e1ef2821739bd85050))
- **setup:** teach the graph hooks about in-scope sibling repos ([073f545](https://github.com/xyzxyz442/x442-skills/commit/073f545dee50d0da73dbfc8c290daffc6a00784c))
- **setup:** repair the malformed cross-repo routing table template ([26a708d](https://github.com/xyzxyz442/x442-skills/commit/26a708d97e743f4a617a8a3636d8669351942262))
- **docs:** drop the stale CI claim from commitlint enforcement ([ab0e207](https://github.com/xyzxyz442/x442-skills/commit/ab0e20723e9b436da0316f67dc856c0d82d1fdf3))
- **setup:** mark the shipped commit-msg hook payload executable ([7468e84](https://github.com/xyzxyz442/x442-skills/commit/7468e84b6b7640b9537a6e4b63c6335f28713467))

### 📚 Documentation

- **docs:** resync roadmap and drop stale AGENTS.md TODOs ([75d1264](https://github.com/xyzxyz442/x442-skills/commit/75d12644c675d03aa4e5be85152e76674ea030e6))
- **docs:** record the first benchmark; contextualize gaps #1/#4/#5 ([a2d4736](https://github.com/xyzxyz442/x442-skills/commit/a2d4736fe1ea95d69e441d5951eecb670fb650d9))
- **docs:** record the tooling workspace and skip state; close gaps #1 and #3 ([8684de9](https://github.com/xyzxyz442/x442-skills/commit/8684de9e8a150ab9acbaeae29bc47dc33d3a4e77))
- **docs:** record this repo's own open harness gaps ([2fdce2f](https://github.com/xyzxyz442/x442-skills/commit/2fdce2f8f14eb3307a9b7f1553d1f10276e2d091))
- **docs:** record the cross-repo and repair eval workspaces ([fd4058f](https://github.com/xyzxyz442/x442-skills/commit/fd4058f8ee1c1d0fcb5bdb3255d3bc0589465cb1))
- **docs:** clarify the merged graph is not a cross-repo bridge ([213de14](https://github.com/xyzxyz442/x442-skills/commit/213de14425d3037c53c0275c537afcd27b47cfaf))
- **docs:** mark the eval harness as built, not specced ([6342bc6](https://github.com/xyzxyz442/x442-skills/commit/6342bc60872bec526ca8d3023ead409a7523b6cc))
- **test:** document how to run and grade an eval ([ad9fd58](https://github.com/xyzxyz442/x442-skills/commit/ad9fd58e97b2891af1b3c0ffbd8a3ab82e797dc8))
- **docs:** document the sibling tier in the grep-steer ladder ([83b0595](https://github.com/xyzxyz442/x442-skills/commit/83b059586cdb55cf9fedb399f6e5c1d5b64df7b3))
- **docs:** add a monorepo scenario for the subdir manifest layer ([fab568f](https://github.com/xyzxyz442/x442-skills/commit/fab568f1f690f7144a6892e0e93d9111befea5f2))
- **docs:** add an orienting diagram to each graph-tool skill ([fa47424](https://github.com/xyzxyz442/x442-skills/commit/fa47424bfc5f6cb405c9a7706b07d619c8dc8682))
- **docs:** illustrate cross-repo lookup with diagrams and scenarios ([0e57f64](https://github.com/xyzxyz442/x442-skills/commit/0e57f64beaccb309f9dd1e741906ceabc91463a8))
- **docs:** rewrite the cross-repo section for the manifest cascade ([ce90139](https://github.com/xyzxyz442/x442-skills/commit/ce901393cc850cf29340614aa567e710c27adbf7))
- **docs:** restore the missing v0.2.1 changelog entries ([9d6980f](https://github.com/xyzxyz442/x442-skills/commit/9d6980fc3d35d9434b401b3a9b383023e050ddcd))

### 💅 Styles

- **style:** format grep-steer.sh with prettier-plugin-sh ([3f4e016](https://github.com/xyzxyz442/x442-skills/commit/3f4e0164f9c122d25b5452016583a1cc3950e323))

### 🧼 Code Refactoring

- **setup:** unify the verify-script contract across the four skills ([2495036](https://github.com/xyzxyz442/x442-skills/commit/2495036b7deacb02011f6fa411778ff394fb0c8a))
- **setup:** emit only the resolver fields a consumer reads ([6fe6fb8](https://github.com/xyzxyz442/x442-skills/commit/6fe6fb8ce93601c0e5bb93246109cf500689c40c))
- **config:** express the fixture exclusion as a glob, not a function ([451f060](https://github.com/xyzxyz442/x442-skills/commit/451f060a23efa0ab6e60c6a49e33d55debe6cd4a))

### 🧪 Tests

- **setup:** assert a cross-repo grep gets steered to the graph ([b710917](https://github.com/xyzxyz442/x442-skills/commit/b710917b1fe6deac134415483cac9c78983e4c25))

### 🧹 Miscellaneous Chores

- **config:** gitignore the .claude/handoff working folder ([1ee8c7c](https://github.com/xyzxyz442/x442-skills/commit/1ee8c7cb2c9adf9e8d6d88ad8d9dd1b08e9dc2c9))
- **config:** keep prettier off the invalid-JSON repair fixture ([3481390](https://github.com/xyzxyz442/x442-skills/commit/34813905aae33307e6e9ca8ed4d3ac54a4c7006b))
- **config:** narrow lint-staged to prettier on json/md/yml ([435a84f](https://github.com/xyzxyz442/x442-skills/commit/435a84fefa47f782350221e29954ddf0f633cc66))
- **config:** exclude harness fixtures from lint-staged ([06b3d37](https://github.com/xyzxyz442/x442-skills/commit/06b3d37dba1cab3e86f4576360f6a18d000e53fb))
- **config:** keep eval-harness source out of the ignore rules ([c5c53c4](https://github.com/xyzxyz442/x442-skills/commit/c5c53c4d15cc7b2d297ea8af5ff1731ccb7c7d77))
- **setup:** drop seven dead pre-graph-hooks scripts ([ff40ffc](https://github.com/xyzxyz442/x442-skills/commit/ff40ffc09e8e08c44ddb5dc2faab8d17285c8a8e))

## [0.2.1](https://github.com/xyzxyz442/x442-skills/compare/v0.2.0...v0.2.1) (2026-07-13)

### 🐞 Bug Fixes

- **config:** ensure body-max-line-length rule is set to always ([b35d29a](https://github.com/xyzxyz442/x442-skills/commit/b35d29a0fb4627004963e16ee7c7592a1d793b57))

### 🧹 Miscellaneous Chores

- update dependencies for commitlint, prettier, and release-it ([1d3a1ac](https://github.com/xyzxyz442/x442-skills/commit/1d3a1acde9c0c16eff6752b52980c1b529615d0d))

## 0.2.0 (2026-07-13)

### 🚀 Features

- add graph-hooks setup option to initial-project skill ([8771ff1](https://github.com/xyzxyz442/x442-skills/commit/8771ff1ca55ae782b388425d86f590f518aa856a))
- add graphignore template and enhance setup script for idempotent ignore file management ([8dab649](https://github.com/xyzxyz442/x442-skills/commit/8dab649b09d6145933a8fc9521b75fb79a160819))
- add Karpathy coding guidelines and setup hooks for automatic application ([2d6c372](https://github.com/xyzxyz442/x442-skills/commit/2d6c372a8f71ff2bf39a4c64b94622a9be7c2c51))
- add per-tool graph-hook config generator and Copilot wrappers ([8d4ccbe](https://github.com/xyzxyz442/x442-skills/commit/8d4ccbe31e61b35693495eef116acb784eb963e7))
- add Prettier configuration and ignore files ([8028e07](https://github.com/xyzxyz442/x442-skills/commit/8028e079dff2ab4abcec00fdeb2d20fcbd013108))
- add release-it configuration for automated releases ([f8ca74a](https://github.com/xyzxyz442/x442-skills/commit/f8ca74a227ac61ca9c64dca578465dd21c9fa6ce))
- add scripts to link and list skills in the repository ([11dd85a](https://github.com/xyzxyz442/x442-skills/commit/11dd85a6990203e57e54780da3f4aa075c020ccd))
- add setup-graph-hooks skill ([ce9616d](https://github.com/xyzxyz442/x442-skills/commit/ce9616dcc599f40976afb462703f82176d320436))
- add tool-neutral graph-hook cores and protocol dispatcher ([8320c1f](https://github.com/xyzxyz442/x442-skills/commit/8320c1f575ea458ed9cde2b40f0ad2b363a48b66))
- **config:** seed commit conventions into AGENTS.md via initial-project ([8e9bcc1](https://github.com/xyzxyz442/x442-skills/commit/8e9bcc1bc001a0fca73f840c0e5a5cec656c1b86))
- enhance link-claude-skills.sh with stale link pruning functionality ([4b24328](https://github.com/xyzxyz442/x442-skills/commit/4b24328be71a15d7af5e0159c5f85c3f0f6f8d18))
- make graph hooks dedup-safe via thin wrappers ([2982036](https://github.com/xyzxyz442/x442-skills/commit/2982036d9c270bf091943ad3471604638eed23ee))
- make graph-hooks installer and verifier tool-generic with primary-owner wiring ([2d256eb](https://github.com/xyzxyz442/x442-skills/commit/2d256ebf2ce878a35957042c6d6f32b51cccd6b9))
- restructure skills and guidelines, consolidate Karpathy guidelines and update linking scripts ([7c80ac5](https://github.com/xyzxyz442/x442-skills/commit/7c80ac524b44f9ae03e6d258dc3e2cbcfa4b96fb))
- **setup:** add commitlint scaffolding to initial-project skill ([658ef1c](https://github.com/xyzxyz442/x442-skills/commit/658ef1c3f0bd340b8517244cc79d42753bde12ea))
- **setup:** add embed-provider resolver and setup-embeddings installer ([9ebad0c](https://github.com/xyzxyz442/x442-skills/commit/9ebad0c4739eed0b6f24b2f356195ae2757e2601))
- **setup:** add initial project files including configuration, instructions, and README ([eceaa8e](https://github.com/xyzxyz442/x442-skills/commit/eceaa8eca3d2da4542cb90df55fa0241eb65b414))
- **setup:** add register-cross-repo-graph support skill ([1c955b0](https://github.com/xyzxyz442/x442-skills/commit/1c955b0061412e76110a0ff59e04a9071815edee))
- **setup:** add repair-graph-hooks support skill ([dfccd9b](https://github.com/xyzxyz442/x442-skills/commit/dfccd9bc3e81ffa5c17dc596dee6fc65de5d5f29))
- **setup:** add setup-project-tooling skill for project dev tooling ([499f4d4](https://github.com/xyzxyz442/x442-skills/commit/499f4d4d86f931bf122f4d37ff54498fe2906bd1))
- **setup:** redesign register-cross-repo-graph around a manifest cascade ([bdd21b0](https://github.com/xyzxyz442/x442-skills/commit/bdd21b0e9938aa7fe25b5b6d57cb8af9388f4ebc))
- **setup:** report the embedding tier in verify-graph-hooks ([fb3dc83](https://github.com/xyzxyz442/x442-skills/commit/fb3dc8352777536f9c14bbf8a3ccb25e7b0e56f2))
- **setup:** restructure setup-project-tooling into common base + per-language layers ([b71ef62](https://github.com/xyzxyz442/x442-skills/commit/b71ef62d38e906cbc9fc2c55cd1775e53d609b1e))
- update AGENTS.md and README.md for Antigravity integration; add ANTIGRAVITY.md with specific instructions ([081ba66](https://github.com/xyzxyz442/x442-skills/commit/081ba66175b4878491ee66e83aec6e8196c8ceb5))
- update AGENTS.md for clarity and add engineering README for software skills ([ccd09b5](https://github.com/xyzxyz442/x442-skills/commit/ccd09b5e110e985025f60e080e7ae08a10913823))
- update README for iteration 1 status and initial-project skill details ([6a96da7](https://github.com/xyzxyz442/x442-skills/commit/6a96da77f5b85df7f96ae3df6cbfc85688430d62))

### 🐞 Bug Fixes

- **config:** tag releases as v-prefixed and write CHANGELOG.md ([56a9541](https://github.com/xyzxyz442/x442-skills/commit/56a954136028351b3e8001ca91889540a35416bb))
- rename script references for clarity in README and link-claude-skills.sh ([12b9ff2](https://github.com/xyzxyz442/x442-skills/commit/12b9ff2ba8fc58a1c7b5b1ee836ef9f0377d210f))
- **setup:** drop invalid graphify init from graph-hooks build hints ([c4d6a0c](https://github.com/xyzxyz442/x442-skills/commit/c4d6a0ce624050120f40b76d6942811fe69d469a))
- **setup:** gate embed behind a configured provider in the refresh hooks ([f006727](https://github.com/xyzxyz442/x442-skills/commit/f0067273bf1f1502345400ecf0542addff51d472))
- **setup:** root-anchor MANIFEST so manifest/ dirs are not ignored ([d8f9878](https://github.com/xyzxyz442/x442-skills/commit/d8f9878f76d3e065717ce2ab9e5b8cb8f03694d9))

### 📚 Documentation

- add references section to README for external sources related to skills ([5668c6d](https://github.com/xyzxyz442/x442-skills/commit/5668c6d288aa05be4e2a05dfe609b9295849b10e))
- adjust table formatting in engineering README for clarity ([1d17cff](https://github.com/xyzxyz442/x442-skills/commit/1d17cffc315f3a9312be7f854d775c99a349269b))
- **docs:** add graph-tools runtime guide ([5cc3f46](https://github.com/xyzxyz442/x442-skills/commit/5cc3f461607dd31e2a9ab468393b3dec414b7fe1))
- **docs:** document embeddings as an opt-in tier across the graph skills ([329e4c7](https://github.com/xyzxyz442/x442-skills/commit/329e4c7268244170a5a4ded020140450c60bbe15))
- **docs:** refresh README and skill catalog for shipped skills ([4eab6f2](https://github.com/xyzxyz442/x442-skills/commit/4eab6f2bd465c47d81c58df33f342e524b13da42))
- **docs:** register and cross-link the graph-hooks support skills ([9015047](https://github.com/xyzxyz442/x442-skills/commit/9015047bbad33e16f63d6c6a06f506a6962519bb))
- **docs:** sync setup-project-tooling description in skill index ([1fec2cb](https://github.com/xyzxyz442/x442-skills/commit/1fec2cb88d5cdd90de08ef0b524c1c2d9db23574))
- **docs:** sync the skill index and catalog with what ships ([09fb9b4](https://github.com/xyzxyz442/x442-skills/commit/09fb9b4dcdcdf7b7a1d423ecbe7666375d6fb024))
- enhance README for clarity on skill structure and installation instructions ([cd9a11b](https://github.com/xyzxyz442/x442-skills/commit/cd9a11b8896fdaffa7802c85ab75edd0fd3333a7))
- rewrite setup-graph-hooks SKILL.md as tool-generic with cited contracts ([469d5f5](https://github.com/xyzxyz442/x442-skills/commit/469d5f557082c174613df6566fe7f5e057e04e2f))
- **setup:** document cross-platform prerequisites for setup-graph-hooks ([4736aa2](https://github.com/xyzxyz442/x442-skills/commit/4736aa2476b231b99d010378c56c909500f4099c))
- update README and AGENTS.md for clarity on skill structure and status ([5574249](https://github.com/xyzxyz442/x442-skills/commit/5574249d84dec4b316f28f9ef4e202446d156273))

### 🏗️ Build System

- **config:** add gitattributes LF guard and expand ignore files ([95334ce](https://github.com/xyzxyz442/x442-skills/commit/95334ced68bbb9d7bee6a42884daddb840e10892))
- **config:** add lint-staged config for staged-file formatting ([21c01c2](https://github.com/xyzxyz442/x442-skills/commit/21c01c2cf32ee73b26911dc82908341aa611b656))

### 🧹 Miscellaneous Chores

- **ci:** remove commitlint workflow ([c51417a](https://github.com/xyzxyz442/x442-skills/commit/c51417a775823e4bcf0632deffaec6d35753967e))
- **config:** format shell scripts and ignore .venv ([6c8ef8f](https://github.com/xyzxyz442/x442-skills/commit/6c8ef8ff112d0ddc1085032e9951b5c615d5f032))
- **config:** point the CRG MCP server at local ollama embeddings ([2e6a3e7](https://github.com/xyzxyz442/x442-skills/commit/2e6a3e76e0a0a447a58fbe2adb4e930eafe6d90a))
- **deps:** add prettier-plugin-sh for shell script formatting ([8fe4010](https://github.com/xyzxyz442/x442-skills/commit/8fe4010e92a4b405943e8663b5edf1022dd53f11))
- dogfood setup-graph-hooks in this repo ([00d0ba2](https://github.com/xyzxyz442/x442-skills/commit/00d0ba2197ab50a697fcf8cc9d59cb2b97622d9f))
- dogfood tool-generic graph-hooks in this repo ([1846871](https://github.com/xyzxyz442/x442-skills/commit/18468713ba5c78c679616cef9677f3d39e4f1e18))
- **setup:** adopt commitlint with husky hook and CI workflow ([740fdc0](https://github.com/xyzxyz442/x442-skills/commit/740fdc07cf947a8abcff30e22c2eb8da2384e97d))
- **style:** apply prettier across the repo ([3cd980a](https://github.com/xyzxyz442/x442-skills/commit/3cd980a93368b270baed1a0e01fe0dff7e017fae))
- update .gitignore to include husky directory and remove commit-msg hook ([bc9ed1b](https://github.com/xyzxyz442/x442-skills/commit/bc9ed1bad5672682a8d72ffc2834638e643f2be7))
- update package.json for version bump and script enhancements ([d672e2a](https://github.com/xyzxyz442/x442-skills/commit/d672e2aa71d3d84361249b1bbc4b9c68d3249933))
