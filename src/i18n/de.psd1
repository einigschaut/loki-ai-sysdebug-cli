# src/i18n/de.psd1 — Deutscher Meldungskatalog. Reine Daten (Import-PowerShellDataFile). UTF-8 MIT BOM
# (Umlaute -> sonst liest Windows PowerShell 5.1 die Datei als ANSI = Mojibake). Schluessel spiegeln en.psd1;
# jeder en-Schluessel MUSS hier existieren (Test-Gate in tests/i18n.Tests.ps1). Siehe ADR-0004.
@{
    'app.tagline'                = 'portabler AI-Debug-Stick'

    'dispatch.overviewHint'      = 'Übersicht: loki help'
    'dispatch.statusHint'        = 'Status:    loki status'
    'error.unknownCommandQuoted' = "Unbekanntes Command: '{0}'."
    'error.didYouMean'           = "Meintest du 'loki {0}'?"
    'hint.overview'              = 'Übersicht: loki help'

    'help.usage'                = 'Verwendung: {0}'
    'help.usageGeneric'         = 'Verwendung: loki <command> [args] [--flags]'
    'help.flagsHeading'         = 'Flags:'
    'help.examplesHeading'      = 'Beispiele:'
    'help.footer'               = 'Hilfe zu einem Command: loki help <command>  oder  loki <command> --help'
    'help.unknownCommand'       = 'Unbekanntes Command: {0}'

    'auth.notSet'               = '(nicht gesetzt)'
    'auth.status.method'        = 'Methode:'
    'auth.status.variable'      = 'Variable:'
    'auth.status.secretSet'     = 'Secret gesetzt ({0})'
    'auth.status.secretUnset'   = 'Kein Secret gesetzt.'
    'auth.use.invalid'          = 'Ungültige oder fehlende Auth-Methode.'
    'auth.use.usage'            = 'Verwendung: loki auth use <api|sub>'
    'auth.use.set'              = 'Auth-Methode gesetzt: {0}'
    'auth.set.prompt'           = 'API-Key / Token (Eingabe verborgen)'
    'auth.set.saved'            = 'Secret gespeichert.'
    'auth.clear.removed'        = 'Secret entfernt.'
    'auth.login.chooseHeading'  = 'Wie soll Loki die Online-Engine erreichen?'
    'auth.login.optSub'         = '  [1] Claude-Abo         (öffnet einen Browser zum Anmelden)'
    'auth.login.optApi'         = '  [2] Anthropic-API-Key  (Console-Key einfügen)'
    'auth.login.choosePrompt'   = 'Wähle 1 oder 2'
    'auth.login.badMethod'      = 'Wähle eine Methode: sub (Claude-Abo) oder api (API-Key).'
    'auth.login.usage'          = 'Verwendung: loki auth login [sub|api]'
    'auth.login.subLaunch'      = 'Starte die Claude-Anmeldung - ein Browser öffnet sich. Schließe sie ab und kopiere den angezeigten Token.'
    'auth.login.pasteHint'      = 'Füge jetzt den oben angezeigten Token ein.'
    'auth.login.prompt'         = 'Subscription-Token (Eingabe verborgen)'
    'auth.login.subFailed'      = 'Die Claude-Anmeldung wurde nicht abgeschlossen - kein Token erzeugt. Nichts geändert.'
    'auth.login.engineMissing'  = 'Claude Code (das `claude`-CLI) wurde nicht gefunden. Installiere es für die Abo-Anmeldung.'
    'auth.login.apiPrompt'      = 'Anthropic-API-Key (Eingabe verborgen)'
    'auth.login.apiDone'        = 'API-Key gespeichert; Auth-Methode auf api gesetzt.'
    'auth.login.empty'          = 'Kein Zugang eingegeben - nichts geändert.'
    'auth.login.done'           = 'Subscription-Token gespeichert; Auth-Methode auf sub gesetzt.'
    'auth.missingSub'           = 'loki auth benötigt ein Sub-Command.'
    'auth.unknownSub'           = "Unbekanntes Sub-Command: '{0}'."
    'auth.usage'                = 'Verwendung: loki auth <login|status|use|set|clear>'

    'status.net.online'         = 'Netz: erreichbar (Online-Engine nutzbar)'
    'status.net.offline'        = 'Netz: nicht erreichbar - nur Offline-Pfad (collect/offline) verfügbar'
    'status.postureRollup'      = '{0} ok, {1} Warnung(en), {2} Problem(e)'
    'status.doctorHint'         = '`loki doctor` für die volle Prüfung (Auth, Host-Posture, Volume/BitLocker).'

    'status.summary'            = 'Schneller Umgebungs-Check (schreibt nichts)'
    'help.summary'              = 'Hilfe / Command-Übersicht (auch: loki <cmd> --help)'
    'version.summary'           = 'Zeigt Loki- und Umgebungs-Versionen'
    'auth.summary'              = 'Auth-Methode und Secret verwalten'
    'doctor.summary'            = 'Vollständige Umgebungs- und Host-Posture-Diagnose'
    'ask.summary'               = 'Der Online-Engine eine read-only Diagnosefrage stellen'

    'doctor.check.auth'         = 'Authentifizierung'
    'doctor.check.lang'         = 'PowerShell-Sprachmodus'
    'doctor.check.execpolicy'   = 'Ausführungsrichtlinie'
    'doctor.check.deviceguard'  = 'Device Guard / WDAC'
    'doctor.check.applocker'    = 'AppLocker'
    'doctor.check.volume'       = 'Volume'

    'doctor.status.ok'          = 'OK'
    'doctor.status.warn'        = 'WARN'
    'doctor.status.fail'        = 'FEHL'
    'doctor.status.unknown'     = '?'

    'doctor.detail.unknown'         = 'nicht ermittelbar'
    'doctor.deviceguard.enforced'   = 'Code-Integrität erzwungen'
    'doctor.deviceguard.off'        = 'nicht erzwungen'
    'doctor.applocker.rules'        = 'wirksame Regeln vorhanden'
    'doctor.applocker.none'         = 'keine wirksamen Regeln'
    'doctor.volume.encrypted'       = 'Wechseldatenträger, BitLocker an'
    'doctor.volume.plain'           = 'kein verschlüsselter Wechseldatenträger'

    'doctor.footer'             = '{0} OK, {1} Warnung(en), {2} Fehler'

    'footprint.heading'         = 'loki doctor --footprint'
    'footprint.probeVerified'   = 'Isolations-Probe bestätigt: die Env-Var-Umleitung greift - die isolierten Writes landeten auf dem Stick, nicht im Host.'
    'footprint.clean'           = 'Sauber für diese Probe: die Env-Var-Umleitung greift, kein isolierter Write hat das Host-Profil erreicht. (Deckt keine Known-Folder-API-Writes ab - siehe ADR-0010.)'
    'footprint.leaked'          = 'FOOTPRINT: ein isolierter Write ist ins Host-Profil gelangt ({0}). Die Umleitung greift nicht.'
    'footprint.observed'        = 'Hinweis: beobachtete Host-Ort(e) haben sich während der Probe geändert (evtl. fremde Aktivität): {0}'
    'footprint.probeFailed'     = 'Isolations-Probe konnte nicht ausgeführt werden - Footprint-Ergebnis nicht aussagekräftig.'

    'ask.usage'                 = 'Verwendung: loki ask <Frage>'
    'ask.offline'               = 'loki ask benötigt Netzzugang (Online-Engine nicht erreichbar). Nutze stattdessen den Offline-Pfad.'
    'ask.working'               = 'Frage an die Online-Engine (read-only Diagnose)...'
    'ask.authMissing'           = "Kein Zugang für die Online-Engine gesetzt. Führe 'loki auth login' aus (Claude-Abo oder API-Key)."
    'ask.engineMissing'         = 'Claude Code (das `claude`-CLI) wurde nicht gefunden. Installiere es für die Online-Engine.'
    'ask.timeout'               = 'Die Online-Engine hat nicht rechtzeitig geantwortet.'
    'ask.failed'                = 'Die Online-Engine konnte die Anfrage nicht abschließen.'
    'ask.cost'                  = 'Kosten: {0} USD'

    'scan.summary'              = 'Strukturierten read-only Diagnose-Scan eines Bereichs ausführen'
    'scan.invalidArea'          = 'Unbekannter Scan-Bereich. Gültige Bereiche: {0}.'
    'scan.offline'              = 'loki scan benötigt Netzzugang (Online-Engine nicht erreichbar). Nutze stattdessen den Offline-Pfad.'
    'scan.working'              = 'Scanne {0} mit der Online-Engine (read-only Diagnose)...'
    'scan.authMissing'          = "Kein Zugang für die Online-Engine gesetzt. Führe 'loki auth login' aus (Claude-Abo oder API-Key)."
    'scan.engineMissing'        = 'Claude Code (das `claude`-CLI) wurde nicht gefunden. Installiere es für die Online-Engine.'
    'scan.timeout'              = 'Die Online-Engine hat nicht rechtzeitig geantwortet.'
    'scan.failed'               = 'Die Online-Engine konnte den Scan nicht abschließen.'
    'scan.cost'                 = 'Kosten: {0} USD'

    'chat.summary'              = 'Interaktive Diagnose-Session mit der Online-Engine (Mutationen nur nach Bestätigung)'
    'chat.offline'              = 'loki chat benötigt Netzzugang (Online-Engine nicht erreichbar). Nutze stattdessen den Offline-Pfad.'
    'chat.starting'             = 'Starte interaktive Diagnose-Session (read-only automatisch, Änderungen nur nach Bestätigung)...'
    'chat.authMissing'          = "Kein Zugang für die Online-Engine gesetzt. Führe 'loki auth login' aus (Claude-Abo oder API-Key)."
    'chat.engineMissing'        = 'Claude Code (das `claude`-CLI) wurde nicht gefunden. Installiere es für die Online-Engine.'
    'chat.ended'                = 'Session beendet.'
    'chat.failed'               = 'Die Online-Engine konnte die interaktive Session nicht starten.'
}
