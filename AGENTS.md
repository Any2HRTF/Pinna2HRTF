# Architecture

Pinna2HRTF is a headless application with two native clients. A user with the installed CLI and its documented runtime dependencies must be able to perform every project operation from a terminal. Verify resource and executable discovery from a working directory outside the checkout.

- Implement project operations once in HRTFCalculation and expose them through the public Pinna2HRTF command. Introduce or extend the CLI operation before wiring either UI to it. Route interactive and machine clients to the same implementation.
- Python owns project formats, defaults, validation, path relocation, stage dependencies, output ownership, freshness, and all changes to project files and scientific artifacts. Put locks, stale-input checks, safe publication, rollback, and cancellation at the operation that owns the write.
- Swift and C# own windows, dialogs, rendering, selection, unsaved form values, and app-local preferences. Send an edit or run request to the CLI and render its result. A camera rotation is presentation. Applying a transform to a saved mesh is a backend operation.
- Use one native CLI client per platform for launching the packaged runtime, sending requests, receiving results, and surfacing errors. Keep platform-specific process and rendering details local. Keep Python snippets, private-module invocations, and project-format serializers out of UI code.
- Document commands and machine-readable payloads alongside the CLI usage. Keep stdout parseable in machine mode, route diagnostics to stderr, and expose failures through stable error information and a nonzero exit status for failed commands. Preserve existing scripts and saved projects when evolving the interface.

# Code style

- Use descriptive domain names, explicit units where relevant, and straightforward control flow. Remove dead branches, commented-out implementations, pass-through wrappers, and repeated conversions after checking their callers.
- Write first-party implementation code without explanatory comments. Express intent through names and structure. Move durable scientific rationale, coordinate conventions, and format rules into the relevant documentation before deleting the original explanation. Preserve required license notices, shebangs, compiler and tool directives, and user-visible CLI help. Leave vendored and generated sources to their upstream owners.
- Before adding a function, find the existing operation and inspect its callers. Consolidate equivalent behavior at its owner. Compare units, coordinate frames, platform path semantics, side effects, and failure behavior before merging similar functions. Extract an abstraction only when it removes real duplication or isolates a concrete dependency.
- Migrate one complete operation at a time. Exercise it from the installed CLI and through both UI entry points on copies of representative projects. Check legacy inputs, expected outputs, and relevant failure or cancellation paths before deleting superseded code.

# Mac app updates

After making and verifying Mac app changes, replace `/Applications/Pinna2HRTF.app` with the updated build. The user has authorized this as the default workflow. Preserve any unsaved work before restarting the running app.

# GitHub updates

After completing and verifying changes, commit and push them to the current GitHub branch. The user has authorized pushing as the default workflow.

# Verification preferences

Do not create a `Tests` directory or add automated tests for the app. The user explicitly removed the existing tests. Verify changes with builds, inspection, and manual runtime checks without recreating those files.
