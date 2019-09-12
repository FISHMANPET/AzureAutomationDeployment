# AzureAutomationDeployment

Track Changes to AzureRunbooks

This will run various tests and checks and tasks in Azure Pipelines, based on the type of commit

The pipeline will do different things based on the type of commit

- A standard commit to a branch
- A commit to a branch with the string `!testdeploy` in the commit message (a "Test Deploy" commit)
- A PR build (initiated when a PR is opened, and when any commit is made to a branch with an open PR)
- A commit to master (a merged pull request or someone has made a commit directly to master)

x|Commit|Test Deploy|Pull Request|Commit to Master|
-|-|-|-|-|
Test Production Variables|:x:|:x:|:heavy_check_mark:|:heavy_check_mark:|
Test Test Variables|:x:|:heavy_check_mark:|:heavy_check_mark:|:heavy_check_mark:|
Run Code Tests|Files changed in this commit|Files changed in this commit|All changes in PR|All tests|
Build|:x:|:heavy_check_mark:|:heavy_check_mark:|:heavy_check_mark:|
Deploy to Test Env|:x:|:heavy_check_mark:|:heavy_check_mark:|:heavy_check_mark:
Deploy to Production|:x:|:x:|:x:|:heavy_check_mark:|
Error Email|:x:|committer or team|team|incident queue|

There's a test automation account, where runbooks can be deployed to.  When deploying there, checks will be run to ensure that the workspace has all the "shared resources" (variables, connections, certificates, credentials, but I've just called them "variables" generally) needed to run that runbook.

When doing a build and deploy, the error email can be set automatically if the runbook has the proper formatting.  It looks for a variable assignment to `$errorEmail` and if it finds it exactly once, it will replace it with the value defined in the table above.  If you set the final catch email to send to `$errorEmail` instead of the incident email explicitly, then it will cut down on spam while testing.

Instead of running code coverage against all files, it only runs code coverage against files that have tests (a file with $name.ps1 and a corresponding $name.Tests.ps1 in the Tests folder).

When running tests it will only run tests on things that changed, (except in master where it will run all the tests)

When a commit is made to master, this will deploy it to production, including create the runbook if it didn't exist previously.

This uses a module called BuildHelpers, leaning heavily on the `Get-GitChanged` function, which, coincidentally, I wrote.  The maintainer is kind of slow in accepting PRs, especially when they're complicated, so that change hasn't been merged into the public project.  Because of that I've had to build my own version with my changes included.  There is a "download artifact" step in the pipeline that will download this, and then when build.ps1 runs, if that package is present, it will import it, otherwise it will install the module from the Gallery.  If/when my PR is merged into the project, that download package step can be disabled, and build.ps1 will automatically pull from the gallery instead.
