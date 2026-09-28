# Exist: Bluetooth Attendance (design, as built)

Phones only: no extra hardware. On a normal day, students do nothing and an Android teacher
does nothing; an iPhone teacher opens the app once per class.

```
Teacher phone (peripheral)                     Student phone (central, native code)
 ├─ iBeacon  UUID = region(session, phase) ──▶  wakes app (iOS region / Android scan filter)
 ├─ GATT service UUID = f(session)       ◀──▶  connect
 │    CHALLENGE (read)  ver|shortId|slot|token|phase|windowIdx
 │    CHECKIN   (write) body + ECDSA-P256 signature (hardware key)
 └─ outbox ──(any time there is internet)──▶ Backend: re-verifies everything, computes status
```

## 0. Subjects, classes and classes at any time (protocol v2)

* **No administrator.** Teachers create classes (subject × group, optional start/end dates) and share a class
  code; students join with it; other teachers co-teach with a co-teacher code. Teachers set the timetable and special days
  of their own classes, approve students' new phones, record leave and reset passwords. Anyone can delete their account.
  An optional institution-wide teacher code (set at launch) keeps students from creating teacher accounts.
* **Personal calendars:** everyone can add private entries next to their classes; only they see them.
* **Bluetooth identity per subject group, not per class session.** Each subject group has permanent
  service UUIDs and iBeacon UUIDs, in two variants ("toggle 0/1"). A student's phone listens only for its
  own subjects this semester, so:
  * a teacher can start a class **any time, offline**, and students' phones still detect it;
  * phones of students not in the subject never react. If one connects anyway, the teacher's phone answers
    "not in this class" and the server rejects it too.
* **The toggle wakes phones.** The teacher's phone flips the toggle whenever a check opens or closes.
  * Android students: an always-on, low-power system scan (works with the app closed) sees the new service
    variant and connects.
  * iPhone students: entering the other beacon region wakes the app (2 regions per subject, up to 10 subjects).
* **Instant verdict.** The teacher's phone verifies each check-in before answering the write, so a student's
  phone knows immediately whether it was accepted.

## 1. Core rules

* **Three checks per class:** START, a **secret random MID** (one per ~50 min), and END.
  3/3 → PRESENT · missed START → LATE · missed END → LEFT_EARLY · missed MID → FLAGGED ·
  passed ≤ half → ABSENT.
* The MID time is derived from the session secret, which only the teacher's phone and the server know.
* A check-in is valid only if all of these hold:
  * it is signed by the student's **bound hardware key**;
  * it carries the **rotating token** (HMAC(secret, slot), 5 s slots);
  * it was received within **±15 s** of that slot, so a relayed or replayed token fails;
  * its **nonce is unused**;
  * the student is **enrolled** in the class.
* The teacher's phone cannot fabricate check-ins, because it has no student keys, and it cannot move a check-in to another window, because the slot is signed.

Code: `backend/src/crypto/protocol.ts`, `backend/src/domain/{plan,evaluate,schedule,policy}.ts`,
mirrored in `app/lib/protocol/protocol.dart` and `app/lib/domain/plan.dart`, and kept identical by
`shared/test-vectors.json`.

## 2. Edge cases handled

