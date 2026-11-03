# Windows v2 integration with main

The Windows integration branch starts at main `89d63f6418a210ecd29caa609e14b1749a3f38ff` and retains the local Windows and Mac-imitation layouts. Prior work and packages remain separate. No installer is produced by this integration.

## Main contracts retained

- Shared Python configuration, spatial LocaDyn upsampling, scan/review receipts, preprocessing/NumCalc updates and staged SOFA publication come from current main.
- Ear-distance migration remains available on both platforms, with backups and future-release deprecation markers. The current ear-distance setting takes precedence.
- Windows includes spatial subdivisions and independent spatial normalization, original-scan provenance, offline Help, common lighting and the existing compact fitting/pressure viewers.
- Registry numbers are stored invariantly. Editors accept the active culture and unambiguous invariant input; invalid drafts preserve the saved value and block execution. An isolated review can set `PINNA2HRTF_APP_DATA` and `PINNA2HRTF_CULTURE` without changing Windows settings.

## Lifecycle and data protection

`OwnedProcess` contains each tool in its own kill-on-close Windows job at creation. Pipeline and helper callers share argument serialization, cancellation and bounded output handling. Output ownership remains reserved until writers have stopped. Cancelled or invalid fitting-worker sessions are retired.

Project removal distinguishes app-created folders from imported/reference/unknown locations, resolves filesystem identity and checks protected locations, other project roots and dependencies. Folder removal uses a recycle-only Shell operation; list-only removal remains available.

Generated output manifests and external SOFA ownership preserve modified, shared and unrelated files. Editor saves publish from private workspaces under the output lease. Preprocessing stages replacement solver projects and retains previous exports; the app does not approve deletion of older backups. Duplication stages a coherent copy, holds the source lease and rewrites only known metadata paths.

Status, availability and progress inspection run on snapshots in the background. File hashes are cached for presentation and freshly checked before decisive actions. Explicit stale-review recovery does not silently select another mesh. Postprocessing completion includes settings/output fingerprints and spatial receipts.

Windows SOFA I/O adapts the bundled netCDF filename handling. It uses the active Windows code page where representable and native Python I/O plus netCDF memory datasets for other Unicode names. It does not change the system locale or current directory. File-only plots use the Agg backend.

Windows startup initializes process time-zone data before XAML construction. Native debugging identified an STA lock wait during the first file-timestamp inspection in Loaded, allowing timer callbacks into the partially built window. The same scan-startup case now passes from an unrelated working directory and both ASCII and Unicode package paths.

Scan receipt inspection no longer imports MeshLab eagerly. Actual Windows meshing loads Blender before MeshLab because the bundled native libraries otherwise conflict; both real scan preparation and reviewed-ear preprocessing were exercised with this order. macOS retains its existing library-loading order.

## Build and verification

Build either layout with `dotnet build Sources/Pinna2HRTF.Windows/Pinna2HRTF.Windows.csproj -c Release -p:MacImitation=true` (or `false`). `Scripts/build_windows_port.ps1` stages portable output before promotion; `RuntimePackage` supplies an independent runtime/model payload and `ExternalRoot` selects prepared native tools. Native preparation pins installer/source identities and writes `external-build-manifest.json`.

Verification uses builds, source inspection and manual runtime exercises. No removed app test suite or Tests directory is recreated. The portable review report records source identity and distinguishes verified, partial, broken and unavailable checks. Coarse solver runs establish workflow and file validity, not acoustic accuracy. Native macOS, physical Precision Touchpad, mixed-DPI/multiple-display and real full-head-scan acceptance require the corresponding environment/data.
