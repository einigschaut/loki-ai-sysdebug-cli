# src/i18n/en.psd1 — English message catalog (base language + fallback). Data-only (Import-PowerShellDataFile).
# Keys are namespaced 'area.name'. {0}/{1} are -f placeholders filled by Get-LokiText -ArgumentList.
# Every key here MUST exist in every other locale catalog (enforced by tests/i18n.Tests.ps1). See ADR-0004.
@{
    'app.tagline'                = 'portable AI debug stick'

    'dispatch.overviewHint'      = 'Overview:  loki help'
    'dispatch.statusHint'        = 'Status:    loki status'
    'error.unknownCommandQuoted' = "Unknown command: '{0}'."
    'error.didYouMean'           = "Did you mean 'loki {0}'?"
    'hint.overview'              = 'Overview: loki help'

    'help.usage'                = 'Usage: {0}'
    'help.usageGeneric'         = 'Usage: loki <command> [args] [--flags]'
    'help.flagsHeading'         = 'Flags:'
    'help.examplesHeading'      = 'Examples:'
    'help.footer'               = 'Help for a command: loki help <command>  or  loki <command> --help'
    'help.unknownCommand'       = 'Unknown command: {0}'

    'auth.notSet'               = '(not set)'
    'auth.status.method'        = 'Method:'
    'auth.status.variable'      = 'Variable:'
    'auth.status.secretSet'     = 'Secret set ({0})'
    'auth.status.secretUnset'   = 'No secret set.'
    'auth.use.invalid'          = 'Invalid or missing auth method.'
    'auth.use.usage'            = 'Usage: loki auth use <api|sub>'
    'auth.use.set'              = 'Auth method set: {0}'
    'auth.set.prompt'           = 'API key / token (input hidden)'
    'auth.set.saved'            = 'Secret saved.'
    'auth.clear.removed'        = 'Secret removed.'
    'auth.login.chooseHeading'  = 'How should Loki reach the online engine?'
    'auth.login.optSub'         = '  [1] Claude subscription  (opens a browser to sign in)'
    'auth.login.optApi'         = '  [2] Anthropic API key    (paste a console key)'
    'auth.login.choosePrompt'   = 'Choose 1 or 2'
    'auth.login.badMethod'      = 'Choose a method: sub (Claude subscription) or api (API key).'
    'auth.login.usage'          = 'Usage: loki auth login [sub|api]'
    'auth.login.subLaunch'      = 'Starting Claude sign-in - a browser will open. Complete it, then copy the token it prints.'
    'auth.login.pasteHint'      = 'Now paste the token shown above.'
    'auth.login.prompt'         = 'Subscription token (input hidden)'
    'auth.login.subFailed'      = 'Claude sign-in did not complete - no token was generated. Nothing changed.'
    'auth.login.engineMissing'  = 'Claude Code (the `claude` CLI) was not found. Install it to sign in with a subscription.'
    'auth.login.apiPrompt'      = 'Anthropic API key (input hidden)'
    'auth.login.apiDone'        = 'API key saved; auth method set to api.'
    'auth.login.empty'          = 'No credential entered - nothing changed.'
    'auth.login.done'           = 'Subscription token saved; auth method set to sub.'
    'auth.missingSub'           = 'loki auth requires a sub-command.'
    'auth.unknownSub'           = "Unknown sub-command: '{0}'."
    'auth.usage'                = 'Usage: loki auth <login|status|use|set|clear>'

    'status.net.online'         = 'Network: reachable (online engine available)'
    'status.net.offline'        = 'Network: unreachable - only the offline path (collect/offline) is available'
    'status.postureRollup'      = '{0} ok, {1} warning(s), {2} issue(s)'
    'status.doctorHint'         = "Run 'loki doctor' for the full check (auth, host posture, volume/BitLocker)."

    'status.summary'            = 'Quick environment check (writes nothing)'
    'help.summary'              = 'Help / command overview (also: loki <cmd> --help)'
    'version.summary'           = 'Show Loki and environment versions'
    'auth.summary'              = 'Manage auth method and secret'
    'doctor.summary'            = 'Full environment & host-posture diagnosis'
    'ask.summary'               = 'Ask the online engine a read-only diagnostic question'

    'doctor.check.auth'         = 'Authentication'
    'doctor.check.lang'         = 'PowerShell language mode'
    'doctor.check.execpolicy'   = 'Execution policy'
    'doctor.check.deviceguard'  = 'Device Guard / WDAC'
    'doctor.check.applocker'    = 'AppLocker'
    'doctor.check.volume'       = 'Volume'

    'doctor.status.ok'          = 'OK'
    'doctor.status.warn'        = 'WARN'
    'doctor.status.fail'        = 'FAIL'
    'doctor.status.unknown'     = '?'

    'doctor.detail.unknown'         = 'could not be determined'
    'doctor.deviceguard.enforced'   = 'code integrity enforced'
    'doctor.deviceguard.off'        = 'not enforced'
    'doctor.applocker.rules'        = 'effective rules present'
    'doctor.applocker.none'         = 'no effective rules'
    'doctor.volume.encrypted'       = 'removable, BitLocker on'
    'doctor.volume.plain'           = 'not on an encrypted removable volume'

    'doctor.footer'             = '{0} OK, {1} warning(s), {2} failure(s)'

    'footprint.heading'         = 'loki doctor --footprint'
    'footprint.probeVerified'   = 'Isolation probe verified: the env-var redirect held - the isolated writes landed on the stick, not the host.'
    'footprint.clean'           = 'Clean for this probe: the env-var redirect held, no isolated write reached the host profile. (Does not cover Known-Folder-API writes - see ADR-0010.)'
    'footprint.leaked'          = 'FOOTPRINT: an isolated write leaked to the host profile ({0}). The redirect is not holding.'
    'footprint.observed'        = 'Note: watched host location(s) changed during the probe (possibly unrelated activity): {0}'
    'footprint.probeFailed'     = 'Could not run the isolation probe - footprint result is inconclusive.'

    'ask.usage'                 = 'Usage: loki ask <question>'
    'ask.offline'               = 'loki ask needs network access (the online engine is unreachable). Use the offline path instead.'
    'ask.working'               = 'Asking the online engine (read-only diagnosis)...'
    'ask.authMissing'           = "No credential set for the online engine. Run 'loki auth login' (Claude subscription or API key)."
    'ask.engineMissing'         = 'Claude Code (the `claude` CLI) was not found. Install it to use the online engine.'
    'ask.timeout'               = 'The online engine did not respond in time.'
    'ask.failed'                = 'The online engine could not complete the request.'
    'ask.cost'                  = 'Cost: ${0} USD'

    'scan.summary'              = 'Run a structured read-only diagnostic scan of an area'
    'scan.invalidArea'          = 'Unknown scan area. Valid areas: {0}.'
    'scan.offline'              = 'loki scan needs network access (the online engine is unreachable). Use the offline path instead.'
    'scan.working'              = 'Scanning {0} with the online engine (read-only diagnosis)...'
    'scan.authMissing'          = "No credential set for the online engine. Run 'loki auth login' (Claude subscription or API key)."
    'scan.engineMissing'        = 'Claude Code (the `claude` CLI) was not found. Install it to use the online engine.'
    'scan.timeout'              = 'The online engine did not respond in time.'
    'scan.failed'               = 'The online engine could not complete the scan.'
    'scan.cost'                 = 'Cost: ${0} USD'

    'chat.summary'              = 'Interactive diagnostic session with the online engine (mutations require confirmation)'
    'chat.offline'              = 'loki chat needs network access (the online engine is unreachable). Use the offline path instead.'
    'chat.starting'             = 'Starting an interactive diagnostic session (read-only auto, changes need confirmation)...'
    'chat.authMissing'          = "No credential set for the online engine. Run 'loki auth login' (Claude subscription or API key)."
    'chat.engineMissing'        = 'Claude Code (the `claude` CLI) was not found. Install it to use the online engine.'
    'chat.ended'                = 'Session ended.'
    'chat.failed'               = 'The online engine could not start the interactive session.'

    'setup.summary'             = 'Prepare the stick: download offline model(s) (run where you set up the stick)'
    'setup.offline'             = 'loki setup needs internet access - run it on the machine where you prepare the stick.'
    'setup.heading'             = 'loki setup - offline models'
    'setup.tiersHint'           = 'Available tiers (* = recommended default):'
    'setup.choosePrompt'        = 'Which tier(s)? ids comma-separated, or "default" / "all"'
    'setup.badSelection'        = "Unknown tier id: '{0}'."
    'setup.noneSelected'        = 'Nothing selected - no models downloaded.'
    'setup.downloading'         = 'Downloading {0} (~{1} GB)...'
    'setup.verified'            = '{0}: downloaded and verified.'
    'setup.skipped'             = '{0}: already present and verified - skipped.'
    'setup.verifyFailed'        = '{0}: FAILED ({1}) - not kept.'
    'setup.done'                = 'Done - {0} model(s) ready on the stick.'
    'setup.engineNote'          = 'Models are staged on the stick. The offline engine that runs them comes in a later version.'
}
