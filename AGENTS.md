# Working on mdr

Work in this checkout and keep generated fixtures, benchmarks, and scratch files
under `work/`. Never commit personal documents, feedback files, or absolute paths
from a developer's machine.

## Keep the local installation current

After changes to the app, renderer, resources, or CLI, finish by building with
`npm run build`, running the checks appropriate to the change, and running
`bash scripts/install.sh`. Do not leave the developer testing an older installed
app. Documentation-only changes do not require a rebuild.

Verify that the installed app has the expected version, its signature is valid,
and the user's `mdr` command resolves to that installation. If mdr is configured
as the default Markdown reader, verify that Finder resolves Markdown files to
the installed bundle rather than a build, backup, or test copy. The installer
cleans up registrations for development copies in this checkout.

Preserve running readers and feedback watchers during installation. Tell the
user to quit and reopen an existing reader to load changed application code.
Never stop a user's running process just to refresh the installation.
