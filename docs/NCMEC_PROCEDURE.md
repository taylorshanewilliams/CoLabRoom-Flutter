# Reporting child sexual abuse material

What happens if CSAM is found on CoLabRoom. Written 8 September 2026, the day
Decibel Zero LLC applied to the NCMEC CyberTipline as an electronic service
provider.

This is an internal operating procedure, not a public page. It exists because
18 U.S.C. §2258A imposes a real duty to report on actual knowledge, the
tooling to act already exists, and the worst time to work out the order of
operations is while it is happening.

## What the law asks, and what it does not

**There is no duty to search.** §2258A(f) is explicit that a provider is not
required to monitor its service or affirmatively seek facts. CoLabRoom does
not scan uploads, and choosing not to is lawful.

**There is a duty to report on actual knowledge**, as soon as reasonably
possible after obtaining it. Actual knowledge means a person here knows —
from a report, from moderating something else, from anything.

**There is a duty to preserve.** The REPORT Act moved this from 90 days to
**at least one year** from the date of the report. Preservation covers the
contents of the report and any material that accompanied it.

## Who does this

Taylor Williams, and at present nobody else. One person is enough for four
users and will not be enough later; when it stops being enough, this document
is what a second person is handed.

## How something reaches us

| Route | Where it lands |
| --- | --- |
| Report inside the app | `content_reports`, five stranger-facing surfaces |
| `abuse@colabroom.com` | the address registered with NCMEC |
| `support@colabroom.com` | the published developer contact |
| Anywhere else | it still counts — the route does not change the duty |

`moderation-check.yml` runs daily at 09:00 UTC and fails the workflow when any
report has been open more than 24 hours, which emails the repo owner. That is
the backstop for ordinary reports. **It is not the standard for this one** —
suspected CSAM is acted on when it is seen, not on the next scheduled run.

## The order of operations, which matters more than the speed

**1. Do not download it, forward it, or copy it anywhere.** Do not send it to
anyone for a second opinion. Possessing and distributing this material is
itself an offence and there is no exception that makes an operator's copy
safe. Work from the report and the database row.

**2. Preserve before you remove.** This is the step that is easy to get
backwards, because the takedown tooling is faster than the reporting portal.

> `tools/take_down.py` deletes the storage object. Running it before the
> CyberTipline report is filed destroys material the law requires be kept for
> a year. **File first, take down second.**

`public.take_down_image()` clears the column the app reads and returns the
storage path; the Python wrapper then deletes the object through the Storage
API. Neither half should run until step 3 is done.

**3. File the CyberTipline report** through the ESP portal at
`esp.ncmec.org`. Include what the registration says we would include: the
account identifier and registration email, the file and its storage path, the
upload timestamp, the song or room it was uploaded to, and the IP address
where available.

**4. Then remove it**, using `tools/take_down.py <report-id>`, and disable the
account. Verify the path no longer resolves — the script says `Gone.` only
when the object is actually unreachable.

**5. Preserve for a year.** Keep the CyberTipline report, the report id, the
account identifier and the storage path where they cannot be deleted by
routine cleanup. Note the date the year runs out.

## The known gap

**Account deletion currently removes everything, by design.** A user who
deletes their account takes their rows with them, and there is no legal-hold
flag that survives it. If a preserved matter's account were deleted, evidence
we are required to keep for a year would go with it.

At four users this is a theoretical problem. It stops being theoretical the
day strangers can install the app, and it is on the pre-launch list rather
than the backlog.

## Contacts

- CyberTipline ESP portal — `esp.ncmec.org`
- CyberTipline, 24 hours — 1-800-843-5678
- Registration applied for 8 September 2026, pending review

## Reviewing this

Read it again when a second person joins, when uploads open to strangers, or
when the deletion gap above is closed. A procedure nobody has read since it
was written is not a procedure.