| Situation | What happens |
|---|---|
| **Teacher late** | START opens when the teacher actually starts, so students are never marked late for it. Students are told at +10 min, the admin at +20 min. The teacher can start up to 20 min before the scheduled end. |
| **Teacher phone auto-started, teacher/class arrived later** | START stays open until 5 min after 25% of the class has checked in. A MID that nobody passed doesn't count against anyone. If nobody checks in within 10/20 min, students and the admin are told. |
| **Teacher absent** | Not started 20 min before the end → `TEACHER_NO_SHOW`. The class is not counted, and students are told. |
| **Teacher phone was offline, not absent** | A later sync revives the no-show session and computes attendance normally. |
| **Teacher starts early** | Allowed up to 10 min early. START still runs until scheduled start + 10. |
| **Teacher ends early** | END opens immediately for 3 min. MIDs that hadn't happened are dropped. |
| **Class overruns** | The teacher can extend by up to +90 min. END moves; the MID does not. |
| **Teacher forgets to end** | Ends automatically at the planned end (phone), or 15 min later (server, at the last sign of activity). |
| **Teacher phone dies mid-class** | Checks that didn't run (under 50% activity coverage) don't count. Nothing ran → `UNVERIFIED`, and the teacher resolves it. |
| **Teacher phone missing** | The web dashboard shows a rotating QR. Check-ins are still hardware-signed and are labelled `via=qr`. |
| **No internet in class** | Everything is kept on the teacher's phone and synced later; the server re-verifies it all. |
| **Class cancelled in advance** | Students are notified, the class can't be started, and it doesn't count. |
| **Holiday** | No class is generated. |
| **Extra class** | The teacher announces it (needs internet so students' phones learn it). Runs like any class. |
| **Combined sections** | Same teacher, same time → one session for all the sections. |
| **Long lab (3 h)** | Several random MIDs. |
| **Substitute teacher** | Admin assigns one in advance, or a teacher covers and the admin approves it afterwards (records stay provisional until then). |
| **Room change** | Nothing to do: the session follows the teacher's phone, not the room. |
| **Class moved to another time** | The teacher taps Move. The old slot is cancelled, an extra class is created, and students are notified. |
| **Holiday / exam week / college fest** | Admin calendar entry. Classes are simply not generated, for everyone or for chosen sections. |
| **Saturday runs Monday's timetable** | Day-swap calendar entry. |
| **Class goes outside mid-lesson** | The teacher pauses attendance. Checks during the pause count for no one. |
| **Field trip** | After class: mark everyone present, with a reason (audited). |
| **Student late** | START missed but later checks passed → LATE. |
| **Student leaves early / goes out mid-class** | LEFT_EARLY / FLAGGED. |
| **Student's phone dead or forgotten** | The teacher marks "present without phone" (3 per term, then admin only). |
| **Bluetooth off** | A warning in the app. Nudge "you're not checked in" after START closes. |
| **Phone lagged, student sure they were there** | Dispute within 72 h → teacher accepts/rejects. Audited. |
| **Medical leave / on-duty** | Admin excuse → EXCUSED, left out of the percentage. |
| **New phone** | The new key waits 48 h (or admin approval); the old one is revoked. A friend can't take over an account overnight. |
| **Two accounts, one phone / one account, two phones** | A key binds to one account; an account has one active key. |
| **Wrong phone clock** | Server-corrected clock in the app; slots are checked against when the teacher's phone *received* them. |
| **Android battery killers (Xiaomi, Oppo…)** | Onboarding asks for a battery exemption and exact alarms; the app warns if they are missing. |
| **Low attendance** | Daily warning below 75% (after 5+ classes). |
| **Every override** | Written to the append-only audit log. |

## 3. Calendar, automation and teacher control

**Academic calendar** (`backend/src/domain/calendar.ts`)
* **Terms:** no classes are generated outside term dates.
* **Holidays and exams:** block classes for the whole college or for chosen sections.
* **Events:** optionally suspend classes.
* **Day swaps:** "Saturday follows Monday's timetable".
* **Notifications:** everyone affected is told when the admin adds an entry. Teachers can add tests and events for their own sections; these are informational and never cancel other teachers' classes.
* **Views:** a month view in the app, and a private `.ics` link to subscribe to in Google or Apple Calendar.

**Runs by itself**
* Classes auto-start. Late and absent teachers are handled, and forgotten classes auto-close.
* Students' phones refresh their class list in the background.
* **After every class:** a summary goes to the teacher ("32 present, 2 need review…"), and each student not marked present gets a personal note with the reason and the dispute deadline.
* **Daily:** a low-attendance warning, and alerts to the student and teacher after 3 absences in a row.
* **Mondays:** a digest for each teacher, with each section's average and the students at risk.
* Phone changes are approved automatically after the cooldown.

**Teacher controls**
| Where | Control |
|---|---|
| Section settings | auto-start on/off · 0–3 random middle checks (or automatic) · start-check length 5–30 min · end-check length 3–20 min · how LATE / LEFT_EARLY count (100/50/0%) · "present without phone" allowance 0–10 |
| During class | pause / resume (checks during a pause count for no one) · **surprise check** now (up to 3; phones check in by themselves) · +10 min · end early |
| Before class | start manually · cancel with a reason · **move** to another time (students notified) · extra class |
| After class | change any student's status · mark everyone not present as present or excused (field trip) · resolve disputes |
| Overview | "My sections": average, classes held, students below the requirement |

The settings are fixed for a class once it starts: the phone uploads the plan it used, and the
server re-checks the limits (`clampPlan`), so a running class is never re-planned under anyone.

## 4. Why not the MAC address?

A MAC address can't secure this app:
* **iOS** never gives apps the MAC address.
* **Android 6+** returns a fake constant (`02:00:00:00:00:00`).
* **Over Bluetooth**, phones broadcast a random address that changes about every 15 min, for privacy.

Exist uses the stronger equivalent: a **key generated inside the phone's security chip** (Android
Keystore/StrongBox, iPhone Secure Enclave) that can sign but can never be copied out. Every check-in is
signed with it. The phone model, OS and install ID are also recorded at registration, **for admins
only** (for example, "likely the same phone, reinstalled" on a phone-change request). They are never
used as proof, because a rooted phone can fake them.

