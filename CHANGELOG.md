# Changelog

## [0.12.0](https://github.com/xyzxyz442/x442-skills/compare/v0.11.4...v0.12.0) (2026-09-05)

### 🚀 Features

- **feature:** add the credential detection and redaction engine ([e1e40e5](https://github.com/xyzxyz442/x442-skills/commit/e1e40e51f4ebadcb3ccb731c09c85cfd46351f8e))
- **feature:** add the secret-guard AGENTS.md block and its splice ([15c0868](https://github.com/xyzxyz442/x442-skills/commit/15c0868625296963ec9248f3d01e7de0c57813c6))
- **feature:** add the secret-guard verifier ([695ef8f](https://github.com/xyzxyz442/x442-skills/commit/695ef8f8ef1cc3dc8b2814043e7764321e31c576))
- **feature:** add the setup-secret-guard installer and its settings merge ([129e0d8](https://github.com/xyzxyz442/x442-skills/commit/129e0d8543d3435bbf88cb015a805e3b97ae2b60))
- **feature:** converge the consent gate onto the shared credential engine ([0d97c2f](https://github.com/xyzxyz442/x442-skills/commit/0d97c2ff0e89f5c313b9abb836ec649f616cc13a))

### 🐞 Bug Fixes

- **bug:** degrade the consent gate to a bash reader instead of exiting open ([7cbd37a](https://github.com/xyzxyz442/x442-skills/commit/7cbd37ad0cdf1cf866608963577c971c3f865453))
- **bug:** let --dry-run show the whole plan and stop claiming it wired anything ([28afc16](https://github.com/xyzxyz442/x442-skills/commit/28afc1671e6d9286d25c953d99196b1f2a0a2697))
- **bug:** make the secret-guard installer executable ([c4d4ef6](https://github.com/xyzxyz442/x442-skills/commit/c4d4ef6bcf3b1c4f0b289ff7aabf4e0511172885))
- **bug:** ship the absolute-path deny anchors that were missing ([ad45b86](https://github.com/xyzxyz442/x442-skills/commit/ad45b86ddff6728f8f1252f7c4180c5b370d0de7))
- **bug:** tell a command from an argument that merely looks like one ([bff4834](https://github.com/xyzxyz442/x442-skills/commit/bff48340fddf9cd0512a33734cb0e09d609829bb))
- **graph-hooks:** stop inferring a cloud embedding provider from an ambient key ([c70e66f](https://github.com/xyzxyz442/x442-skills/commit/c70e66f935ebb985c23f69e0fb449a194503cb6b))
- **setup:** track the git hooks so worktrees actually run them ([e225550](https://github.com/xyzxyz442/x442-skills/commit/e22555016227100caf4fe4cf7ed89702dcb7c7bc))
- **test:** refresh the stale graph-hooks payload in every fixture ([3c71678](https://github.com/xyzxyz442/x442-skills/commit/3c716781ebdc7aec248c18b8512fa1d577a3ccb9))

### 📚 Documentation

- **adr:** record the upstream embedding-provider boundary as ADR 0007 ([d17e234](https://github.com/xyzxyz442/x442-skills/commit/d17e2347b55a6a5ec34a4974904da8696699b197))
- **docs:** add secret guard, detection and redaction to the glossary ([ebea10c](https://github.com/xyzxyz442/x442-skills/commit/ebea10c37f744f2fabb41c1e81e62424988a8f73))
- **docs:** index the setup-secret-guard skill ([8723147](https://github.com/xyzxyz442/x442-skills/commit/8723147deb9997fab528c0a8ab15fee9d9d1a953))
- **docs:** normalise masking and scrubbing onto redaction ([7db53fa](https://github.com/xyzxyz442/x442-skills/commit/7db53fa86057913e3a511d2b6fa2159316b1b8b1))
- **docs:** record one credential engine resolved through a cascade ([6e8f532](https://github.com/xyzxyz442/x442-skills/commit/6e8f532182529c7f63288315941ec06ebcb07173))
- **docs:** settle outbound export as refuse, and say to rotate ([549f18a](https://github.com/xyzxyz442/x442-skills/commit/549f18a450c493f006dfb88ca61618dfec4aae15))
- **graph-hooks:** document the providers this skill recognises but does not drive ([a9657db](https://github.com/xyzxyz442/x442-skills/commit/a9657db3f576566f67abdbe90acdffb34378ba43))

### 💅 Styles

- **other:** apply the formatting the worktree commits skipped ([608d3d6](https://github.com/xyzxyz442/x442-skills/commit/608d3d65dffe2b24171e50ebfd717b7f649e51a1))

### 🧪 Tests

- **graph-hooks:** guard the embedding-provider defects with an offline eval ([7e5f32e](https://github.com/xyzxyz442/x442-skills/commit/7e5f32ecb3b71af55a198a75dd8e5e9fbfc25ecf))
- **test:** add the setup-secret-guard harness with leak cases ([62fc1e4](https://github.com/xyzxyz442/x442-skills/commit/62fc1e4fd21d5b7f607a30a287b843bf7992e18e))
- **test:** assert the rewritten command actually runs and masks ([104b6bc](https://github.com/xyzxyz442/x442-skills/commit/104b6bc8385ce8aa75c910c90965d806bea71952))
- **test:** grade the over-firing half, not only the leaks ([b69f932](https://github.com/xyzxyz442/x442-skills/commit/b69f932bad3ab33d5b473ef0c194b9e012b0b164))
- **test:** pin the credential-read probe instead of inheriting the machine's guard ([05f914c](https://github.com/xyzxyz442/x442-skills/commit/05f914c3a43afc362fb292a34242fb93983928ce))

### 🧹 Miscellaneous Chores

- **graph-hooks:** lift this repo's own install to payload 3 ([d040025](https://github.com/xyzxyz442/x442-skills/commit/d040025c2ff63d3c995a95dfc43bc81009a2e2dc))

## [0.11.4](https://github.com/xyzxyz442/x442-skills/compare/v0.11.3...v0.11.4) (2026-09-04)

### 🐞 Bug Fixes

- **config:** lint-staged skipped JavaScript too ([21a864c](https://github.com/xyzxyz442/x442-skills/commit/21a864c88a69509698196999272c0d600e0a3e41))
- **config:** stop commitlint warning about footers on ordinary prose ([09abfa8](https://github.com/xyzxyz442/x442-skills/commit/09abfa851529cf073d96320f5d48f16f600dbbfb))

## [0.11.3](https://github.com/xyzxyz442/x442-skills/compare/v0.11.2...v0.11.3) (2026-09-04)

### 🐞 Bug Fixes

- **config:** lint-staged never checked shell, the language this repo is written in ([1f67c1a](https://github.com/xyzxyz442/x442-skills/commit/1f67c1aa8ca15f2edd0e117e5363e8022ee658f5))

## [0.11.2](https://github.com/xyzxyz442/x442-skills/compare/v0.11.1...v0.11.2) (2026-09-04)

### 🐞 Bug Fixes

- **bug:** close the unknown-flag class at its fifth site, cmd_list ([c48d045](https://github.com/xyzxyz442/x442-skills/commit/c48d04532219ccb52441661d549a465ee52cdc13))

## [0.11.1](https://github.com/xyzxyz442/x442-skills/compare/v0.11.0...v0.11.1) (2026-09-04)

### 🐞 Bug Fixes

- **bug:** refuse an unknown flag instead of swallowing it ([102fc2c](https://github.com/xyzxyz442/x442-skills/commit/102fc2c9c6e36642863190c6aff598ccb6150f9b))
- **test:** freeze the payload once per selftest run ([b185105](https://github.com/xyzxyz442/x442-skills/commit/b1851057acb20deaf401b54d0b54ba54827df484))

### 📚 Documentation

- **docs:** correct manifest naming and harness-count drift after v0.11.0 ([1fe69f6](https://github.com/xyzxyz442/x442-skills/commit/1fe69f67821263abba250c413d3150884afb2fc8))

## [0.11.0](https://github.com/xyzxyz442/x442-skills/compare/v0.10.0...v0.11.0) (2026-09-04)

### 🚀 Features

- **build:** add --personal opt-in to the skill link scripts ([d903c0f](https://github.com/xyzxyz442/x442-skills/commit/d903c0f8864607b2247c954e5ea69153b443f87b))
- **ci:** enforce the standalone rule on pre-commit and in CI ([47067a7](https://github.com/xyzxyz442/x442-skills/commit/47067a76c7a114d7716e6d9ccb2559928b5306a2))
- **feature:** --local-wiring, for a member of a board it does not own ([bc7a015](https://github.com/xyzxyz442/x442-skills/commit/bc7a0156d52906a1b775a9727efa455c20b22e13))
- **feature:** add a ranked agent ladder, delegation modes, and kind-based routing ([82b4574](https://github.com/xyzxyz442/x442-skills/commit/82b4574f39c5ef1c71a02bb3246d3b030afa1ec8))
- **feature:** add handoff export for offline execution briefs ([8fc2030](https://github.com/xyzxyz442/x442-skills/commit/8fc2030a7664a3cac2bfd8f2315a768563bcabcf))
- **feature:** add per-vendor adapters for delegated dispatch ([3e6c07e](https://github.com/xyzxyz442/x442-skills/commit/3e6c07ee7844cf38a737c7562a2c0ba9820d5218))
- **feature:** add repair-handoff ([58e3541](https://github.com/xyzxyz442/x442-skills/commit/58e3541c84554de245b969f45c53c1d5b4925b9f))
- **feature:** add repo identity helpers and a sourceable guard to the handoff CLI ([bcc824e](https://github.com/xyzxyz442/x442-skills/commit/bcc824eadab01178f8b79895557a196d7c7ecfa2))
- **feature:** add run-delegate-agent skill ([b74b768](https://github.com/xyzxyz442/x442-skills/commit/b74b76816cef4d765a67984a4bd577b0366c87d2))
- **feature:** add setup-delegate-agent skill ([5ef15cb](https://github.com/xyzxyz442/x442-skills/commit/5ef15cb4982f8a149d5fa59bbe6d6f8739e14b63))
- **feature:** add the handoff brief template and section extraction ([2687005](https://github.com/xyzxyz442/x442-skills/commit/268700589e4bc266867f2058fafd67ac85ab602b))
- **feature:** adopt a CLAUDE_CONFIG_DIR as a delegation backend profile ([001b694](https://github.com/xyzxyz442/x442-skills/commit/001b69444c2063edb25a42ac35600b4a6edaf9cf))
- **feature:** document schema — typed edges, environment, role, and queryable evidence ([8e02457](https://github.com/xyzxyz442/x442-skills/commit/8e0245762a144331d88ce17c6fb6d9cbe36a95f8))
- **feature:** enforce the no-secret rule at both dispatch boundaries ([eb4b864](https://github.com/xyzxyz442/x442-skills/commit/eb4b864058d4d4d8987540f8232d3bc8b5011cdc))
- **feature:** gate credential exposure asymmetrically in the consent hook ([480ce96](https://github.com/xyzxyz442/x442-skills/commit/480ce96d9fcdd49099b323c0d445a60ccad8cdca))
- **feature:** generate the orchestrator children table from child frontmatter ([40c8e6b](https://github.com/xyzxyz442/x442-skills/commit/40c8e6b1613ba48a78f2a8b07d46adbda3ecc216))
- **feature:** install machinery and render the roster from the resolved cascade ([1100c23](https://github.com/xyzxyz442/x442-skills/commit/1100c2379a4ce1545c1c39a87f371a8acb72ef67))
- **feature:** make the handoff board shareable — remote, root-commit identity, push-CAS leases ([b4fa5b4](https://github.com/xyzxyz442/x442-skills/commit/b4fa5b4f87a3440910197845ffb28f8e84cab99f))
- **feature:** reach local models through copilot BYOK, and name silent tool-call failures ([fba0504](https://github.com/xyzxyz442/x442-skills/commit/fba050497f90a4c278a4d57bcb154634da4aec67))
- **feature:** read a returned brief back onto the board without trusting its status ([6d53fe3](https://github.com/xyzxyz442/x442-skills/commit/6d53fe3a9925c92e0f2cf5a910eec760908a5258))
- **feature:** render the schema — environment ladder, spec links, advisory backlinks ([4c7f517](https://github.com/xyzxyz442/x442-skills/commit/4c7f517c09e57db8dcc3aad93fba391efe07fb3d))
- **feature:** resolve cross-repo brief identity from the group manifest ([48e0b28](https://github.com/xyzxyz442/x442-skills/commit/48e0b28def5bab0a11d2b0673ccbeb52207eb551))
- **feature:** schema versioning and gated migration ([a5d0884](https://github.com/xyzxyz442/x442-skills/commit/a5d088419bd5159d8dd45bd6e4b1483967d02c14))
- **feature:** security model — sensitivity, write-path scanning, outbound redaction ([145934e](https://github.com/xyzxyz442/x442-skills/commit/145934e01c680bb3e8159be56571a5ea27709f17))
- **feature:** separate board from binary — dispatcher, CLI ladder, board override ([f59d6b9](https://github.com/xyzxyz442/x442-skills/commit/f59d6b97de35bb29648306a35a6a42562140a25a))
- **feature:** show a repo provider in the brief instead of a bare host ([d049acb](https://github.com/xyzxyz442/x442-skills/commit/d049acb82955cf9aff955f3f057678072b98ab44))
- **feature:** split the roster into register-delegate-agents ([5c1834d](https://github.com/xyzxyz442/x442-skills/commit/5c1834d736f33cebcd9c9b93f11261a82503b49c))
- **feature:** surface delegated and review-pending handoffs in list and release ([6baac0e](https://github.com/xyzxyz442/x442-skills/commit/6baac0e96e5a0b05efccb508df6837e459348efc))
- **feature:** verify --json — stable findings for the advisory half of the board ([448ff19](https://github.com/xyzxyz442/x442-skills/commit/448ff197bb99f764256aeddc6a042bdcd2216779))
- **setup:** add a payload-version stamp to setup-delegate-agent ([1f6d3d3](https://github.com/xyzxyz442/x442-skills/commit/1f6d3d3b9c569c8d9d84bf07f5c8099038906e37))
- **setup:** add the handoff config precedence resolver ([69db71d](https://github.com/xyzxyz442/x442-skills/commit/69db71d7186c2181cf93834fae400a6d2b1cd1f8))
- **setup:** install the brief template and bump the handoff payload to 3 ([cf8ba09](https://github.com/xyzxyz442/x442-skills/commit/cf8ba09b649afe406dcf19a68a57d50c8562b894))
- **setup:** migrate hook-command env into a repo config ([03d3d54](https://github.com/xyzxyz442/x442-skills/commit/03d3d544b745d5c2a76629b6019c8c4882a321a6))
- **setup:** notice unhealthy board state at session start ([f69c971](https://github.com/xyzxyz442/x442-skills/commit/f69c97159072b82fd5f42c47904ed43f56586ff6))
- **setup:** report payload drift from the verifiers ([1d48687](https://github.com/xyzxyz442/x442-skills/commit/1d48687eeb5f8dce5f29568235c2d10de7a74d45))
- **setup:** report the effective handoff config from the verifier ([1ad01be](https://github.com/xyzxyz442/x442-skills/commit/1ad01be1b1855917aaa3b478b189e01ecf24be77))
- **setup:** resolve hook identity from repo config, not the command line ([b249c07](https://github.com/xyzxyz442/x442-skills/commit/b249c07790e3e745d1093b60ad406ac2a50f7d05))
- **setup:** stamp installed payloads with a version ([f2ca16f](https://github.com/xyzxyz442/x442-skills/commit/f2ca16f198ed2e6b769cf9af760855219891c1a2))
- **test:** finish the --json rollout — all 7 verifiers now emit findings ([08a4b8f](https://github.com/xyzxyz442/x442-skills/commit/08a4b8f888710e82de52c3fe0c7fadbfe51a0746))
- **test:** give three more verifiers a --json findings channel ([9490b09](https://github.com/xyzxyz442/x442-skills/commit/9490b094534a4e1be8353a7611dc3b29d5d39f1f))

### 🐞 Bug Fixes

- **bug:** a continue in a case arm exempted archived docs from the schema count ([a79f89d](https://github.com/xyzxyz442/x442-skills/commit/a79f89d6b80664a7ba2c023e525e5b5c490be326))
- **bug:** claim before stamping in handoff export, guard pipe and empty REPO_DIR ([440374b](https://github.com/xyzxyz442/x442-skills/commit/440374ba22c9afe89a4442cbee1c53edbe16c7f2))
- **bug:** clear the lease on every handoff release path ([ae2c39b](https://github.com/xyzxyz442/x442-skills/commit/ae2c39bb58edb98b59c80b20a72c09ac5ae1cf70))
- **bug:** close frontmatter injection and delegation gaps found in whole-branch review ([0761cfc](https://github.com/xyzxyz442/x442-skills/commit/0761cfcea3f16067619d440b4418df4a4484e875))
- **bug:** close import --result's colon-fold, secret-scan, and awk-escaping gaps ([2840f61](https://github.com/xyzxyz442/x442-skills/commit/2840f61a9ba3accc4071cd34c83ddebd3423712f))
- **bug:** detect hook command drift, and resolve verifier helpers absolutely ([5bd102b](https://github.com/xyzxyz442/x442-skills/commit/5bd102b70814cadd1b3c64d553836fe7c6bdeae0))
- **bug:** doc.schema.behind counted an archive that migrate cannot reach ([1e39912](https://github.com/xyzxyz442/x442-skills/commit/1e399122ddf7b64adb9284ae8e076061b82eba77))
- **bug:** fail loudly when a done handoff cannot be archived ([994092e](https://github.com/xyzxyz442/x442-skills/commit/994092ec9a809efc42fffb6348cd326932e05b2e))
- **bug:** honor board config for the lease TTL ([b5c65e5](https://github.com/xyzxyz442/x442-skills/commit/b5c65e5df5a96be99bcc81c215e2b0d9253cd0ff))
- **bug:** hook merges own their groups — stop deleting each other's ([c66727d](https://github.com/xyzxyz442/x442-skills/commit/c66727d556397044230513bae4279391b88ae683))
- **bug:** let a same-account delegate authenticate, and stop gating delegates ([6afadbe](https://github.com/xyzxyz442/x442-skills/commit/6afadbe2f32ec559f47838849425a147a48c7ef8))
- **bug:** make a real dispatch reach the agent on a stock macOS ([544cbce](https://github.com/xyzxyz442/x442-skills/commit/544cbce129a55dfeeca7fd30a1ec10addadd4330))
- **bug:** map copilot dispatches onto permission kinds, not tool names ([45d0602](https://github.com/xyzxyz442/x442-skills/commit/45d0602ae4fb3087e2e5f0a36c63dea564ceba5e))
- **bug:** read board config through the resolver, not by grepping a filename ([5e4a3db](https://github.com/xyzxyz442/x442-skills/commit/5e4a3dbcc7eaf19c7fd3bbf73f938a240ce5f57b))
- **bug:** reject a trailing or flag-shaped value in setup-handoff's arg loop ([71517c6](https://github.com/xyzxyz442/x442-skills/commit/71517c6e46e3ab3ef72aecda6c034263d18c2223))
- **bug:** report provider unknown when a repo has no origin remote ([9ca8959](https://github.com/xyzxyz442/x442-skills/commit/9ca895964ab3568fb991c244de00b629554b656b))
- **bug:** rewrite the AGENTS.md handoff block instead of only injecting it ([606fdd8](https://github.com/xyzxyz442/x442-skills/commit/606fdd8413643f2a04f7e2a36ae0d49b9fd3bb59))
- **bug:** say when a grouped handoff board has no section in scope ([80180ac](https://github.com/xyzxyz442/x442-skills/commit/80180ac1352b002d0310dec3e26d29cdc621e77b))
- **bug:** split handoff --children on commas only and resolve legacy ids ([a9b63db](https://github.com/xyzxyz442/x442-skills/commit/a9b63dbfaae464dc9e8d591acea209d506f46b43))
- **bug:** stop eval-of-config from masking handoff_config_load failures ([645691b](https://github.com/xyzxyz442/x442-skills/commit/645691b967c754945d903667c804b61f8a43c1bf))
- **bug:** stop export refusing on a lease the acting session already holds ([2a81f6a](https://github.com/xyzxyz442/x442-skills/commit/2a81f6a18e27e98d7bca646492bd9a3e5bbcf7c6))
- **bug:** stop the installer rewriting tool configs that did not change ([9a196c4](https://github.com/xyzxyz442/x442-skills/commit/9a196c474664d24b1f5bd5d06048a948f686b4a5))
- **bug:** the graph verifier spent the operator's grep allowance on itself ([d0427bb](https://github.com/xyzxyz442/x442-skills/commit/d0427bb819b97ddf8bd5ad5ee192c6c5545682c2))
- **bug:** the legacy boardPath alias silently beat the canonical board key ([8ea6409](https://github.com/xyzxyz442/x442-skills/commit/8ea6409037642779416b6146ac519fef1ff2f51c))
- **bug:** the verifier only found a board whose directory was named handoff ([00888c0](https://github.com/xyzxyz442/x442-skills/commit/00888c0e8ef2054d605e218066acd39fa2a34062))
- **config:** pin fast-uri past the 4.x advisories ([81db78f](https://github.com/xyzxyz442/x442-skills/commit/81db78f896acc4abbff25754df670853f476245f))
- **config:** point this repo's handoff board at itself ([b9eef0a](https://github.com/xyzxyz442/x442-skills/commit/b9eef0af1cc84a17f800d2bd7efa6aa9974325e6))
- **docs:** make the orphaned-delegation check discoverable in repair-handoff ([97efdb3](https://github.com/xyzxyz442/x442-skills/commit/97efdb3085e3744f8aac975a650690ffca3d425d))
- **docs:** remove colons from skill frontmatter values ([259d481](https://github.com/xyzxyz442/x442-skills/commit/259d48116ecda60de6427675276a6a15cf871648))
- **docs:** replace foreign project names leaked into the config-scopes docs ([d0d6c90](https://github.com/xyzxyz442/x442-skills/commit/d0d6c9029965781ef94ec1d6bb1c083622caaf73))
- **docs:** update generation timestamp in handoff index ([133cff3](https://github.com/xyzxyz442/x442-skills/commit/133cff3dc9c4005daf76d7336f2546a0bf2fc968))
- **feature:** a write on a board that is behind offers the migration ([1b6394e](https://github.com/xyzxyz442/x442-skills/commit/1b6394e208fc7be0b1cc53616f4e023e47ea199c))
- **feature:** idempotent AGENTS.md splice, claim exits 0, graders on current filenames ([856e241](https://github.com/xyzxyz442/x442-skills/commit/856e2414ea673dffa8a60469c506398fa27608ce))
- **feature:** refuse silent downgrades — install gate and board schema gate ([5306379](https://github.com/xyzxyz442/x442-skills/commit/5306379d9360bcd7ff874fd2344ce289351f074a))
- **feature:** the other three AGENTS.md splices, and the assertion class that hid them ([64b4332](https://github.com/xyzxyz442/x442-skills/commit/64b433264f9fcd546b879ef4407c5109fb52c710))
- **setup:** fail closed loudly when a board has no config.sh ([ad638bf](https://github.com/xyzxyz442/x442-skills/commit/ad638bf1f07ecf5a08edb9b916325b7e5126794c))
- **setup:** fall back to the resolved group when HANDOFF_GROUP is unset ([30442b4](https://github.com/xyzxyz442/x442-skills/commit/30442b49fc2b40c33d1d365f6f4657c42ff0b449))
- **setup:** guard nulls and forbid silent repo-config drop without python3 ([76b099d](https://github.com/xyzxyz442/x442-skills/commit/76b099daac2fe64c39b799c9d7f5c3099f1b5f79))
- **setup:** make the prefix-migration refusal all-or-nothing per file ([4185fb4](https://github.com/xyzxyz442/x442-skills/commit/4185fb49654bb25e5d5422ea7fd61117761a6cae))
- **setup:** merge board config.json instead of overwriting it ([9e85911](https://github.com/xyzxyz442/x442-skills/commit/9e85911acf34678c00f9b2b994f538a060699a82))
- **setup:** name the actual cause in the config-missing notice ([3aa7775](https://github.com/xyzxyz442/x442-skills/commit/3aa77758c610df0664ffd66cde2f3d3e964b0778))
- **setup:** propagate the frontmatter-injection fix to every installed handoff board ([aa9d938](https://github.com/xyzxyz442/x442-skills/commit/aa9d93884ae34662151b05a761b42a0f0d2a7d46))
- **setup:** propagate the provider frontmatter and bump the payload to 5 ([40e15a4](https://github.com/xyzxyz442/x442-skills/commit/40e15a4903c6454c4fec727858c11cbdb2481342))
- **setup:** propagate the provider-unknown fix and bump the payload to 6 ([197f4c6](https://github.com/xyzxyz442/x442-skills/commit/197f4c699a6b2a5bb16d5626b31139a9f3f81838))
- **setup:** refresh this repo's stale handoff wiring by re-running the installer ([56b60e5](https://github.com/xyzxyz442/x442-skills/commit/56b60e5e1a63de6eef6c7688ca10c3006ebe589d))
- **setup:** report a malformed config.json as one FAIL, not two ([d633c78](https://github.com/xyzxyz442/x442-skills/commit/d633c78788ac9470ddb0f2d575188a2dcee7752e))
- **setup:** stop a --kind value from swallowing the next flag in hooks.sh ([74b1776](https://github.com/xyzxyz442/x442-skills/commit/74b1776f644ca4878bc3d529066af41c931c58eb))
- **setup:** stop the unknown-key check from PASSing on unparseable config.json ([a3aa1e9](https://github.com/xyzxyz442/x442-skills/commit/a3aa1e9b698d51c33ebb65675105dc8178426b40))
- **setup:** stop write_board_config wiping a shared board's section config ([986e562](https://github.com/xyzxyz442/x442-skills/commit/986e562c7a5f2c0e1a3e4476d1120b1a1c2ccd31))
- **setup:** write repo config from live env on fresh cross-repo installs ([0df58fc](https://github.com/xyzxyz442/x442-skills/commit/0df58fc9771940011f4f8e3491a9e40802648124))
- **test:** keep case out of command substitution so prettier cannot break the selftest ([53bf6fb](https://github.com/xyzxyz442/x442-skills/commit/53bf6fb7a8ef56118b20e1cfe7cd774f9f890a1f))
- **test:** stop the .gitignore swallowing a harness fixture ([387d623](https://github.com/xyzxyz442/x442-skills/commit/387d62363dd2119e05cfe963c3763bd8b87b5559))
- **test:** stop the verified_at check failing on a run that crosses midnight ([54d2149](https://github.com/xyzxyz442/x442-skills/commit/54d214927a0206d4b3bb8076f9717ceb59671de3))

### 📚 Documentation

- **docs:** add an AGENTS.md block-drift probe to repair-handoff step 2 ([a287f13](https://github.com/xyzxyz442/x442-skills/commit/a287f13dfea3e109ac260f7018763d98eb6dd48a))
- **docs:** add compaction-brief guidance to run-handoff ([72d7666](https://github.com/xyzxyz442/x442-skills/commit/72d7666c6a96b25803921713f411e52e2d30b6f2))
- **docs:** add the delegate-handoff skill and document the delegation loop ([60f8f33](https://github.com/xyzxyz442/x442-skills/commit/60f8f333121c9ecc6dbfdc597027e016ab110cd3))
- **docs:** archive the agents-block-drift handoff as done ([e175361](https://github.com/xyzxyz442/x442-skills/commit/e175361eaac6b8ac6e94e481e37eb0a09acd1daf))
- **docs:** archive the hook-command-drift handoff as done ([f1b1430](https://github.com/xyzxyz442/x442-skills/commit/f1b1430d8bd937805592ed126f1cadb5586c5bb0))
- **docs:** archive the installer-write-churn handoff as done ([63db3ba](https://github.com/xyzxyz442/x442-skills/commit/63db3ba06b59528ac0dc48f191aee918209c5ee5))
- **docs:** catalog register-delegate-agents and restate the pair's scope ([99470ec](https://github.com/xyzxyz442/x442-skills/commit/99470ecced9a2c1ff05ae6d5d8ab267f78040915))
- **docs:** catalog the delegate-agent skills under personal/ ([f211fc7](https://github.com/xyzxyz442/x442-skills/commit/f211fc7da410a7338ad4fa37200337d27ef80bd8))
- **docs:** commit the ADR-0001 companion documents ([480e967](https://github.com/xyzxyz442/x442-skills/commit/480e96790b3b30d90adb67c5962a73fe2bada1ef))
- **docs:** design offline handoff delegation via export and import ([fd0457a](https://github.com/xyzxyz442/x442-skills/commit/fd0457a0016f24f8f2879be6ea4fcbfaab12cbf2))
- **docs:** design the handoff configuration scopes ([d060c02](https://github.com/xyzxyz442/x442-skills/commit/d060c0248a559d0b56778bd4ff6fc42567cf0b6a))
- **docs:** document the handoff configuration scopes ([d1ed5c6](https://github.com/xyzxyz442/x442-skills/commit/d1ed5c6543fa625a7d50d9ffd6543e6cdd3bb794))
- **docs:** file handoffs for the board version guard, env naming, and deprecations ([0edb74f](https://github.com/xyzxyz442/x442-skills/commit/0edb74fc1db2b5509f34176d89098a026ff655de))
- **docs:** file the two handoffs deferred from the delegation review ([006f9ba](https://github.com/xyzxyz442/x442-skills/commit/006f9ba53429a6cfb3fc2c4f2b62deb8e28ae80c))
- **docs:** fix stale handoff index and example claims found in the doc sweep ([f9f5c09](https://github.com/xyzxyz442/x442-skills/commit/f9f5c09c22fb684f68615510659f5e221b05cd37))
- **docs:** pass HANDOFF_GROUP in the cross-repo board commands ([3bc559d](https://github.com/xyzxyz442/x442-skills/commit/3bc559da8cc2f221f76c481fd07613c48c3cf615))
- **docs:** plan the handoff config scopes implementation ([ce4a9ec](https://github.com/xyzxyz442/x442-skills/commit/ce4a9ecc8f13a6eb6eee0c44675d7c1a9a5e937a))
- **docs:** plan the offline handoff delegation implementation ([a1c5a91](https://github.com/xyzxyz442/x442-skills/commit/a1c5a91c1283534fabb13e88ce16bd89766ac015))
- **docs:** record the handoff suite redesign decisions and the domain glossary ([ae8bdff](https://github.com/xyzxyz442/x442-skills/commit/ae8bdffa26062f7c1d008fa9690c959df96d1a83))
- **docs:** record when a setup skill owes a repair sibling or a version stamp ([15bac52](https://github.com/xyzxyz442/x442-skills/commit/15bac52cfdcf8ed22990f74ebffc9f602cc9de15))
- **docs:** settle repo vs repoName — config keys name from their own layer ([16ca627](https://github.com/xyzxyz442/x442-skills/commit/16ca627de951b94eaac6dbd166a8efc5904285d0))
- **docs:** switch the handoff config design to JSON ([d467d79](https://github.com/xyzxyz442/x442-skills/commit/d467d792e1da51df705491bb5da27abc7193af3a))

### 💅 Styles

- **docs:** format the last unformatted archive doc ([862f8da](https://github.com/xyzxyz442/x442-skills/commit/862f8da554dbeddde5723e2537be256d03099807))
- **docs:** normalise markdown and settings formatting ([7fa972e](https://github.com/xyzxyz442/x442-skills/commit/7fa972e0efb84b8b90170693ceb2e466367442c5))
- **style:** apply black and clear the one ruff finding ([bfaeb3b](https://github.com/xyzxyz442/x442-skills/commit/bfaeb3b02f60fc230190016d3598bedc5136ff90))
- **style:** format the last four files prettier flagged ([bfad6a2](https://github.com/xyzxyz442/x442-skills/commit/bfad6a29fc24879645f9363c192689e9a02b887c))

### 🧼 Code Refactoring

- **config:** one handoff.json at every layer, replacing five config filenames ([cab1cfa](https://github.com/xyzxyz442/x442-skills/commit/cab1cfa92066393285032541eecef3283ab58fef))
- **config:** the board path is an argument, not an env var ([e81862c](https://github.com/xyzxyz442/x442-skills/commit/e81862ca677f3c955f62f0f14cc3be172b267022))
- **feature:** resolve delegation agents from an .agents/delegate.json cascade ([9147c37](https://github.com/xyzxyz442/x442-skills/commit/9147c379e86d4e9a6edb5c0941a2b1262539d157))

### 🧪 Tests

- **test:** add setup-delegate-agent harness workspace ([124ac65](https://github.com/xyzxyz442/x442-skills/commit/124ac654546532c337c30ffa1d9112c08ce9ed9a))
- **test:** add the delegate-handoff eval workspace ([c981144](https://github.com/xyzxyz442/x442-skills/commit/c9811441f5b6ea46c7931a1fcbb0c9df6c5fcee0))
- **test:** add the legacy-config migration eval and repair the suite ([05b195b](https://github.com/xyzxyz442/x442-skills/commit/05b195b248ea7e7efe455ab8d81b261aefaafee2))
- **test:** add the repair-handoff eval workspace ([043be90](https://github.com/xyzxyz442/x442-skills/commit/043be90a13abf22c8653fd2196aa833036c07d39))
- **test:** bring the handoff fixtures to the shipped payload version ([1e84d63](https://github.com/xyzxyz442/x442-skills/commit/1e84d63a24699ff195023f1ee728dc61df80fd76))
- **test:** convert handoff fixtures to JSON config and resync mirrors ([4ef2a87](https://github.com/xyzxyz442/x442-skills/commit/4ef2a8738dfc28cc1fef3693dcdd63acf25fb09a))
- **test:** give the last four shipped modules a --selftest ([a3e66d3](https://github.com/xyzxyz442/x442-skills/commit/a3e66d3d4241bed90452adc9cd2b29d74f928911))
- **test:** grade the advisory half — evals for the checks that never fail ([02bd891](https://github.com/xyzxyz442/x442-skills/commit/02bd891a6cde7713921ae41b9564d51ba64779fa))
- **test:** grade the schema count that under-reported for two payload versions ([a8604e7](https://github.com/xyzxyz442/x442-skills/commit/a8604e7a3a268438440e307d605b6aadeb286874))
- **test:** rebuild the harness for the cascade and credential rules ([903200f](https://github.com/xyzxyz442/x442-skills/commit/903200faf1ffc5768355f0ad4ec6a0b31ff8e1c3))
- **test:** refresh setup-handoff fixtures with the repo-level handoff.json ([0955f84](https://github.com/xyzxyz442/x442-skills/commit/0955f848263b98c17dbf627681a5dce05c236cec))
- **test:** selftest the three cascade resolvers, and the containment bug they shared ([9ad7759](https://github.com/xyzxyz442/x442-skills/commit/9ad77599cb96da2513618a93649f5992e50aa885))
- **test:** stamp wired fixtures and resync the hooks.sh mirrors ([42f4aa5](https://github.com/xyzxyz442/x442-skills/commit/42f4aa522a517e15d248313cf231dced8be0cc48))
- **test:** the two blocked eval cases, and the ladder defect they exposed ([64adaf1](https://github.com/xyzxyz442/x442-skills/commit/64adaf1202f732d16a141313109006355780a2b7))
- **test:** update fixture briefs to the provider frontmatter format ([18ab8d2](https://github.com/xyzxyz442/x442-skills/commit/18ab8d21e140f2f44c449af1022d09ba06785ac0))

### 🏗️ Build System

- **config:** lint python with a pinned toolchain, not a uv project ([77e6604](https://github.com/xyzxyz442/x442-skills/commit/77e6604d90a325a78b3e437ab5625c7e9b36deac))

### 🧹 Miscellaneous Chores

- **config:** bring this repo's own board onto the JSON config ([8b52947](https://github.com/xyzxyz442/x442-skills/commit/8b52947f7ff27bf7b6c037ce5daf588a45e87bc0))
- **config:** exclude repair-handoff fixtures from prettier ([f78c5c5](https://github.com/xyzxyz442/x442-skills/commit/f78c5c569a232e5e8c4786af36873739bfed6094))
- **config:** gitignore the per-machine handoff board wiring ([e81660b](https://github.com/xyzxyz442/x442-skills/commit/e81660beb766104f6b58a2d487e24c33a5a63f59))
- **config:** gitignore the renamed per-machine board wiring ([e668f1c](https://github.com/xyzxyz442/x442-skills/commit/e668f1c99fa2aedd410291e8ee6a34db9eadc755))
- **config:** re-sync the fixture READMEs after prettier reformatted the payload ([47dc4aa](https://github.com/xyzxyz442/x442-skills/commit/47dc4aa61f32efa3e84f677e8b454f7784a401a4))
- **config:** remove this repo's own handoff board install ([dc9469e](https://github.com/xyzxyz442/x442-skills/commit/dc9469e4b67b50ad00206c85dea0bcd58e2a0c6d))
- **config:** stamp this repo's own skill installs ([146e6fc](https://github.com/xyzxyz442/x442-skills/commit/146e6fc5773185ccd4892b96d5fcb3b3c779b64a))
- **feature:** re-sync the vendored fixture payloads to v15 ([bcd7808](https://github.com/xyzxyz442/x442-skills/commit/bcd7808e506501dff090f86cde7a2bb6323f573f))

## [0.10.0](https://github.com/xyzxyz442/x442-skills/compare/v0.9.0...v0.10.0) (2026-08-14)

### 🚀 Features

- **feature:** detect any OpenAI-compatible embedding backend ([e942e6a](https://github.com/xyzxyz442/x442-skills/commit/e942e6a4476d5ae65cc48900830ad9b8cd0cd20a))
- **feature:** warn on embedding-config drift at session start ([d7fc319](https://github.com/xyzxyz442/x442-skills/commit/d7fc319696b9c34743c5421f8944eefca37a0e4b))

### 🐞 Bug Fixes

- **bug:** scope code-review-graph install to the wired tools ([ef1bfb1](https://github.com/xyzxyz442/x442-skills/commit/ef1bfb122b68b1bdc8155437afbff8893313c0a2))
- **bug:** scope MCP re-registration in repair-graph-hooks ([9ac6ff1](https://github.com/xyzxyz442/x442-skills/commit/9ac6ff1c01e08588b67a6873883b212e243cff13))

### 📚 Documentation

- **docs:** document backend choice, the health notice, and fix stale routing ([aac7a27](https://github.com/xyzxyz442/x442-skills/commit/aac7a272e94b647fc980bea75de152c3b39516ff))
- **docs:** fix both duplicate-refresh-owner commands in the build guide ([94847aa](https://github.com/xyzxyz442/x442-skills/commit/94847aa4d135fa3145d83532b71c7838abf844d4))
- **docs:** sync the engineering-suite handoff for v0.10.0 ([8d68814](https://github.com/xyzxyz442/x442-skills/commit/8d688143db320a00dc454e0c24b3b9cbce668282))
- **docs:** sync the engineering-suite handoff for v0.9.0 ([6a85127](https://github.com/xyzxyz442/x442-skills/commit/6a851276b88b4447afc9370e145b7ade3c798757))

### 🧪 Tests

- **test:** sync graph-hooks copies with the session-context notice ([3f9d891](https://github.com/xyzxyz442/x442-skills/commit/3f9d89197cf5685607b3526538133711ab63fa4f))
- **test:** sync graph-hooks fixtures with the new core payload ([ba4e77d](https://github.com/xyzxyz442/x442-skills/commit/ba4e77d1e032cc1266c327012ea3902df332ba13))

### 🧹 Miscellaneous Chores

- **config:** point the graph MCP read path at lm-studio ([15de3fc](https://github.com/xyzxyz442/x442-skills/commit/15de3fcee1d3a02d4c949ba694f92187ffa26a01))
- **deps:** bump release-it to 21.0.2 ([b078bfd](https://github.com/xyzxyz442/x442-skills/commit/b078bfd856e116ecef59bb50658cf734775c8923))
- **deps:** update ip-address version constraints in workspace configuration ([187dfdd](https://github.com/xyzxyz442/x442-skills/commit/187dfdd5805d6e5ca364528a62a569ce54b9a0a6))

## [0.9.0](https://github.com/xyzxyz442/x442-skills/compare/v0.8.0...v0.9.0) (2026-08-04)

### 🚀 Features

- **setup-graph-hooks:** route the graph by intent, assert one embedder owns the index ([09a544d](https://github.com/xyzxyz442/x442-skills/commit/09a544d1c0080c81068ceb55ccf09e5ebed342e5))

### 📚 Documentation

- **docs:** sync routing docs and harness fixtures to the intent lanes ([ba9c09c](https://github.com/xyzxyz442/x442-skills/commit/ba9c09cd85d422b71231bacad0facfc692ae4e88))
- **docs:** sync the engineering-suite handoff for v0.8.0 ([0ba6785](https://github.com/xyzxyz442/x442-skills/commit/0ba6785d874ebb0a815bf0c4600956796e0bd56b))

### 🧹 Miscellaneous Chores

- **config:** regenerate .gitignore from toptal with the shared AI tail ([6331963](https://github.com/xyzxyz442/x442-skills/commit/6331963de91f49d5b3357b06a18674171fa1d059))

## [0.8.0](https://github.com/xyzxyz442/x442-skills/compare/v0.7.0...v0.8.0) (2026-08-04)

### 🐞 Bug Fixes

- **bug:** fold colons out of every free-text frontmatter value ([bdc6e41](https://github.com/xyzxyz442/x442-skills/commit/bdc6e417b93b462cf2dbe0eb1329f8c679ae8620))
- **bug:** resolve --blocked-on inside the caller's board section ([781f450](https://github.com/xyzxyz442/x442-skills/commit/781f450523f66874bcd06cc3ab13d9f5250cfff4))
- **bug:** stop graph status probes reporting live vectors as keyword mode ([01b0064](https://github.com/xyzxyz442/x442-skills/commit/01b0064ecd2904e649a0aec65dfe31a7d9406390))
- **bug:** strip one surrounding quote pair when reading frontmatter ([c947dfa](https://github.com/xyzxyz442/x442-skills/commit/c947dfa13328d5b4b38bfb28ca4f8fcdcd98f429))
- **bug:** treat an empty or block-list repos: as this repo's own doc ([3dff07e](https://github.com/xyzxyz442/x442-skills/commit/3dff07e9bfa70f9081cbd90c53e18e88eaef3280))
- **bug:** write the changelog to CHANGELOG.md, not CHANGELOG ([96d29d7](https://github.com/xyzxyz442/x442-skills/commit/96d29d790bb353a428473001cfe6576a2a02f0c8))

### 📚 Documentation

- **docs:** close the protocol bundle and retire the landed reference docs ([309f4c5](https://github.com/xyzxyz442/x442-skills/commit/309f4c59e5cf617b134468578519603ba4005536))
- **docs:** record the multi-group cross-repo handoff install ([ee5d6ed](https://github.com/xyzxyz442/x442-skills/commit/ee5d6edf3656d4d7e37c13c6fe25c77ab9c7f00c))
- **docs:** sync the engineering-suite handoff for unreleased main ([1adfce4](https://github.com/xyzxyz442/x442-skills/commit/1adfce4e7a0b89cb4fecb54ca50496508d22aacb))

### 🧹 Miscellaneous Chores

- **deps:** upgrade release-it and add advisory overrides ([b2f2b3c](https://github.com/xyzxyz442/x442-skills/commit/b2f2b3c9c6a93accd901ef4b2459b3d33a47599f))
- **setup:** resync the cross-repo handoff block after a group split ([8edfa9c](https://github.com/xyzxyz442/x442-skills/commit/8edfa9cd6ff0d366ac8c53c0a4b91523b14bba1e))
- **setup:** wire this repo into a shared cross-repo handoff board ([e52fa5c](https://github.com/xyzxyz442/x442-skills/commit/e52fa5ca8c88f2f89ab13d27987a0bbe9b23e6c4))

## [0.7.0](https://github.com/xyzxyz442/x442-skills/compare/v0.6.0...v0.7.0) (2026-07-26)

### 🚀 Features

- **feature:** add register-cross-repo-handoff skill ([60dee4e](https://github.com/xyzxyz442/x442-skills/commit/60dee4ec1f6a922eaae088503ac5cd98d8368d6d))
- **feature:** give setup-project-tooling a .gitattributes baseline ([9852623](https://github.com/xyzxyz442/x442-skills/commit/985262399e623c910de1f3b0dea9b323e37c3818))
- **feature:** multi-group sub-indexed boards in handoff payload ([091aaeb](https://github.com/xyzxyz442/x442-skills/commit/091aaebe67af18fd5c558fb37167f5c402cc992c))
- **feature:** scaffold standalone boards and thread group identity in setup-handoff ([a326009](https://github.com/xyzxyz442/x442-skills/commit/a3260094f61ca5b4cc70d6ff7ac4c3fe17f67df2))

### 🐞 Bug Fixes

- **bug:** hard-fail handoff claim/release on an unresolvable id ([2eb8e99](https://github.com/xyzxyz442/x442-skills/commit/2eb8e99036abb0b64d225faf4384c8d5a9735fd4))
- **bug:** recognize handoff hooks on any board name in merge-hooks ([4a9600c](https://github.com/xyzxyz442/x442-skills/commit/4a9600c8429e485c8dbb41b84ce169e945712876))
- **bug:** require --kind in handoff hook discriminator to avoid stripping foreign groups ([7911584](https://github.com/xyzxyz442/x442-skills/commit/791158480b9c195710fb8a8e4db4d7905226da16))
- **bug:** stop initialize.sh bootstrapping python in base-only repos ([aff1d6f](https://github.com/xyzxyz442/x442-skills/commit/aff1d6ffa9e3628c4438553bc8cf7e7025fdfda2))
- **feature:** gather channel and language as multi-select in release-announcement ([b7d4a87](https://github.com/xyzxyz442/x442-skills/commit/b7d4a8761cb59c29f143e2ca2541d67993d23e99))

### 📚 Documentation

- **docs:** index register-cross-repo-handoff in AGENTS.md and skills catalog ([6a4de38](https://github.com/xyzxyz442/x442-skills/commit/6a4de3845949754bf90a8269688fd4f8b2e9c1c8))
- **docs:** sync the engineering-suite handoff for v0.6.0 ([3e505e4](https://github.com/xyzxyz442/x442-skills/commit/3e505e46ab2e412ca72d227bf9b11a21c97a6b9f))
- **docs:** sync the engineering-suite handoff for v0.7.0 ([9d2a3dd](https://github.com/xyzxyz442/x442-skills/commit/9d2a3dde6d2481979ba03d4151f8d4f41ad836f5))

### 🧪 Tests

- **test:** add register-cross-repo-handoff eval harness ([6b37d48](https://github.com/xyzxyz442/x442-skills/commit/6b37d48db9f7d8e1a78686938fdb10333b2ef069))
- **test:** cover multi-group sub-indexed boards in setup-handoff harness ([f94d9f3](https://github.com/xyzxyz442/x442-skills/commit/f94d9f3168e6fe1b96c6aba6c1cc1656b2bc3453))

### 🧹 Miscellaneous Chores

- **config:** adopt the setup-project-tooling gitattributes baseline ([0165a2d](https://github.com/xyzxyz442/x442-skills/commit/0165a2dc44f53b95aa6fe6569aa8fd62cf401c3a))
- **setup:** adopt the workspace-bootstrap layer from setup-project-tooling ([f72209f](https://github.com/xyzxyz442/x442-skills/commit/f72209f9baa2eec4ae1d9d5aa3162c2eb71e828e))
- **setup:** re-sync this repo's handoff board onto the current payload ([fa51b57](https://github.com/xyzxyz442/x442-skills/commit/fa51b57aa248ceb3994108554eb12d908e4e050a))

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
