# Store privacy declarations — answer key

What to enter into Google Play's Data Safety form and Apple's App Privacy
"Nutrition Label" in App Store Connect. Both are consoles only an enrolled
developer account can submit to, so this can't be filed for you — but every
answer below is traced to the actual code, the same way `privacy.html` and
`terms.html` were, so filling either form should be copy-in rather than a
research project.

Three facts do most of the work in both forms:

- **No analytics SDK, no ad SDK, anywhere in the app.** Nothing here is used
  for advertising, and nothing here is used to track you across other apps
  or websites. That answers most of the "used for tracking" / "shared for
  advertising" questions with a clean no.
- **No location code anywhere.** The Location category is entirely N/A on
  both forms.
- **Payments aren't wired up yet.** A RevenueCat account exists but nothing
  in the app calls it. Leave Financial info / Purchases unanswered for now
  — **this file needs a pass the day subscriptions actually ship**, not
  before.

---

## Google Play — Data Safety

Per Google's definition, "collected" means data that leaves the device.
Two things that might look like they qualify don't: imported lyric sheets
(PDF/Word/Excel/etc.) are parsed **on the device**, only the resulting text
is saved — the original file is never uploaded. And Studio search
(`searchDrafts` in `draft_search.dart`) runs over data already loaded on the
device — no query is ever sent anywhere. Neither counts as collection.

| Category | Type | Collected? | Shared? | Purpose | Required? | Notes |
|---|---|---|---|---|---|---|
| Personal info | Name | Yes | No | App functionality, Account management | Yes | `profiles.display_name` |
| Personal info | Email address | Yes | No | App functionality, Account management | Yes | Sign-in and invitations |
| Personal info | User IDs | Yes | No | App functionality | Yes | Internal account id |
| Photos and videos | Photos | Yes | No | App functionality | **No** | Avatar and feedback screenshots — both explicitly optional |
| Audio files | Voice or sound recordings | Yes | **Yes** | App functionality | No | Voice notes and reference recordings. Shared with OpenAI (vocal stem only, transcription, only when analysis is requested) — see below |
| App activity | Other user-generated content | Yes | No | App functionality | No¹ | Lyrics, chords, comments, room/song names |
| App info and performance | Crash logs | Yes | No | App functionality | N/A² | `CrashReporter` → `analysis_errors` |
| App info and performance | Diagnostics | Yes | No | App functionality, Developer communications | N/A² | Feedback message/category/route/version/platform |

¹ Nobody is required to author content to have an account, but it's the
core thing the app is for.
² Collected automatically on error; there's currently no in-app setting to
opt out of this. Worth knowing — not something to fix silently, since
adding an opt-out is a real feature decision, not a form-filling one.

**Everything else — Location, Financial info, Health and fitness, Messages,
Videos, Files and docs, Calendar, Contacts, Web browsing, Device or other
IDs — answer "not collected."**

One judgment call: comments and lyrics could plausibly read as "Messages"
(user-to-user text) instead of "App activity → Other user-generated
content." I went with the latter because the content's primary purpose is
the shared document itself, not person-to-person messaging — but it's a
plain-language distinction Google's own reviewers use loosely, so it's
worth your own five-second gut check before submitting.

**Data sharing, specifically:** the only data that leaves CoLabRoom's own
systems is the isolated vocal stem, sent to OpenAI's transcription API, and
only when you ask a song to be analysed. RunPod and Google Cloud Run also
touch a recording during analysis, but they're infrastructure running our
own code, not independent recipients — same distinction `privacy.html`
draws. Google's own definition of "shared" is broad enough that declaring
all of them wouldn't be wrong either; I'd rather you know the reasoning
than take the terser answer on faith.

**Encryption in transit:** yes, uniformly — Supabase's client library and
every Edge Function call runs over HTTPS.

**Data deletion:** yes — describe the in-app **Account → Delete account**
flow, and link `colabroom.com/privacy.html`.

---

## Apple — App Privacy ("Nutrition Label")

Apple sorts into three buckets: **Data Used to Track You**, **Data Linked to
You**, **Data Not Linked to You**. Given no ad/analytics SDK, nothing here
is Tracking — that whole bucket is empty.

| Data type | Collected? | Linked to you? | Purpose |
|---|---|---|---|
| Contact Info → Name | Yes | Yes | App Functionality |
| Contact Info → Email Address | Yes | Yes | App Functionality |
| User Content → Photos or Videos | Yes | Yes | App Functionality |
| User Content → Audio Data | Yes | Yes | App Functionality |
| User Content → Other User Content | Yes | Yes | App Functionality |
| Identifiers → User ID | Yes | Yes | App Functionality |
| Diagnostics → Crash Data | Yes | Yes | App Functionality |
| Diagnostics → Other Diagnostic Data | Yes | Yes | App Functionality |

Everything is "Linked to You" rather than "Not Linked" — every table this
data lands in is keyed to a signed-in account (`auth.uid()`), nothing here
is anonymized or aggregated before storage.

**Third-party partners:** Apple's form asks you to name data types shared
with third-party code. Declare **Audio Data → shared with a third-party
transcription provider (OpenAI)**, same reasoning as the Play form above.

**Everything else** — Location, Health & Fitness, Financial Info, Sensitive
Info, Contacts, Browsing History, Search History, Purchases — not
collected.

---

## When this needs revisiting

- The day RevenueCat actually gets wired up: add Financial Info / Purchases
  to both forms before that build ships, not after.
- If an opt-out for crash/diagnostic reporting ever gets built, the
  "Required?" column on Play's diagnostics rows changes.
- If Studio search or anything else starts sending queries to a server
  instead of running locally, re-check the "not collected" calls above —
  several of them depend on that staying true.