## 5. Anti-cheat summary

| Attack | Blocked by |
|---|---|
| Friend logs in on their phone | Hardware key binding + 48 h change cooldown + password lockout |
| Student of another class checks in | Teacher phone answers "not in this class"; server rejects non-enrolled |
| Screenshot/forward the code | Nothing to screenshot: a check-in needs a live GATT connection + ±15 s slot |
| Replay a recorded check-in | Nonce uniqueness + slot bound to receive time |
| Sniff and clone the teacher beacon | The token needs the secret; the beacon carries no secret |
| Check in and leave | Secret random MID + END |
| Modified app / rooted phone | Android key attestation verified against Google's roots (record or strict mode); iOS App Attest pending an Apple Team ID |
| Friend carries my phone | **Not yet covered.** Face spot checks are planned (see gaps) |

## 6. Platform limits (cannot be engineered away)

* **iPhone as the teacher's phone:** iOS only advertises while the app is on screen, so the teacher taps Start
  (a reminder notification is scheduled) and leaves the phone on the desk.
* **iPhone as the student's phone:** waking for class uses iBeacon region monitoring, which needs **location
  "Always"**. iOS allows 20 regions, so the app watches the next 6 classes × 3 phases.
* **Android student:** location permission is needed because Android hides iBeacon results without it.
  Exact alarms + a battery exemption are needed to wake reliably.
* **Web browsers cannot take part** in Bluetooth check-in (by choice as well as by platform).

## 7. Known gaps / next steps

1. **iOS App Attest verification** (needs an Apple Team ID). Android attestation is verified.
2. **Friend carrying my phone:** random face spot checks (~10% of students per class), done on the phone.
   (The teacher's surprise check and the photo roster help in the meantime.)
3. **Corridor:** no RSSI threshold is enforced yet beyond −95 dBm. Calibrate it per room in the Phase 1 field test.
4. **Instant push when the phone is idle** would need Firebase/APNs. It's free but needs the institution's own setup. Today the app shows new alerts as phone notifications whenever it wakes.
5. **Large classes:** one teacher phone handles ~7–15 simultaneous GATT connections; each check-in takes
   about 1 s. Test with 60+ phones.
