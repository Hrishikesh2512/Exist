# Exist: Bluetooth attendance

Attendance marks itself when students are in class, using only phones. There's no administrator:
**teachers run their classes, students join them**. Three checks per class (start, a secret random
middle, and end) happen automatically over Bluetooth. It's free and runs on your own server.
Design details and edge cases: [DESIGN.md](DESIGN.md) · going live: [LAUNCH.md](LAUNCH.md).

```
backend/   TypeScript API (Fastify + Prisma + Postgres) and the website (backend/public)
app/       Flutter app for students and teachers (Android + iOS), with native Bluetooth code
shared/    test-vectors.json: proves the server and app speak exactly the same protocol
deploy/    launch kit: HTTPS server, daily backups, one-command setup
```

## How it works

| Who | Does |
|---|---|
| **Teacher** | Creates an account (with the institution's teacher code, if one was set) → **New class** (subject, group, dates) → shares the **class code** with students. Sets the weekly timetable and special days (no class / test / event). Can start a class **any time**. |
| **Student** | Creates an account with their roll number → **Join a class** with the code → accepts the privacy notice → registers the phone. From then on nothing to do: the phone checks in by itself, only for their own classes. |
| **Co-teacher** | Joins a class with its **co-teacher code** and shares everything about it. |

**Attendance sheets**
- **Teachers** see each class's full register (students × dates, with %), can change any entry, and can download it as CSV (app or website).
- **Students** see their total, each class's %, and their own sheet class by class. They can report a wrong entry to the teacher.

**Calendar**
- Every class's timetable, holidays, tests and events in one month view.
- **Anyone** can add their own entries (study plan, reminders), visible only to them.
- A private link adds it all to Google or Apple Calendar.

**Teachers also handle:**
- **Leave:** record medical or on-duty leave for a student in their class.
- **New phones:** approve a student's new phone (otherwise it's automatic after 48 h).
- **Passwords:** reset a student's forgotten password.
- **During class:** pause, surprise check, mark a student by hand, extend or end early.
- **Scheduling:** move or cancel classes, set per-class attendance settings.

**Everyone can:**
- change their password;
- use "forgot password" (emailed code if email is set up);
- delete their own account (attendance stays in registers, anonymised).

## Local testing (developers)

```bash
podman compose up -d --build                         # server on http://<computer-ip>:8080
./deploy/build-app.sh http://<computer-ip>:8080      # app with that address built in → exist.apk
```

The address is built into the app (users never type it), so a test build must be rebuilt if the
computer's IP changes. A real launch uses a fixed `https://` address; see LAUNCH.md.
The iPhone app must be built on a Mac with Xcode.

## Tests

```bash
backend/scripts/test-integration.sh   # 78 tests against real Postgres + checks the compiled server starts
cd app && flutter test                # Dart matches the server byte-for-byte (shared vectors)
```

After changing the protocol or planning code, run `npm run vectors` in `backend/` and both test suites.

## Security and privacy

- Each phone gets a key inside its security chip that can't be copied. Every check-in is signed with it, and an account works on one phone.
- A class's check-ins are accepted only from its own students; the teacher's phone and the server both check.
- **Rooted or modified Android phones:** Google's key attestation is verified. By default, teachers see a warning next to the student; with `ATTESTATION_MODE=strict` such phones are refused.
- Rotating 5-second codes, one-time nonces, and check-ins bound to their time window.
- Privacy notice with consent; lockout after 8 wrong passwords; changing a password signs out everywhere; manual changes are audit-logged.

## Known limits

- **iPhone:** the native code has never been compiled (needs a Mac). iOS App Attest verification needs an Apple Team ID.
- **Alerts on an idle phone:** they show when the app wakes (class time, or opening it), not instantly. Instant alerts need Firebase, which is free but needs your own Google project.
- **A friend carrying your phone to class:** partly covered by surprise checks and the teacher's name list; face checks are not built.
- **Field test needed:**
  - how far the signal reaches;
  - whether many phones checking in at once all succeed;
  - whether a *closed* iPhone app wakes reliably.
