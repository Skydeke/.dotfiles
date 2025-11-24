// CalendarService.qml — Read CalDAV calendars from EDS cache databases

import QtQuick
import Quickshell
import Quickshell.Io

pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import Qt.labs.platform
import qs.modules.common.functions
import qs.modules.common

Singleton {
    id: root

    property bool edsAvailable: false
    property var events: []
    property var weekdays: [
        Translation.tr("Sunday"), 
        Translation.tr("Monday"), 
        Translation.tr("Tuesday"), 
        Translation.tr("Wednesday"), 
        Translation.tr("Thursday"), 
        Translation.tr("Friday"), 
        Translation.tr("Saturday"),
    ];
    property var sortedWeekdays: root.weekdays.map((_, i) => weekdays[(i+Config.options.time.firstDayOfWeek+1)%7]);
    property var eventsInWeek: []
    property var calendarDirs: []

    // --- Logging ---
    function logInfo(msg)  { console.log("[CalendarService]", msg) }
    function logWarn(msg)  { console.warn("[CalendarService]", msg) }
    function logError(msg) { console.error("[CalendarService]", msg) }

    // --- Find all calendar cache directories ---
    Process {
        id: findCalendarDirs
        command: ["bash", "-c", "find ~/.cache/evolution/calendar -maxdepth 1 -type d -name '*' | grep -E '[a-f0-9]{40}$'"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                const dirs = this.text.trim().split('\n').filter(d => d.length > 0)
                root.calendarDirs = dirs
                if (dirs.length > 0) {
                    root.edsAvailable = true
                    root.logInfo("Found " + dirs.length + " calendar cache database(s)")
                    loadCalendarData.running = true
                } else {
                    root.logWarn("No calendar cache databases found")
                    // Also check local ICS files as fallback
                    findLocalCalendars.running = true
                }
            }
        }
    }

    // --- Fallback: Find local ICS files ---
    Process {
        id: findLocalCalendars
        command: ["bash", "-c", "find ~/.local/share/evolution/calendar -name '*.ics' -type f 2>/dev/null"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                const files = this.text.trim().split('\n').filter(f => f.length > 0)
                if (files.length > 0) {
                    root.edsAvailable = true
                    root.logInfo("Found " + files.length + " local calendar file(s)")
                    loadLocalCalendarData.command = ["bash", "-c", "cat " + files.join(' ') + " 2>/dev/null"]
                    loadLocalCalendarData.running = true
                } else {
                    root.logWarn("No calendars found — using mock data")
                    root.eventsInWeek = root.getEventsInWeek()
                }
            }
        }
    }

    // --- Load calendar data from SQLite cache databases ---
    Process {
        id: loadCalendarData
        running: false
        command: [
            "bash", "-c",
            root.calendarDirs.map(dir => 
                // use -noheader to avoid header line; keep default separator
                `sqlite3 -noheader "${dir}/cache.db" "SELECT summary, occur_start, occur_end, has_recurrences, ECacheOBJ FROM ECacheObjects;"`
            ).join(' ; ')
        ]
        
        stdout: StdioCollector {
            onStreamFinished: {
                const text = this.text
                root.logInfo("Loaded calendar data from SQLite databases (raw length: " + text.length + ")")

                let events = []
                const lines = text.split('\n')

                // Re-assemble rows: if ECacheOBJ (BEGIN:VEVENT...END:VEVENT) is split across multiple lines,
                // join them into one row so parsing can extract full VEVENT content.
                let rows = []
                let buffer = ''
                for (let i = 0; i < lines.length; i++) {
                    const line = lines[i]
                    // If we are currently accumulating a VEVENT, keep appending until END:VEVENT
                    if (buffer.length > 0) {
                        buffer += '\n' + line
                        if (line.indexOf('END:VEVENT') !== -1) {
                            rows.push(buffer)
                            buffer = ''
                        }
                    } else {
                        // Not currently buffering: if line contains BEGIN:VEVENT, start buffering
                        if (line.indexOf('BEGIN:VEVENT') !== -1) {
                            buffer = line
                            // If the same line also contains END:VEVENT (unlikely but possible), flush immediately
                            if (line.indexOf('END:VEVENT') !== -1) {
                                rows.push(buffer)
                                buffer = ''
                            }
                        } else {
                            // Normal single-line row (no VEVENT content)
                            if (line && line.trim().length > 0) rows.push(line)
                        }
                    }
                }
                // If anything left in buffer, push it (best-effort)
                if (buffer.length > 0) rows.push(buffer)

                for (let row of rows) {
                    if (!row || row.length === 0) continue

                    // If row contains a VEVENT, separate the prefix columns (summary/occur_start/...) from the VEVENT body
                    const veventIndex = row.indexOf('BEGIN:VEVENT')
                    let pre = row
                    let icalData = ''

                    if (veventIndex !== -1) {
                        pre = row.substring(0, veventIndex)
                        icalData = row.substring(veventIndex) // include BEGIN:VEVENT...END:VEVENT
                    }

                    const parts = pre.split('|')

                    // Try to obtain canonical fields from either the DB columns or by parsing the VEVENT body
                    // DB column order expected: summary|occur_start|occur_end|has_recurrences|ECacheOBJ
                    let summary = parts[0] || ''
                    const startStr = parts[1] || ''
                    const endStr = parts[2] || parts[1] || ''
                    const hasRecurrences = (parts[3] === '1')

                    // If we found an embedded VEVENT body, parse it to get authoritative values
                    if (icalData && icalData.length > 0) {
                        // parseVEvent expects the text AFTER 'BEGIN:VEVENT' (similar to loadLocalCalendarData)
                        const veventBody = icalData.split('BEGIN:VEVENT')[1] || icalData
                        const parsed = root.parseVEvent(veventBody)
                        if (parsed) {
                            // Prefer the VEVENT's SUMMARY (keeps capitalization and proper decoding)
                            if (parsed.content) {
                                summary = parsed.content
                            }
                            // Prefer DTSTART/DTEND from VEVENT when available (for correct timezone/date behavior)
                            if (parsed.startDate) {
                                // Use ISO-ish representation for expandRecurringEvent when needed
                                // We'll still pass the raw icalData to expandRecurringEvent so it can read RRULE
                            }
                        }
                    }

                    // If this row has recurrences and we have VEVENT/icalData, expand using the VEVENT body
                    if (hasRecurrences && icalData && icalData.length > 0) {
                        const occurrences = root.expandRecurringEvent(summary, startStr, endStr, icalData)
                        events = events.concat(occurrences)
                    } else {
                        // Simple one-time event (or fallback)
                        let ev = null
                        if (icalData && icalData.length > 0) {
                            const veventBody = icalData.split('BEGIN:VEVENT')[1] || icalData
                            ev = root.parseVEvent(veventBody)
                            ev.color = ColorUtils.stringToColor(ev.content);
                        }

                        // fallback to DB columns if VEVENT parse failed
                        if (!ev) {
                            ev = {
                                content: summary,
                                startDate: parseICalDateTime(startStr) || null,
                                endDate: parseICalDateTime(endStr) || parseICalDateTime(startStr) || null,
                                color: ColorUtils.stringToColor(summary),
                            }
                        }

                        // if still no startDate, skip
                        if (!ev.startDate) continue

                        // for all-day events with missing endDate, set end = start + 1 day
                        if (!ev.endDate) ev.endDate = new Date(ev.startDate.getTime() + 24*60*60*1000)

                        events.push(ev)
                    }
                }

                // Sort, dedupe and normalize results
                events.sort(function(a, b) {
                    return new Date(a.startDate) - new Date(b.startDate)
                })
                // dedupe by start-time + summary
                let deduped = []
                for (let i = 0; i < events.length; i++) {
                    const e = events[i]
                    if (e && e.startDate) {
                        const key = e.startDate.getTime() + '|' + (e.content || '')
                        if (i === 0 || (deduped.length > 0 && (deduped[deduped.length - 1].startDate.getTime() + '|' + deduped[deduped.length - 1].content) !== key)) {
                            deduped.push(e)
                        }
                    }
                }

                root.events = deduped
                root.eventsInWeek = root.getEventsInWeek()
                root.logInfo("Parsed " + deduped.length + " event(s) from databases")
            }
        }
        
        stderr: StdioCollector {
            onStreamFinished: {
                if (this.text.trim().length > 0) {
                    root.logError("Error reading calendar databases: " + this.text)
                }
            }
        }
    }

    // --- Load local ICS files (fallback) ---
    Process {
        id: loadLocalCalendarData
        running: false
        
        stdout: StdioCollector {
            onStreamFinished: {
                const text = this.text.trim()
                let events = []
                
                if (text.includes("BEGIN:VEVENT")) {
                    const vevents = text.split("BEGIN:VEVENT")
                    for (let i = 1; i < vevents.length; i++) {
                        const ev = root.parseVEvent(vevents[i])
                        if (ev) events.push(ev)
                    }
                }

                root.events = events
                root.eventsInWeek = root.getEventsInWeek()
                root.logInfo("Parsed " + events.length + " event(s) from local files")
            }
        }
    }

    // --- Parse VEVENT from ICS format ---
    function parseVEvent(str) {
        let e = {}
        const lines = str.split(/([\r\n]+)/).join('\n').split(/\n+/) // normalize newlines
        let currentLine = ""
        
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i]
            if (!line) continue

            if (line.match(/^[ \t]/)) {
                // continuation line
                currentLine += line.substring(1)
                continue
            }

            if (currentLine.length > 0) {
                parseVEventLine(currentLine, e)
            }
            currentLine = line.trim()
        }
        
        if (currentLine.length > 0) {
            parseVEventLine(currentLine, e)
        }
        
        if (e.content && e.startDate) {
            e.endDate = e.endDate || e.startDate
            return e
        }
        return null
    }

    function parseVEventLine(line, e) {
        const [rawKey, ...rest] = line.split(":")
        const value = rest.join(":").trim()
        const key = (rawKey || "").toUpperCase()

        function decodeQuotedPrintable(str) {
            str = str.replace(/=\r?\n/g, '')
            try {
                return decodeURIComponent(str.replace(/=([A-Fa-f0-9]{2})/g, '%$1'))
            } catch (err) {
                return str.replace(/=([A-Fa-f0-9]{2})/g, function(_, hex) {
                    return String.fromCharCode(parseInt(hex, 16))
                })
            }
        }

        const upperRawKey = rawKey ? rawKey.toUpperCase() : ''

        if (key.startsWith("SUMMARY")) {
            if (upperRawKey.indexOf('QUOTED-PRINTABLE') !== -1) {
                e.content = decodeQuotedPrintable(value)
            } else {
                e.content = value
            }
        } else if (key.startsWith("DTSTART")) {
            e.startDate = parseICalDateTime(value)
        } else if (key.startsWith("DTEND")) {
            e.endDate = parseICalDateTime(value)
        } else if (key.startsWith("RRULE")) {
            e.rrule = value
        } else if (key.startsWith("UID")) {
            e.uid = value
        } else if (key.startsWith("RECURRENCE-ID")) {
            // RECURRENCE-ID may carry TZID param; parse value portion
            e.recurrenceId = parseICalDateTime(value)
        } else if (key.startsWith("EXDATE")) {
            // EXDATE may be comma-separated values. Keep as Dates array.
            const parts = value.split(',').map(s => parseICalDateTime(s.trim())).filter(Boolean)
            e.exdates = (e.exdates || []).concat(parts)
        } else if (key.startsWith("STATUS")) {
            e.status = (value || '').toUpperCase()
        }
        
        e.allDay = line.startsWith("DTSTART;VALUE=DATE")
    }

    // --- Parse iCalendar datetime format (from SQLite or ICS) ---
    function parseICalDateTime(dateStr) {
        if (!dateStr) return null;
        dateStr = dateStr.trim();

        // Match DATE-only form: YYYYMMDD
        const dateOnly = dateStr.match(/^(\d{4})(\d{2})(\d{2})$/);
        if (dateOnly) {
            const year = parseInt(dateOnly[1], 10);
            const month = parseInt(dateOnly[2], 10) - 1;
            const day = parseInt(dateOnly[3], 10);
            return new Date(year, month, day, 0, 0, 0); // midnight local time
        }

        // Match full datetime form: YYYYMMDDTHHMMSS(Z optional)
        const m = dateStr.match(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})?(Z)?$/);
        if (!m) return null;

        const year = parseInt(m[1], 10);
        const month = parseInt(m[2], 10) - 1;
        const day = parseInt(m[3], 10);
        const hour = parseInt(m[4], 10);
        const min = parseInt(m[5], 10);
        const sec = m[6] ? parseInt(m[6], 10) : 0;
        const isUTC = !!m[7];

        return isUTC
            ? new Date(Date.UTC(year, month, day, hour, min, sec))
            : new Date(year, month, day, hour, min, sec);
    }

    // --- Expand recurring events ---
    function expandRecurringEvent(summary, startStr, endStr, icalData, exceptionsMap) {
        let events = []

        // parse DTSTART/DTEND from VEVENT if present (fallback to startStr/endStr)
        const dtstartMatch = icalData.match(/DTSTART[^:]*:([^\n\r]+)/)
        const dtendMatch = icalData.match(/DTEND[^:]*:([^\n\r]+)/)
        const eventStart = dtstartMatch ? parseICalDateTime(dtstartMatch[1]) : parseICalDateTime(startStr)
        const eventEnd = dtendMatch ? parseICalDateTime(dtendMatch[1]) : parseICalDateTime(endStr) || eventStart
        if (!eventStart) return events
        const duration = eventEnd.getTime() - eventStart.getTime()
        
        // Check if this is an all-day event
        const isAllDay = icalData.match(/DTSTART;VALUE=DATE[^:]*:/) !== null

        // RRULE & parameters
        const rruleMatch = icalData.match(/RRULE:([^\n\r]+)/)
        const rrule = rruleMatch ? rruleMatch[1] : ''
        const freq = (rrule.match(/FREQ=([^;]+)/) || [])[1]
        const untilStr = (rrule.match(/UNTIL=([^;]+)/) || [])[1]
        const countMatch = rrule.match(/COUNT=(\d+)/)
        const intervalMatch = rrule.match(/INTERVAL=(\d+)/)
        const byday = (rrule.match(/BYDAY=([^;]+)/) || [])[1]

        const intervalVal = intervalMatch ? parseInt(intervalMatch[1], 10) : 1
        const maxOccurrences = countMatch ? parseInt(countMatch[1], 10) : 1000
        const untilDate = untilStr ? parseICalDateTime(untilStr) : new Date(2030, 0, 1)

        // parse EXDATE(s) from VEVENT body (can be multiple EXDATE lines or comma-separated)
        let exdateTimes = new Set()
        const exdateLines = (icalData.match(/EXDATE[^:\n\r]*:[^\n\r]+/g) || [])
        for (let line of exdateLines) {
            const val = line.split(':', 2)[1] || ''
            const parts = val.split(',').map(s => s.trim()).filter(Boolean)
            for (let p of parts) {
                const dt = parseICalDateTime(p)
                if (dt) exdateTimes.add(dt.getTime())
            }
        }

        // helper to check exceptions map for a given time
        exceptionsMap = exceptionsMap || {}

        // track matched exception times so we can later add unmatched overrides if needed
        const usedExceptionKeys = new Set()

        // Helper to push occurrence (applies override or skip if cancelled)
        function pushOccurrence(dt) {
            const k = dt.getTime()
            // skip if EXDATE explicitly lists it
            if (exdateTimes.has(k)) return
            // if exceptionsMap has this key
            if (exceptionsMap[k]) {
                const parsed = exceptionsMap[k]
                // if cancelled, skip
                if (parsed.status === 'CANCELLED') {
                    usedExceptionKeys.add(k)
                    return
                }
                // override: use parsed DTSTART/DTEND/SUMMARY if present
                usedExceptionKeys.add(k)
                events.push({
                    content: parsed.content || summary,
                    startDate: parsed.startDate || new Date(k),
                    endDate: parsed.endDate || (parsed.startDate ? parsed.endDate : new Date(k + duration)),
                    color: ColorUtils.stringToColor(parsed.content || summary),
                    allDay: isAllDay
                })
                return
            }
            // normal occurrence: use dt with same time-of-day as eventStart
            const occ = new Date(dt)
            occ.setHours(eventStart.getHours(), eventStart.getMinutes(), eventStart.getSeconds(), eventStart.getMilliseconds())
            events.push({
                content: summary,
                startDate: occ,
                endDate: new Date(occ.getTime() + duration),
                color: ColorUtils.stringToColor(summary),
                allDay: isAllDay
            })
        }

        // Generate occurrences depending on frequency
        if (freq === 'WEEKLY') {
            const weekdayMap = { SU:0, MO:1, TU:2, WE:3, TH:4, FR:5, SA:6 }
            const byDays = byday ? byday.split(',').map(d => weekdayMap[d]) : [eventStart.getDay()]

            // start at the week containing eventStart
            let weekStart = new Date(eventStart)
            weekStart.setHours(0,0,0,0)
            let occurrences = 0

            while (weekStart <= untilDate && occurrences < maxOccurrences) {
                for (let wd of byDays) {
                    // compute date of weekday wd in the week that includes weekStart
                    const occurrenceDate = new Date(weekStart)
                    const offset = (wd - weekStart.getDay() + 7) % 7
                    occurrenceDate.setDate(weekStart.getDate() + offset)
                    occurrenceDate.setHours(eventStart.getHours(), eventStart.getMinutes(), eventStart.getSeconds(), eventStart.getMilliseconds())

                    if (occurrenceDate >= eventStart && occurrenceDate <= untilDate && events.length < maxOccurrences) {
                        pushOccurrence(occurrenceDate)
                        occurrences++
                    }
                }
                // advance by intervalVal weeks
                weekStart.setDate(weekStart.getDate() + 7 * intervalVal)
            }
        } else if (freq === 'DAILY' || freq === 'MONTHLY' || freq === 'YEARLY') {
            let current = new Date(eventStart)
            let occurrences = 0
            while (current <= untilDate && occurrences < maxOccurrences) {
                pushOccurrence(current)
                occurrences++
                if (freq === 'DAILY') current.setDate(current.getDate() + intervalVal)
                else if (freq === 'MONTHLY') current.setMonth(current.getMonth() + intervalVal)
                else if (freq === 'YEARLY') current.setFullYear(current.getFullYear() + intervalVal)
            }
        } else {
            // unknown frequency, fallback to single DTSTART
            pushOccurrence(eventStart)
        }

        // Finally, add any override exceptions that were not matched to an occurrence
        for (const k in exceptionsMap) {
            const kNum = parseInt(k, 10)
            if (!usedExceptionKeys.has(kNum)) {
                const parsed = exceptionsMap[k]
                if (!parsed) continue
                if (parsed.status === 'CANCELLED') continue
                // add this standalone override
                events.push({
                    content: parsed.content || summary,
                    startDate: parsed.startDate || new Date(kNum),
                    endDate: parsed.endDate || (parsed.startDate ? parsed.endDate : new Date(kNum + duration)),
                    color: ColorUtils.stringToColor(parsed.content || summary),
                    allDay: isAllDay
                })
            }
        }

        // sort & dedupe
        events.sort(function(a,b){ return a.startDate - b.startDate })
        let out = []
        for (let i = 0; i < events.length; i++) {
            if (i === 0 || events[i].startDate.getTime() !== events[i-1].startDate.getTime() || events[i].content !== events[i-1].content) {
                out.push(events[i])
            }
        }

        return out
    }

    // --- Public API ---
    function getTasksByDate(date) {
        if (!edsAvailable) return []

        const dayStart = new Date(date)
        dayStart.setHours(0, 0, 0, 0)
        const dayEnd = new Date(dayStart)
        dayEnd.setDate(dayEnd.getDate() + 1)

        const res = root.events.filter(e => {
            if (!e.startDate || !e.endDate) return false
            const start = new Date(e.startDate)
            const end = new Date(e.endDate)
            return start < dayEnd && (end > dayStart || e.allDay)
        })

        return res
    }

    function getEventsInWeek() {
        const d = new Date();
        const num_day_today = d.getDay();
        let result = [];
        for (let i = 0; i < root.weekdays.length; i++) {
            const dayOffset = (i + Config.options.time.firstDayOfWeek+1); 
            d.setDate(d.getDate() - d.getDay() + dayOffset %7);
            const events = this.getTasksByDate(d);
            const name_weekday = root.weekdays[d.getDay()];
            let obj = {
                "name": name_weekday,
                "events": []
            };
            events.forEach((evt, i) => {
                let start_time = Qt.formatDateTime(evt["startDate"], "hh:mm");
                let end_time = Qt.formatDateTime(evt["endDate"], "hh:mm");
                let title = evt["content"];
                obj["events"].push({
                    "start": start_time,
                    "end": end_time,
                    "title": title,
                    "color": evt['color'] 
                });
            });
            result.push(obj)
        }

        return result;
    }

    // --- Refresh timer ---
    Timer {
        id: interval
        running: root.edsAvailable
        interval: Config.options?.resources?.updateInterval * 60 ?? 3000 * 60
        repeat: true
        onTriggered: {
            if (root.calendarDirs.length > 0) {
                loadCalendarData.running = true
            } else {
                loadLocalCalendarData.running = true
            }
        }
    }
}

