# unity-scaffolded (setup-project-tooling post-state fixture)

A Unity 6 project with the draft Unity module applied by hand over the common base: Unity
ignores, the Unity .gitattributes (LF for every text file) with Git LFS declined, and the editorconfig, prettier, lint-staged,
and VS Code fragments. The grader verifies 0 failed, every unity.* check passing, and idempotency.

Its `.gitattributes` defines `[attr]` macros, which git honours only in a top-level file. Nested
inside x442-skills, git warns `not allowed` whenever it reads attributes under this folder; the
grader copies the fixture to its own git root first, where the macros apply, so the warning is
noise and not a failure.
