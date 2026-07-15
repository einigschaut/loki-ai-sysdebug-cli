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
    'auth.login.deferred'       = 'loki auth login benötigt die Online-Engine (folgt in F2).'
    'auth.missingSub'           = 'loki auth benötigt ein Sub-Command.'
    'auth.unknownSub'           = "Unbekanntes Sub-Command: '{0}'."
    'auth.usage'                = 'Verwendung: loki auth <status|use|set|clear|login>'

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

    'ask.usage'                 = 'Verwendung: loki ask <Frage>'
    'ask.offline'               = 'loki ask benötigt Netzzugang (Online-Engine nicht erreichbar). Nutze stattdessen den Offline-Pfad.'
    'ask.working'               = 'Frage an die Online-Engine (read-only Diagnose)...'
    'ask.authMissing'           = "Kein API-Key gesetzt. Führe zuerst 'loki auth set' aus."
    'ask.engineMissing'         = 'Claude Code (das `claude`-CLI) wurde nicht gefunden. Installiere es für die Online-Engine.'
    'ask.timeout'               = 'Die Online-Engine hat nicht rechtzeitig geantwortet.'
    'ask.failed'                = 'Die Online-Engine konnte die Anfrage nicht abschließen.'
    'ask.cost'                  = 'Kosten: {0} USD'

    'scan.summary'              = 'Strukturierten read-only Diagnose-Scan eines Bereichs ausführen'
    'scan.invalidArea'          = 'Unbekannter Scan-Bereich. Gültige Bereiche: {0}.'
    'scan.offline'              = 'loki scan benötigt Netzzugang (Online-Engine nicht erreichbar). Nutze stattdessen den Offline-Pfad.'
    'scan.working'              = 'Scanne {0} mit der Online-Engine (read-only Diagnose)...'
    'scan.authMissing'          = "Kein API-Key gesetzt. Führe zuerst 'loki auth set' aus."
    'scan.engineMissing'        = 'Claude Code (das `claude`-CLI) wurde nicht gefunden. Installiere es für die Online-Engine.'
    'scan.timeout'              = 'Die Online-Engine hat nicht rechtzeitig geantwortet.'
    'scan.failed'               = 'Die Online-Engine konnte den Scan nicht abschließen.'
    'scan.cost'                 = 'Kosten: {0} USD'

    'chat.summary'              = 'Interaktive Diagnose-Session mit der Online-Engine (Mutationen nur nach Bestätigung)'
    'chat.offline'              = 'loki chat benötigt Netzzugang (Online-Engine nicht erreichbar). Nutze stattdessen den Offline-Pfad.'
    'chat.starting'             = 'Starte interaktive Diagnose-Session (read-only automatisch, Änderungen nur nach Bestätigung)...'
    'chat.authMissing'          = "Kein API-Key gesetzt. Führe zuerst 'loki auth set' aus."
    'chat.engineMissing'        = 'Claude Code (das `claude`-CLI) wurde nicht gefunden. Installiere es für die Online-Engine.'
    'chat.ended'                = 'Session beendet.'
    'chat.failed'               = 'Die Online-Engine konnte die interaktive Session nicht starten.'
}
